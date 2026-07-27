# First RTL-vs-GVSoC per-kernel cycle diff (16-core, streams through cache)

**Date:** 2026-07-27 · **Status:** provisional reference — model side final (post-E4); RTL side from an
older revision sweep (see caveat).
**RTL reference:** `ManyRVData_rebase/reports/sweep_2026-05-29_05-54/cachepool_4t_fpu_512/logs/*.log`
(insitu-cache `2710920`, CombLoop-fix sweep, 4-tile/16-core fpu_512 — same geometry + same binary set as
the model). EOC line: `Simulation ended at <T> (retval = 0)`; `tb_cachepool.sv` `ClockPeriod = 1.0ns`
→ **cycles = T/1000**. All 9 kernels retval=0.
**Model:** post-E4 build (A1+E1+D1+D2+B1+C1+E4), 16-core 4×4, cache ON, streams cached.

## 1. The table

| Kernel | RTL cyc (ref) | GVSoC cyc | Δ (model−RTL) | model ×RTL | verdict |
|---|---|---|---|---|---|
| gemv-opt_M512_N128_K32 | 56,448 | 62,427 | +10.6% | 1.11× | ✅ within ~10% |
| byte-enable | 237,889 | 204,981 | −13.8% | 0.86× | ✅ close |
| fdotp-32b_M32768 | 48,213 | 58,515 | +21.4% | 1.21× | 🔶 ~20% |
| fdotp-32b_M8192 | 37,544 | 26,963 | −28.2% | 0.72× | 🔶 ~30% fast |
| fmatmul-32b_M32_N32_K32 | 56,689 | 38,117 | −32.8% | 0.67× | 🔶 ~30% fast |
| fft-32b_M1024_N16 | 130,217 | 53,514 | **−58.9%** | 0.41× | ⛔ 2.4× fast |
| spin-lock | 68,368 | 26,636 | **−61.0%** | 0.39× | ⛔ 2.6× fast |
| load-store_M16 | 101,208 | 566,576 | **+459.8%** | 5.60× | ⛔ 5.6× SLOW |
| linked-list_M1_N1350_K10 | 183,228 | 2,216,153 | **+1109.6%** | 12.1× | ⛔ 12× SLOW |

## 2. What the errors line up with (each maps to a known gap)

- **load-store 5.6× slow → E3 (runtime partitioning).** The kernel calls `l1d_part` and runs its main
  phases half-half (RTL: private-region traffic = local banks, no remote hops; model: everything sprays
  all 16 banks + remote hops). The review predicted exactly this dominance for this kernel.
- **spin-lock 2.6× fast → B3 (AMO RMW lane occupancy).** RTL holds the bank-shared scalar lane for the
  full RMW (~15–20 cy); the model's AMO shim resolves atomically in-call. B1's +10.6% was only the
  pipeline serialization; the RMW occupancy is unmodeled.
- **fft 2.4× fast → F1 (flush FSM) + P3.1 (DRAM timing).** fft is the warm-cache/flush-heavy kernel:
  the model's flush is a zero-cycle stub (RTL: ~21+256 cy/bank + per-dirty eviction), and the flat
  fixed-latency refill ignores DRAM burst/conflict effects on multi-pass streams.
- **linked-list 12× slow → NEW top mystery.** RTL ≈ 13.5 cyc/op (mostly L1 hits after warmup — the
  node region is ~21 KiB, trivially resident); model ≈ 164 cyc/op (everything misses + serializes).
  Capacity math says it should fit (E1 rotation is on) — so this smells like a *placement/aliasing or
  sync-protocol bug*, not a calibration knob. Highest-investigation-value item: likely a model bug.
- **fdotp/fmatmul ~20-30% fast, gemv/byte-enable ~10-15%.** The cross-cutting remainder is the
  idealized backing store (flat fixed-latency refill vs real DRAM burst/channel timing) — **P3.1**
  (L2 channel demux + DDR4/DRAMSys), plus possibly C2 window effects on the hit path.

## 3. Re-prioritized attack order (from measured error, largest first)

1. **R1: linked-list 12× anomaly** — diagnose (suspected model bug, not calibration).
2. **R2: E3 `l1d_part` runtime partitioning** — load-store 5.6× (plumbing exists in route.hpp).
3. **R3: B3 AMO RMW lane occupancy** — spin-lock 2.6× (~30 lines + 1 knob per the review).
4. **R4: F1 flush FSM** — fft 2.4× (transcription already exists: insitu_cache_sync_fsm.hpp).
5. **R5: P3.1 L2 channel demux + DRAM timing** — the ±20-30% residue on fdotp/fmatmul/gemv.

## 4. Caveats

- The RTL numbers are from the **2026-05-29 sweep (insitu-cache `2710920`)**, not the current
  `dev/multi-group @ 05e4671a` reference revision. The CombLoop fix was combinational-only
  ("no perf change"), and the gross errors (≥2.4×) dwarf any revision drift — but before declaring
  <10% on any kernel, re-run the RTL CI on the current revision for a definitive reference.
- GVSoC EOC cycles are simulator cycles at 10 MHz (the model's clock domain); ratio comparison is
  clock-rate-independent.
