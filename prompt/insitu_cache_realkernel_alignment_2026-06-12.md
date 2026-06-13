# GVSoC ↔ CachePool RTL — Real-Kernel Trace Alignment (dataset `replay_batch_2026-06-12`)

> **RESOLUTION (2026-06-13, see §9):** the headline gap below is now largely **closed**. The
> dominant residual was the interco's monotonic output-arbitration double-counting the RTL
> backpressure in open-loop replay (NOT the per-set bank, NOT an inherent cascade for gemv). The
> per-cycle-arbitration fix brings mean per-access Δ to **+2.6…+6.4 cy on 4 kernels** (hit Δ
> +0.3…+4.5 everywhere); only fdotp retains a large residual (+21.1), entirely on the miss path —
> the genuine open-loop memory-latency cascade. §§1–8 are the investigation as it unfolded.

**Date:** 2026-06-08 (investigation); 2026-06-13 (§9 fix).  
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

## 8. Phase-B fixes — applied / attempted (2026-06-08 fix #1/#3; 2026-06-13 fix #4/#2)

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

### Fix #4 — scalar bypass port (APPLIED, kept)
The Snitch scalar request goes through the RTL 2:1 `reqrsp_xbar`, not the VLSU coalescer: a read
hit returns in ~3 cy and does not contend for the per-set bank. Modelled with a new
`controller.scalar_bypass_port` / `scalar_hit_latency_cycles` pair, fed by an
`interco.forward_initiator` knob that tags each forwarded request with its input-port index. All
three default OFF (Spatz path byte-identical); the calib DUT sets port=4, latency=3. Effect on the
real traces is small — the scalar-port Δ is trimmed but it is a minor fraction of each kernel's
mean (after fix #1 the dominant residual is VLSU refill timing, not the scalar). Synthetic
regression fully unchanged.

### Fix #2 — same-cycle MSHR-drain coalescing (APPLIED, kept)
The `par_coalescer` merges same-cycle same-line reads into one entry, so they retire together. The
drain loop now advances the per-subarray stagger only when a pending reader arrived in a *later*
cycle than the previous one, rather than once per pending reader. This is the correct RTL behaviour
but **zero measured impact** on these traces (the per-controller trace files rarely have multiple
same-cycle same-line readers surviving to the MSHR drain). Kept as a harmless, RTL-faithful
refinement; clearly noted as non-moving on the current dataset.

### Result with fix #1 + #4 + #2 (mean per-access latency Δ, cycles)
| kernel | meanΔ #1 only | meanΔ #1+#4+#2 |
|---|---|---|
| fmatmul M32 | +27.0 | **+26.5** |
| fft M1024 | +34.7 | **+34.6** |
| fdotp M8192 | +75.0 | +75.0 |
| gemv M512 | +76.1 | +76.1 |

Fixes #4/#2 are correct refinements that nudge the hit/scalar-bound kernels and leave the
memory-latency-bound ones (gemv, fdotp) untouched. **NB (superseded by §9):** at this point we
believed the gemv residual was the open-loop refill cascade. The §9 re-measurement disproves that
for gemv — it was a pure-model defect (interco output arbitration) and IS fixable.

## 9. Fix #5 — per-cycle output arbitration (APPLIED, the big lever) — 2026-06-13

A latency-component discriminator (env-gating each queue-wait term and re-measuring fft, whose
misses align so the shared paths are isolable) pinned the dominant residual on the **interco
output arbitration**, not the per-set bank (removing the bank wait changed fft by 0.1 cy; removing
the output wait collapsed it from +36.7 to +3.9).

**Root cause.** `output_busy_until_` was a *monotonic* per-output busy-until cyclestamp: under
sustained streaming it runs tens of cycles ahead of `now`, charging every request a growing
queue-wait. That models cross-cycle 1/cyc backpressure — correct for CLOSED-LOOP (Spatz, where the
core actually stalls on the returned latency) but **double-counted in open-loop replay**: the
trace's `t_issue` already encodes the RTL's cross-cycle backpressure (the core was throttled when
the cache couldn't accept), so re-applying it inflates hit latency ~+33 cy.

**Fix.** Add a second arbitration mode, `per_cycle_output_arb` (interco): reset the accept counter
each cycle and serialize only genuinely *same-cycle* requests (`output_accept_width` per cycle,
default 1) — which the trace's per-access latency *does* reflect. The mode is selected by the
trace's **injection semantics**, not the DUT:
- **default (accumulate)** — closed-loop (Spatz) and the synthetic phase traces, which inject at
  max rate and rely on accumulate-mode backpressure for their saturated-throughput metrics.
- **per-cycle** — real-kernel replay (opt-in via `INSITU_CALIB_PER_CYCLE_ARB=1`), pre-throttled
  `t_issue`.

**Result (clean sequential before→after, mean / hit / miss Δ vs RTL):**

| kernel | base mean (hit/miss) | fix mean (hit/miss) | gap closed |
|---|---|---|---|
| fmatmul M32 | 26.5 (26.8/23.1) | **3.9** (3.3/9.8) | 85% |
| fft M1024 | 34.6 (36.7/3.3) | **3.2** (4.1/−10.8) | 91% |
| fmatmul M128 | 62.7 (65.1/42.9) | **6.4** (4.5/21.7) | 90% |
| gemv M512 | 76.1 (104.1/16.7) | **2.6** (0.9/6.1) | 97% |
| fdotp M8192 | 75.0 (81.3/62.2) | **21.1** (0.3/62.7) | 72% |

The hit Δ collapses to **+0.3…+4.5** on every kernel. gemv (the worst) → +2.6 **proves** §8's
"inherent cascade" attribution wrong — it was the interco arbitration. fdotp's hit path is now
exact (+0.3); its entire residual is the **miss-path** memory-latency cascade (+62.7, unchanged) —
the genuine open-loop limit (§6 fix (a), needs a closed-loop injection model). The mixed-sign
small miss deltas on the other kernels (−10.8…+21.7) are the new dominant — but minor — error.

**No regression:** the accumulate `else`-branch is byte-identical to the original code, so the
synthetic phases (coal_cold 0.4961, evict 0.1659, warm_hit 10, cold_miss 67, …) and the closed-loop
microbench (7 lines unchanged) are provably untouched — they never set the env knob.

> Methodology note: gvsoc writes `gvsoc_config.json` into the working dir, so concurrent replay
> processes sharing one cwd race on it (±0.3 cy of nondeterminism). All numbers above are from
> strictly **sequential** runs (verified reproducible).
