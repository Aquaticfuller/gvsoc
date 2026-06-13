# Weekly Report — GVSoC InSitu L1 Cache Model

**Period:** 2026-06-08 (Mon) → 2026-06-13 (Sat, week in progress)
**Engineer:** Zexin Fu
**Area:** Cycle-approximate GVSoC performance model of the CachePool InSitu L1 data
cache, calibrated against the RTL standalone testbench and (new this week) real-kernel
RTL traces.

---

## TL;DR

Last week the model was calibrated against the RTL **synthetic** calib testbench (every
throughput + headline-latency phase matched). This week we (1) pulled and rebased onto the
latest upstream + handled a new build dependency, (2) confirmed the model still aligns with
the newest RTL standalone calib run, (3) did a full RTL-microarchitecture **coverage audit**,
and (4) — the main thrust — aligned the model for the first time against **real Spatz-kernel
RTL traces** (fmatmul, fft, gemv, fdotp), not synthetic phases.

The real-kernel alignment exposed a **systematic per-access latency over-prediction
(+60–85 cy)** that the synthetic calib didn't surface, while cache *contents* matched (right
contents, wrong timing). After a chain of Phase-B fixes (pipelined-bank, scalar bypass,
MSHR-drain coalescing) and a diagnostic re-measurement, a latency-component discriminator
pinned the dominant residual on the **interco output arbitration** — a monotonic busy-until
cyclestamp that double-counts the RTL's backpressure in open-loop replay (the trace's `t_issue`
already encodes it). The **per-cycle-arbitration fix closes 85–97 % of the gap on 4 of 5
kernels** (hit Δ +0.3…+4.5 everywhere) with provably zero synthetic/Spatz regression. Only
fdotp keeps a large residual (+21.1) — entirely on the **miss path**, the genuine open-loop
memory-latency cascade that needs a closed-loop injection model.

**Real-kernel alignment scorecard at week end (mean per-access latency Δ vs RTL):**

| kernel | committed (fix #1+#4+#2) | **after fix #5 (per-cycle arb)** | hit Δ | miss Δ |
|---|---|---|---|---|
| fmatmul M32 | +26.5 | **+3.9** | +3.3 | +9.8 |
| fft M1024 | +34.6 | **+3.2** | +4.1 | −10.8 |
| fmatmul M128 | +62.7 | **+6.4** | +4.5 | +21.7 |
| gemv M512 | +76.1 | **+2.6** | +0.9 | +6.1 |
| fdotp M8192 | +75.0 | **+21.1** | +0.3 | +62.7 |

(Pre-any-fix baseline was +61–85 cy; fix #5 takes 4 kernels to within ~3–6 cy.) Synthetic calib
+ microbench remain byte-identical throughout (warm hit 10, streaming 7, cold miss ML+17/+13,
coal_cold 0.496, evict 0.166, microbench 7 lines) — the fix is opt-in for open-loop replay only.

---

## What was done

All of this week's committed work landed 2026-06-13; organised here by workstream.

### 1. Upstream pull + rebase + new build dependency
- **Pulled upstream and rebased** both `insitu-cache` dev branches (`core`, `pulp`) onto the
  latest `gvsoc/*` `master` (clean, no conflicts) and **bumped the engine** to upstream
  `5863c25e`. Force-with-lease pushed to the `Aquaticfuller/*` forks; parent stays local.
- **Handled a new elfutils build dependency.** Upstream's ISS now resolves trace PC→symbol at
  runtime via libdw (`<elfutils/libdwfl.h>`, `riscv.py` `add_libraries(['dw','elf'])`). The ETH
  cluster ships the runtime libs but not `elfutils-devel`, and there's no passwordless sudo.
  Added `scripts/setup_elfutils_headers.sh` — a no-sudo dnf-download + RPM-extract of just the
  headers + the missing `libdw.so` link symlink; `--env` prints the `CPATH`/`LIBRARY_PATH`
  exports. Documented in `CLAUDE.md`.

### 2. Re-alignment vs the latest RTL standalone run
- Diffed the model against the RTL's newest synthetic calib run (`run_2026-06-12`) — **all
  metrics still align** (ALIGNED-CONFIRMED). The rebase + engine bump did not perturb the
  calibration.

### 3. RTL microarchitecture coverage audit
- Re-read the InSitu RTL and wrote a **feature coverage matrix**
  (`prompt/insitu_cache_rtl_coverage_matrix.md`): for each RTL microarch feature (par-coalescer,
  Snitch bypass xbar, single-outstanding refill, write-through/coalescer FSM, partition-flushable
  SPM, hash-way/LRU, forwarding buffer, MSHR merge, install ramp), whether it is modeled, gated,
  approximated, or out of scope — so we know exactly what the cycle-approximate model does and
  does not represent.

### 4. Real-kernel alignment — the main thrust
- **New dataset:** the RTL side produced per-controller real-kernel traces
  (`replay_batch_2026-06-12`: fmatmul-32×32, fmatmul-128, fft-1024, gemv-512, fdotp-8192), each
  with a per-access RTL latency CSV. First alignment against **real workloads**, not synthetic
  calib phases.
- **Built the replay-diff harness** (`/tmp/replay_diff.py`): replays each kernel's per-controller
  trace through the GVSoC `insitu_cache_calib` model under the identical memory contract
  (MemLatency=50, Burst=4, single-outstanding), joins on `idx`, and diffs the per-access latency,
  bucketed by hit/miss/scalar + occupancy (`max_outstanding`).
- **Finding: right contents, wrong timing.** Cache contents matched (mem_rd within ~1), but
  GVSoC over-predicted per-access latency by **+60–85 cy** on every kernel — a timing-only
  divergence the synthetic calib never showed because its phases use distinct-set / coalesced
  access patterns that avoid hot-set contention. Root cause: per-set bank over-serialization
  (occupancy inflated 2–2.7× vs RTL). Documented in
  `prompt/insitu_cache_realkernel_alignment_2026-06-12.md`.

### 5. Phase-B fixes
- **Fix #1 — pipelined-bank `set_busy` (the dominant lever, kept).** New `bank_accept_cycles`
  knob (default 1): the per-set bank-busy stamp now advances by the pipelined ACCEPT interval
  (1 cy) instead of the full hit latency, so back-to-back accesses to a hot/reused set pipeline
  rather than serialize. Closed ~50–57 % of the gap on the hit-bound kernels (fmatmul M32
  +61.5→+26.5, fft +72.9→+34.6). The bank stamp only fires under same-set contention, which the
  synthetic distinct-set/coalesced phases avoid → **zero synthetic/microbench/Spatz regression.**
- **Fix #4 — scalar bypass port (kept).** The Snitch scalar request goes through the RTL 2:1
  `reqrsp_xbar`, not the VLSU coalescer: a read hit returns ~3 cy and doesn't contend for the
  per-set bank. New `scalar_bypass_port`/`scalar_hit_latency_cycles` fed by an
  `interco.forward_initiator` port-tag. All default OFF (Spatz unchanged); calib DUT sets port 4.
  Trims the scalar-port Δ.
- **Fix #2 — same-cycle MSHR-drain coalescing (kept).** The par_coalescer merges same-cycle
  same-line reads into one entry, so they retire together; the drain now staggers per arrival
  cycle, not per reader. Correct RTL behaviour, zero measured impact on these traces — kept as a
  harmless RTL-faithful refinement.
- **Fix #3 — single-outstanding-refill backpressure (attempted, reverted).** A cache-side gate
  (DENY a new miss while a refill is outstanding) **backfired** (gemv/fdotp miss latency +400–600).
  Root cause: the gate stalls misses but not hits, so a replayed hit to a not-yet-refilled line
  runs ahead and is charged the wait — but in the RTL the *core* stalled on that line's miss.
  **Open-loop trace replay can't reproduce the core's data-dependency stall.** Reverted.

### 6. End-of-week gap re-measurement + the fixable/inherent split
- Re-ran all 5 kernels against the committed model and pinned down where the residual lives:
  - **Hit-path over-serialization dominates fft / fmatmul / gemv — and it is fixable.** fft is
    the proof: its misses align to **+3.3** and scalar to +2.2, yet hits are +36.7 off. If the
    memory/refill timing matched (misses prove it) and contents match, only the hit-accept path
    can inflate hits. Per-controller hit Δ tracks occupancy ratio (1.7× → +15–19; 2.5× → +30–40).
    This **revises** last week's assumption that gemv's residual was the inherent cascade —
    gemv's occupancy is 2.1–2.7× with miss Δ only +16.7, so it is mostly this fixable serialization.
  - **fdotp is the true inherent exception:** occupancy only 1.24× (uniform), hit+miss both large
    and flat → the genuine memory-latency cascade on the most ML-sensitive kernel; open-loop
    replay cannot reproduce the core's dependency stall.

### 7. Fix #5 — per-cycle output arbitration (the dominant lever)
- **Diagnosis.** A latency-component discriminator (env-gate each queue-wait term, re-measure fft
  whose misses isolate the shared paths) pinned the residual on the **interco output arbitration**,
  not the per-set bank (removing the bank wait moved fft 0.1 cy; removing the output wait collapsed
  it +36.7 → +3.9). This overturned both the abstract set_busy hypothesis and §6's "gemv is
  inherent cascade".
- **Root cause.** `output_busy_until_` was a *monotonic* per-output busy-until cyclestamp,
  accumulating across cycles → models sustained 1/cyc backpressure. Correct for CLOSED-LOOP (Spatz:
  the core stalls on the returned latency) but **double-counts in open-loop replay**, where the
  trace's `t_issue` already encodes the RTL backpressure → ~+33 cy phantom hit inflation.
- **Fix.** New `per_cycle_output_arb` interco mode: reset the accept counter each cycle, serialize
  only genuinely same-cycle requests (`output_accept_width`/cyc, default 1). The mode tracks the
  trace's *injection semantics* — default accumulate (closed-loop + max-rate synthetic phases);
  per-cycle opt-in for real-kernel replay (`INSITU_CALIB_PER_CYCLE_ARB`). Closes 85–97 % of the gap
  on 4 kernels (scorecard above) with the accumulate path byte-identical → zero regression.
- **Methodology fix.** Found that gvsoc writes `gvsoc_config.json` to the cwd, so concurrent replay
  processes race on it (±0.3 cy); all final numbers are from strictly sequential runs.

---

## Commits this week

`core` / `pulp` on the `Aquaticfuller/*` forks (pushed); parent on `main` (local).

| Repo | SHA | Subject |
|---|---|---|
| parent | `cffeec5` | pull upstream: rebase insitu-cache + bump engine + elfutils build dep |
| parent | `29788f8` | docs: record upstream-pull push (dev branches + fork master) |
| parent | `4a837e6` | docs: alignment check vs RTL run_2026-06-12 → ALIGNED-CONFIRMED |
| parent | `1613975` | insitu-cache: Phase-B fix #1 (pipelined-bank set_busy) + real-kernel report |
| parent | `cdcebd9` | insitu-cache: Phase-B fix #4 (scalar bypass) + fix #2 (MSHR-drain coalescing) |
| core | `37982db9` | insitu-cache: pipelined-bank set_busy (real-kernel hit-latency fix) |
| core | `49c377d9` | insitu-cache: scalar-bypass port + same-cycle MSHR-drain coalescing |
| core | `6362b3da` | insitu-cache: per-cycle output arbitration (open-loop replay hit-latency fix) |
| pulp | `bdff6f3` | insitu_cache_calib: INSITU_CALIB_COALESCE_MAX_LAT debug knob |
| pulp | `f0706bc` | insitu_cache_calib: INSITU_CALIB_PER_CYCLE_ARB env knob |

Engine bumped to upstream `5863c25e`. Reports added/updated:
`insitu_cache_realkernel_alignment_2026-06-12.md`, `insitu_cache_rtl_coverage_matrix.md`,
`scripts/setup_elfutils_headers.sh`, `prompt/WORKLOG.md`.

---

## Open items / next

- **[DONE] Hit-path serialization residual — closed** by fix #5 (per-cycle output arbitration).
  Hit Δ now +0.3…+4.5 on every kernel; mean +2.6…+6.4 on 4 of 5. The fix root-caused it to the
  interco arbitration (not the wide-cache accept bandwidth originally hypothesised).
- **fdotp miss-path residual (+62.7) is inherent** to open-loop replay (the trace's `t_issue`
  carries the RTL cache timing; a different-timing cache mismatches the data-dependent misses).
  Not a pure cache-model fix — needs a closed-loop injection model. The remaining largest gap.
- **Small mixed-sign miss deltas** (−10.8…+21.7) on the non-fdotp kernels are the new dominant —
  but minor — error; a candidate refinement to the miss/refill-under-load timing if needed.
- **Spatz end-to-end runtime validation** (real workload with `use_insitu_cache=True`) — still
  pending from last week.
- **coal_cold out/latency shape** — last week's lone synthetic-calib open item; remains scoped
  (Phase-B controller MSHR-collapse + install cap), deliberately not forced.
- **Push** the fix #5 commits (core `6362b3da`, pulp `f0706bc`) to the forks — committed locally.

Full detail + reproduction numbers: `prompt/insitu_cache_realkernel_alignment_2026-06-12.md`,
`prompt/insitu_cache_rtl_coverage_matrix.md`, `prompt/insitu_cache_calib_report.md`,
`prompt/WORKLOG.md`.
