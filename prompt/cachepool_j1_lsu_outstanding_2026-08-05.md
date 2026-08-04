# J1 — scalar LSU outstanding depth (RTL value) + the AMO stall-on-use fix it exposed

2026-08-05 · core `pending` · pulp `pending` · status: **landed, 9/9 data-correct, net calibration win**

J1 brings the scalar LSU's outstanding-request depth to the RTL value. Scoping found the ISS
plumbing already in place (scoreboard stall-on-use always on; the `CONFIG_GVSOC_ISS_LSU_NB_OUTSTANDING`
machinery in `lsu.cpp` is production code used by other cores at depth 8), so the intended change
was one line. The 16-core sweep then exposed a real ISS bug that the depth change makes reachable.

## 1. The change

- **RTL value**: `snitch_max_trans = 16` (`config/cachepool_fpu_512.mk:87` →
  `NumIntOutstandingLoads/Mem = 16`). The model built with the ISS default `nb_outstanding=1`.
- **Wiring** (`pulp/pulp/snitch/snitch_cluster/snitch_cluster.py`): `SnitchFast(...,
  nb_outstanding=…)` for cachepool targets only (gated on `arch.cachepool_num_tiles`, which only
  `pulp/cachepool.py` sets — other snitch/spatz targets keep the default 1). Env override
  `CACHEPOOL_LSU_OUTSTANDING` (default 16) — **build-time** knob, like the other CACHEPOOL_*
  knobs (the value enters the ISS `.so` via `-D`; changing it needs a rebuild).

## 2. The bug it exposed: sync-OK AMOs free-ran at nb>1

First sweep at nb=16: spin-lock EOC **76,802 → 1,622,001** (21×), still data-correct
(result 120). Counters: cache banks idle, but the AMO shims processed **43,170 RMWs** (pre-J1
~3.3k). Root cause in `Lsu::atomic()` (`lsu.cpp`): the synchronous-OK branch under
`CONFIG_GVSOC_ISS_LSU_NB_OUTSTANDING` freed the slot after the AMO's latency
(`free_req(now+latency)` — throughput accounting) but **never marked the destination register
pending** — unlike the nb=1 branch and the async branch, which both do. A result-consuming
spin loop (`amoswap t0,…; bnez t0,…`) therefore never stalled on the poll value and free-ran
at 16-deep poll rate per core; 16 cores × 16-deep polls flooded the lock bank's B3 RMW window
(~35 cy each), and the lock holder's release queued behind the storm → 43k RMWs, 1.6M cycles.

The RTL Snitch blocks on the AMO response (AMOs aren't scoreboarded past the LSU), so each
poll pays the round trip. **Fix**: in the sync-OK branch, also
`scoreboard_reg_set_timestamp(reg_out, req->get_latency()+1, …)` — stall-on-use composed with
the existing slot-busy window (the setter is relative and max-combining, so overlapping AMOs
to the same register are safe). Compiled only when both `NB_OUTSTANDING` and `SCOREBOARD` are
defined → nb=1 targets (plain snitch/spatz) are byte-identical.

Post-fix: spin-lock **76,628** (+12.1% vs RTL 68,368 ≈ the pre-J1 +12.3%), RMWs back to
**3,267**, result correct. The async-AMO path already invalidated/scoreboarded correctly; only
the sync-OK path was missing it.

## 3. Sweep (16-core, cache ON, all retval=0, zero FAIL)

| kernel | pre-J1 (nb=1) | post-J1 (nb=16+fix) | RTL | Δ before → after |
|---|---|---|---|---|
| fmatmul_M32 | 46,001 | 51,001 | 56,689 | −18.9% → **−10.0%** |
| fdotp_M8192 | 31,443 | 32,652 | 37,544 | −16.2% → **−13.0%** |
| linked-list_M1 | 937,001 | 680,001 | 183,228 | −27.4% (still 3.7× — loader + drain storm) |
| spin-lock | 76,802 | 76,628 | 68,368 | +12.3% → +12.1% |
| fdotp_M32768 | 56,484 | 56,001 | 48,213 | +17.1% → +16.2% |
| gemv-opt | 61,4xx | 62,001 | 56,448 | +8.8% → +9.8% |
| load-store_M16 | 183,757 | 183,001 | 101,208 | +81.6% → +80.8% |
| fft_M1024 | 61,001 | 62,001 | 130,217 | ~flat |
| byte-enable | 225,001 | 225,001 | 237,889 | −5.4% (unchanged) |

(pre-J1 baselines: fdotp_M32768/load-store re-measured same-day on the E3.5 tree; the rest from
the E3.3-era sweep — E3.4/E3.5 were kernel-timing-inert, so the baselines are same-state.)

## 4. What J1 explains — and what it refutes

- **Confirmed effects**: the "too-fast" family improved (fmatmul −18.9→−10.0, fdotp_M8192
  −16.2→−13.0) — deeper store/load pipelining + slot-busy backpressure slows the vector kernels'
  issue side toward RTL. Linked-list improved 27% (queue ops pipeline).
- **Refuted**: fft's EOC residual and load-store's locality gap are **not** LSU-depth-bound
  (both ~flat). fft's scalar init/validate phases are instruction-issue-side, not memory-depth —
  move that residual out of J1; load-store's remaining gap stays with the flush-gating +
  hash-way-collapse + scalar-check terms (E3.6 report §3).
- The AMO stall-on-use gap is worth upstreaming: any GVSoC core running `nb_outstanding>1` +
  AMO spin loops hits the same free-run pathology.

## 5. Files

- `core/models/cpu/iss/src/lsu.cpp` — sync-OK AMO scoreboard fix (nb>1 path only).
- `pulp/pulp/snitch/snitch_cluster/snitch_cluster.py` — cachepool `nb_outstanding=16` +
  `CACHEPOOL_LSU_OUTSTANDING` knob.

Verification: full 9/9 sweep above; spin-lock A/B pre/post fix (1,622,001 → 76,628); calib
battery untouched (ISS-only change; the calib TB has no ISS). Spatz/snitch non-cachepool
targets: the fix is preprocessor-dead at nb=1 (verified by construction — the added block sits
inside the `NB_OUTSTANDING`+`SCOREBOARD` branch), and their `.so`s were not rebuilt here.
