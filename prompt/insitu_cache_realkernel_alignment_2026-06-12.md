# GVSoC ↔ CachePool RTL — Real-Kernel Trace Alignment (dataset `replay_batch_2026-06-12`)

**Date:** 2026-06-08.  
**Dataset:** `ManyRVData_rebase/reports/cache_calib/replay_batch_2026-06-12/` — per-controller
cache request traces captured from 5 real kernels on the integrated 16-core CachePool cluster
(`cachepool_fpu_512`, Burst=4, cache IP `93d1c11`), with the RTL's per-access answers in
`peraccess/t<T>c<C>.rtl.csv`.  
**Method:** replayed each `traces/t<T>c<C>.trace` (the shared `port,rw,addr,size,delay` format,
verbatim — addr is controller-view, no interco) through the GVSoC `insitu_cache_calib` model in
**default / Burst=4** mode (single-outstanding refill, MemLatency=50, BeatGap=0, AcceptEvery=1 —
the same memory contract as `CALIB_IMPLEMENTATION.md`), emitted the same per-access CSV, joined
on `idx`, and diffed the `latency` column. Tool: `/tmp/replay_diff.py`. Geometry matches the RTL
DUT (4-way × 256-set × 64 KiB = 1024 entries/controller).

---

## 1. Headline — the model does NOT align to real-kernel traces

GVSoC **over-predicts per-access latency on every kernel by ~+60 to +85 cycles (mean)**, with
exact-match latency only 1.6–21 %. The over-prediction hits **hits and misses alike**.

| kernel | acc | RTL lat | GVSoC lat | exact% | mean Δ | hit Δ | miss Δ | scalar Δ | GV/RTL max-outstanding |
|---|---|---|---|---|---|---|---|---|---|
| fmatmul-32b M32 (full) | 42 787 | 10.2 | 71.7 | 21.0 | +61.5 | +65.0 | +25.6 | +21.3 | 134 / 52 = 2.6× |
| fft-32b M1024 (full) | 107 295 | 10.4 | 83.2 | 8.0 | +72.9 | +75.1 | +39.4 | +5.5 | 126 / 50 = 2.5× |
| gemv-opt M512 (full) | 204 736 | 35.7 | 113.1 | 1.6 | +77.4 | +106.0 | +16.9 | +85.9 | 138 / 65 = 2.1× |
| fdotp-32b M8192 (full) | 49 621 | 109.5 | 180.1 | 14.5 | +70.6 | +39.0 | +133.9 | +44.2 | 128 / 104 = 1.2× |
| fmatmul-32b M128 (partial) | 334 465 | 13.2 | 98.1 | 7.9 | +84.9 | +81.5 | +112.3 | +58.8 | 149 / 53 = 2.8× |

(`hit` = RTL latency ≤ 12 cy; `miss` = > 12. Δ = GVSoC − RTL, cycles.)

---

## 2. It's right-contents, wrong-timing (verified)

The GVSoC cache makes **the same refills as the RTL** — the hit/miss *sequence* is correct; only
the *timing* diverges. Verified `mem_rd` (refill count) on three contrasting controllers:

| controller (kernel type) | GVSoC mem_rd | RTL mem_rd |
|---|---|---|
| fmatmul M32 t0c0 (cache-resident, no eviction) | 16 | 16 |
| gemv t0c0 (cache-active, real eviction traffic) | 266 | 267 |
| fdotp t3c1 (streaming, latency-bound) | 68 | 69 |

All within ~1 refill. So there is **no hash-way / eviction / miss-pattern divergence** — the
gap is entirely in how long each access *takes*, not which accesses miss. (Confirmed too by
matching total cycles/throughput on fmatmul M32 t0c0: 51 k cy / 0.052 vs 54 k / 0.050.)

---

## 3. Root cause (ranked) — internal over-serialization

GVSoC accepts the same accesses but **serializes them internally far more than the RTL** (2–3×
the peak outstanding), inflating per-access latency. Three mechanisms, all pre-documented as
APPROXIMATED items in the RTL-coverage matrix:

1. **`set_busy_until` over-serializes a hot, heavily-reused set (dominant on hit-bound kernels).**
   The model charges 1 access per set per full hit-latency window; a hit to a busy set queues
   behind *every* prior access to that set. Real kernels reuse few lines intensely across 4 VLSU
   + scalar ports (matmul reuses 17 lines ~157×; gemv streams a matrix) → hit latency blows up
   (fmatmul M32 t0c0 max 1180 vs RTL 148; gemv hit Δ +106). The RTL avoids this via pseudo-dual-
   port banks (`BankFactor`) + the `par_coalescer` merging same-cycle same-line reads. Evidence:
   the tell-tale 97/98/99/100 monotonic-by-port latency on a 4-port same-line group (set_busy
   +1/port), and relaxing the coalescer threshold did **not** fix it (followers MSHR-merge but the
   base wait + the `mshr_drain_cycles_per_subarray` +1/port ordering remain).
2. **Refill-serialization cascade (dominant on the latency-bound fdotp, miss Δ +134).** GVSoC's
   single-outstanding memory serializes refills so heavily that the per-refill round-trip seen by
   the cache averages ~280 cy on fdotp t3c1 (a non-queued refill is ~53) — lines become "ready"
   much later than in the RTL, so accesses the RTL serves as fast hits, GVSoC charges the wait.
   fdotp is the cleanest probe of the memory-latency model (per the dataset), and it shows the
   **miss/refill latency is over-predicted**, i.e. GVSoC's refill serialization is more aggressive
   than the RTL's single-outstanding-refill behaviour.
3. **Scalar bypass absent (secondary, +5…+86 by kernel).** Port 4 (Snitch scalar) bypasses the
   coalescer via a 2:1 xbar in the RTL — hit ≈ 3 cy, cold-miss ≈ 60. GVSoC treats port 4 like a
   VLSU port (7 / 67), and on busy controllers (gemv) the scalar also inherits the set_busy
   serialization (scalar Δ +86).

---

## 4. Per-kernel reading
- **fmatmul M32 / fft (compute/hit-bound, RTL ~10):** mean Δ +60…+73, dominated by the set_busy
  hit-serialization (hit Δ +65…+75). 2.5–2.6× outstanding.
- **gemv (cache-active, RTL 35):** worst hit inflation (+106) and worst exact% (1.6) — heavy
  multi-port matrix streaming maximally stresses the hot-set serialization; misses align best
  (+17).
- **fdotp (latency-bound, RTL 109):** the only kernel where the **miss/refill** term dominates
  (+134) and the outstanding ratio is near 1 (1.2×, because the RTL is genuinely latency-bound
  too). This is the kernel that isolates the memory/refill-serialization over-prediction.
- **fmatmul M128 (partial startup):** cold-load-heavy; both hit (+82) and miss (+112) inflated.

---

## 5. Why the synthetic calib looked fine but real traces don't
The synthetic calibration phases (single-port streams, isolated misses, the coal_warm/coal_cold
4-port phases) matched the RTL's headline numbers, but they **never stressed multi-port,
heavily-reused, refill-active access to a hot set** the way real kernels do. The real traces
expose the APPROXIMATED `set_busy` / coalescer / refill-serialization residuals as the **dominant**
error, not a secondary one. The model is calibrated to the synthetic boundary cases but is **not
yet a faithful per-access latency predictor for real workloads.**

---

## 6. Recommended fixes (Phase-B, in impact order)
1. **Relax `set_busy_until` to model bank concurrency** (RTL `BankFactor`/pseudo-dual-port +
   coalescer): same-set / same-line accesses should not serialize one-per-hit-latency. This is the
   #1 lever (drives the +60…+106 hit inflation across all kernels).
2. **Make the input coalescer structural** (merge same-cycle same-line reads regardless of ready
   state, fan one lookup to N ports), so multi-port same-line groups don't serialize.
3. **Re-tune the refill serialization** so the single-outstanding miss path matches the RTL's
   effective per-miss service time (fdotp miss Δ +134) instead of over-queuing.
4. **Model the scalar bypass** (port 4 fast path: ~3-cy hit, no coalescer/set_busy contention).

These are exactly the coverage-matrix APPROXIMATED/ABSENT items
(`insitu_cache_rtl_coverage_matrix.md` §3/§5) — this dataset quantifies their *real-workload*
impact for the first time.

---

## 7. Caveats
- `fmatmul-32b M128` is a **partial (startup ~1.3 %)** capture — valid for same-trace RTL↔GVSoC
  diff (both replay the identical trace) but not representative of the full kernel.
- `data_err` ignored (it is the count of sub-word/unaligned reads — a self-describing-data-check
  artifact; cache data correct, SB PASS on every run).
- Replays use the model **as committed** (default/Burst=4); a gated, default-off env knob
  `INSITU_CALIB_COALESCE_MAX_LAT` was added to the calib target for a discriminator experiment
  (it did not change the result and is off in this sweep).
- Tool + raw JSON: `/tmp/replay_diff.py`, `/tmp/align/json/<kernel>.json`.

---

## 8. Phase-B fixes — applied / attempted (2026-06-08)

### Fix #1 — pipelined-bank `set_busy` (APPLIED, kept)
New `bank_accept_cycles` knob (default 1): the per-set bank-busy stamp now advances by the bank
ACCEPT interval (1 cyc, pipelined) instead of the full hit latency, so back-to-back accesses to a
hot/reused set pipeline rather than serialize. This is the #1 lever and it works:

| kernel | meanΔ before | meanΔ after #1 | hitΔ before→after |
|---|---|---|---|
| fmatmul M32 | +61.5 | **+27.0** | +65 → +27 |
| fft M1024 | +72.9 | **+34.7** | +75 → +37 |
| fmatmul M128 | +84.9 | **+62.9** | +82 → +65 |
| gemv M512 | +77.4 | +76.1 | +106 → +104 |
| fdotp M8192 | +70.6 | +75.0 | +39 → +81 |

3/5 kernels (the hit/compute-bound + cold-load) improve substantially; gemv neutral; fdotp
slightly worse. **Synthetic calib + microbench are fully unchanged** (the bank stamp only fires
under same-set contention, which the synthetic distinct-set/coalesced phases avoid): warm hit 10,
streaming 7, cold-miss ML+17/+13, cold_stream 0.254, coal_cold 0.496, coal_warm 3.37, microbench
7 lines identical. So fix #1 is a strict improvement on the cases where the cache's hit-timing is
the dominant factor, with no regression.

### Fix #3 — single-outstanding-refill backpressure (ATTEMPTED, REVERTED)
A cache-side gate (DENY a new-line miss while a refill is outstanding, like RTL
`refill_read_outstanding_q`) **backfired**: gemv/fdotp miss latency exploded (+400-600). **Root
cause (important):** the gate stalls *misses* but not *hits*, so a replayed hit to a not-yet-
refilled line runs ahead and is charged the wait — whereas in the RTL the *core itself* stalled on
that line's miss, so the hit was only issued after the line was resident. **Open-loop trace replay
cannot reproduce the core's data-dependency stall when the cache's miss-timing differs from the
capturing cache.** This is the same wall the coal_cold deferred-completion refactor hit (NO-GO,
§13 of the calib report). Reverted; the machinery is removed.

### Why gemv/fdotp don't improve, and what it would take
gemv's residual is `hitΔ +104` (hits waiting on not-ready lines) and fdotp's is `missΔ +62` — both
the **refill-latency-under-load cascade**. Because the trace's `t_issue` was set by the RTL's
cache timing, replaying it through a different-timing cache mismatches the dependent accesses.
Closing this is **not** a pure cache-model change; it needs either (a) a closed-loop model that
regenerates injection from data dependencies, or (b) the heavy deferred-completion occupancy path
(repeatedly NO-GO). It is the recurring hard residual, now understood to be partly inherent to
open-loop replay.

### Fixes #2 (structural coalescer) and #4 (scalar bypass) — scoped, not applied
Both are secondary: the discriminator showed relaxing the coalescer does not move the dominant
residual, and the scalar offset (after fix #1) is a small fraction of the per-kernel mean. They
would trim the per-port `+1/port` MSHR-drain ordering and the scalar `7→3`/`67→60` offsets
(helping the hit-bound kernels modestly) but neither addresses the gemv/fdotp refill cascade.
Left as clean follow-ups.
