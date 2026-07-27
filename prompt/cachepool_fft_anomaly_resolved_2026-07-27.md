# #24 — fft anomaly resolved: compute matches within ~6%; the residual is scalar-side (J1)

**Date:** 2026-07-27 · **Status:** CLOSED (explained; residual reassigned to J1)
**Question:** why was fft 2× too fast (61,001 vs RTL 130,217)?

## Verdict up front

fft's butterfly **compute** matches RTL within ~6%. The total-EOC gap is in the
boot/init/validate scalar phases and belongs to the J1 (scalar-LSU) family, not to any
fft-specific cache or stride mechanism. The stride/bank-conflict hypothesis is **dead** —
the model's bank distribution is fine.

## Evidence

1. **The RTL's own kernel prints** (`sweep_2026-05-29_05-54/.../fft-32b_M1024_N16.log`):
   `First execution took 9952 cycles`, `The execution took 5946 cycles`, and the perf dump
   `Total Kernel Cycles: 16441` — the RTL's butterfly compute window is only ~16k cycles of
   its 130,217-cycle EOC; the remaining ~114k is boot + input/gold init + the two
   `for (i<NFFT) fp_check(...)` validation passes + exit.
2. **The model's same prints:** `First execution took 8216` (−17% vs RTL), `The execution
   took 7212` (+21%). Sum 15,428 vs RTL 15,898 = **−3.0%** — compute matches. (The model's
   warm second pass barely improves on its first — its cold path is already fast; the RTL
   gains much more from warmth. Noted, not blocking.)
3. **New per-core Ara issue-side counters** (`[ARA-STATS]`, dumped at sim stop): fft/core =
   126 vloads, 80 vstores, 6,432 bursts, 152 FPU insns (1,216 busy cycles), 0 vslide — the
   vector work is ~15% of the 61k cycles; the kernel is scalar/validate-dominated on *both*
   simulators.
4. The residual (model ~45k vs RTL ~114k non-compute) is the scalar init/validate loops —
   per-iteration dependent L1 accesses + float compares; exactly the **J1 scalar-LSU
   asymmetry** (RTL's 16-outstanding stall-on-use with real per-access latency vs the
   model's sync pipelining).

## Instrumentation added (kept)

- `AraVlsu` (spatz variant): `dbg_loads/dbg_stores/dbg_bursts` (handle_access + burst issue).
- `AraVcompute`: `dbg_insns/dbg_busy` (per-instruction duration sum).
- `Ara::dump_stats()` → `[ARA-STATS <core>]`, called from the **snitch_fast** IssWrapper's
  `stop()` (NOT the generic `iss.cpp` wrapper — the cachepool cores are SnitchFast; an edit
  to `iss.cpp` compiles but is dead for this target. Trap recorded in the worklog).
- fft trace-capture note: `--trace=.../insn` on this kernel is far too slow to reach the
  compute phase; the stop-time counters are the right tool.

## Consequences

- fft's diff-doc row updated: compute −3.0% (two passes −17%/+21%), EOC residual = scalar
  phases (J1). Removed from the "mystery" list.
- J1 (scalar LSU scoreboard, `nb_outstanding=16` + stall-on-use) is confirmed as the top
  issue-side item: it is the remaining explanation for fft's validate gap, load-store's
  +53%, and linked-list's drain-rate storm.
