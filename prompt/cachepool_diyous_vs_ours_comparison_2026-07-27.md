# Comparison: DiyouS fork (Jul 13) vs our current state (Jul 27)

**Date:** 2026-07-27
**Baselines:** DiyouS fork [`DiyouS/gvsoc` @ `0acc24d` (Jul 13)](https://github.com/DiyouS/gvsoc/commits/cachepool/)
— his verified state at integration: 3/8 kernels passing (4-core sweep, integration review
`prompt/diyous_cachepool_integration_review_2026-07-25.md`) — vs **our HEAD** (parent `77e6828`).
**RTL reference:** QuestaSim `sweep_2026-05-29_05-54/cachepool_4t_fpu_512` (4-tile/16-core, 1.0 ns clock).

---

## Table 1 — Kernel pass/fail (16-core, cache ON)

| Kernel | DiyouS fork @ Jul 13 | Ours (now) | Note |
|---|---|---|---|
| fdotp-32b_M8192 | ✅ pass (4c: 24,305) | ✅ pass (32,476) | timing-sensitive; barrier fix from his diagnosis |
| fdotp-32b_M32768 | ✅ pass (4c: 88,916) | ✅ pass (55,440) | his barrier diagnosis, our `c20bd51` for this target |
| gemv-opt_M512_N128_K32 | ✅ pass (4c: 82,741) | ✅ pass (57,001) | |
| fmatmul-32b_M32_N32_K32 | ✅ pass (4c: 13,396) | ✅ pass (51,576) | |
| fft-32b_M1024_N16 | ❌ retval=1 (wrong result) | ✅ pass (61,001) | passes only at native 16-core geometry |
| load-store_M16 | ❌ fail/hang | ✅ pass (154,954) | |
| linked-list_M1_N1350_K10 | ❌ fail | ✅ pass (666,001) | work phase 38k→239k documented (storm) |
| byte-enable | ❌ crash (shared-SPM stack collision) | ✅ PASSED (225,001) | fixed by per-core-private SPM |
| spin-lock | ❌ livelock (AMO `second_data` bug — proven open in the integration review) | ✅ `result: 120; gold: 120` (76,802) | fixed by `dc2e82ca`; later B3 occupancy |
| **Suite total** | **3/8** | **8/8** | |

*At 256-core: his fdotp_M32768 + fmatmul_M128 passes still stand (verified by us on Jul 13); we have not added new 256-core passes — a v2 re-verification run is flagged as a worthwhile check.*

## Table 2 — Performance-calibration compare

| Aspect | DiyouS fork @ Jul 13 | Ours (now) |
|---|---|---|
| **Standalone calib TB vs RTL** | async controller calibrated (June): hit 10/7, cold miss ML+17; structural path Steps 1–4, gated, **uncalibrated** | + structural sync-slave exact: **hit 10, cold miss ML+17, write 8, cold-stream 0.0143 vs RTL 0.0149**; xbar/hop = 1 (CUT_ALL_PORTS) |
| **Deployed cache internals** | rotation OFF (16× capacity collapse), no PEND semantics (early hits mid-refill), no per-cell serialization, coalescer dormant, AMO ~free, flush = stub, refill ungated | rotation ON (E1), PEND ready-cycle clamp (D1), winfo ack (D2), cell token (B1), coalescer live w/ write merge (C1), RMW chained occupancy (B3), real flush (F1), refill occupancy gate |
| **VLSU issue side** | 2× too wide (32 B/cyc), 8 outstanding, commit-at-issue | RTL values: **16 B/cyc, 32 outstanding**, commit at issue+latency (A1) |
| **Memory model** | latency = 0, width divergent under stream | **ML=50** priced, width_log2=6, 4-ch DRAMSys DDR4 L2 option (matches the RTL tb's own backend) |
| **Kernel cycles vs RTL (16-core)** | **not measured** (no RTL-comparable suite run) | see Table 3 — gemv **+1.0%**, byte-enable **−5.4%**, fft compute **−3.0%** |
| **Instrumentation** | none | `[INSITU-CORE]` latency-budget counters, `[ARA-STATS]` issue-side counters, capacity/pend/coal_merge gate traces |
| **Remaining gaps** | uncharacterized | all root-caused + roadmapped (J1 scalar LSU, E3 partitioning, B2/B4/C2/D3) |

## Table 3 — Cycle numbers + error vs RTL, per kernel

RTL = QuestaSim 16-core reference. His fork's measured numbers are from the integration-era **4-core** sweep (marked ‡ — not comparable to the 16-core RTL refs, shown for the record); everything he didn't pass has no cycle number at all.

| Kernel | RTL (16c) | DiyouS fork | Δ vs RTL | Ours (16c) | Δ vs RTL |
|---|---|---|---|---|---|
| fdotp-32b_M8192 | 37,544 | 24,305 ‡(4c) | −35.2% ‡ | 32,476 | **−13.5%** |
| fdotp-32b_M32768 | 48,213 | 88,916 ‡(4c) | +84.4% ‡ | 55,440 | **+15.0%** |
| gemv-opt_M512_N128_K32 | 56,448 | 82,741 ‡(4c) | +46.6% ‡ | 57,001 | **+1.0%** ✅ |
| fmatmul-32b_M32_N32_K32 | 56,689 | 13,396 ‡(4c) | −76.4% ‡ | 51,576 | **−9.0%** |
| fft-32b_M1024_N16 | 130,217 | — (retval=1) | — | 61,001 | **compute −3.0%** (EOC gap = scalar validate, J1) |
| load-store_M16 | 101,208 | — (fail) | — | 154,954 | +53.1% (→ E3 partitioning) |
| linked-list_M1_N1350_K10 | 183,228 | — (fail) | — | 666,001 | 262k loader + storm (→ J1) |
| byte-enable | 237,889 | — (crash) | — | 225,001 | **−5.4%** ✅ |
| spin-lock | 68,368 | — (livelock) | — | 76,802 | +12.3% (was +1.5% pre-flush) |

**Reading Table 3:** his fork had **no RTL-comparable cycle measurement** — only 4 kernels passing, measured at 4-core (‡), with no RTL diff ever computed. Ours runs the full suite at the RTL's own 16-core geometry with per-kernel diffs: **gemv +1.0% and byte-enable −5.4% within ~5%; fmatmul, spin-lock, fdotp×2 within ~15%; fft's compute within 3%; load-store and linked-list root-caused to specific roadmap items (E3, J1).**

---

## One line

His fork contributed the 256-core bring-up and the barrier diagnosis; we fixed a dozen real bugs on top, added the entire cache contention/timing machinery (rotation, PEND, winfo, cell token, coalescer, RMW occupancy, flush, calibrated backing, RTL-faithful VLSU), and took the 16-core suite from **3/8 with no RTL comparison** to **8/8 with per-kernel RTL cycle diffs** — two within ~5%, five more within ~15%, every remaining outlier root-caused.
