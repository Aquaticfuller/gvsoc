# InSitu Cache — Structure Map (2026-06-16b) — all component datapaths transcribed; integration health checked

Supersedes `insitu_cache_structure_map_2026-06-16.md`. Legend: **✓ approximate model, implemented +
calibrated (runs today)** · **◐ structural, runnable + data-correct, gated OFF, UNcalibrated** · **▣
structural datapath transcribed + standalone-validated, not yet wired into the runtime tick** · **≈
approximated** · **✗ not yet modeled** · **N/A** out of scope.

> **Change since 2026-06-16:** Step 7's **datapath components** landed (AMO/LR-SC + L2 scramble/NAPOT,
> core `32950f40`), completing the component-transcription mandate — **every planned microarchitecture/
> architecture component now has real RTL logic** (Steps 1–7 datapath, all standalone-validated). The
> structural cache core was **build-verified in-tree** and run end-to-end through the integrated
> open-loop calib path with **data_err=0** (functional gate PASS).
>
> **What remains: COMPOSITION + CALIBRATION (the final, build-loop-dependent phase).**
>
> **Shared-L1 reminder:** L1 is shared, not private — `insitu_cache_route.hpp` now models the real
> any-core→any-bank routing (all-private/all-shared/mixed + MSB rotation).

---

## Component datapaths — all transcribed (▣) + standalone-validated

| Step | Component (file) | RTL source | Validation |
|---|---|---|---|
| 1 | decoder/encoder (`insitu_cache_decode.hpp`) | decoder.sv/encoder.sv | hash-way + classify + LRU, g++ |
| 2 | pseudo-dual-port bank (`insitu_cache_bank_array.hpp`) | tcdm_wrapper/pseudo_dual_port | classify + WR-conflict scoreboard, g++ |
| 3 | forwarding buffer (`insitu_cache_fwd_buffer.hpp`) | sram_forwarding_buffer.sv | read-suppress/absorb/WB/RAW, g++ |
| 4 | **cache core** (`insitu_cache_core.{cpp,py}`) | core.sv/top.sv | ◐ **runs in-tree, data_err=0** |
| 5 | par_coalescer (`insitu_cache_coalesce.hpp`) | par_coalescer_*/req/rsp | wide-merge + split, g++ |
| 6 | route+SPM+sync (`insitu_cache_{route,spm_remap,sync_fsm}.hpp`) | tcdm_cache_interco/partitionable/wrapper | 51-check g++ |
| 7 | AMO+L2 (`insitu_cache_{amo,l2_addr}.hpp`) | spatz_cache_amo/cluster/pkg | 38-check g++ |

All gated default-off; the calibrated approximate path (`✓`) stays default and untouched.

## Integration health (this session)

- **Build green** (`BUILD_EXIT=0`) for `insitu_cache_calib` / `insitu_cache_tb` with the structural core
  compiled in-tree. The new headers are header-only / unreferenced → zero build impact (standalone
  self-tests are their validation).
- **Structural core end-to-end via the calib path** (env hook `INSITU_CALIB_STRUCTURAL_CORE=1`, default
  off): **`data_err=0`** on the `sample` replay — functionally correct.

## ⚠ Calibration entry point — the refill-latency finding (sample trace, ML=50)

| path | cold-miss read latency | total cyc | matches RTL? |
|---|---|---|---|
| calibrated controller (✓) | 67..536 (models ML+serialize) | 546 | yes (the calibrated baseline) |
| **structural core (◐)** | **1..4 (ignores refill latency!)** | **13** | **no — timing uncalibrated** |

**Root cause (concrete, for the calibration phase):** in `insitu_cache_core.cpp::drain_outputs()`, when the
refill responder returns `IO_REQ_OK` synchronously, the core marks the line installable next tick and
**discards the latency the responder stamped on `refill_req_` (`inc_latency`)** → cold misses resolve in
~pipeline cycles. With the *async* responder (the earlier fmatmul single-tile run) it instead
over-serializes on the single-outstanding gate (~251 vs RTL ~18). So the timing-calibration pass must make
**refill latency EMERGE under BOTH responder modes**: defer the install by the stamped/measured refill
latency (sync responder) and relax single-outstanding to the RTL outstanding cap (async). Data is correct
either way (the functional array is filled synchronously) — this is purely the emergent-latency wiring.

## Remaining work — composition + calibration (final phase, needs the build/sim loop)

```
[✗ Step7 composition]  cachepool_tile.py  — 5 per-port-class InsituCacheXbar + 4 cores + spill + AMO(lane4) + tile flush
[✗ Step7 composition]  cachepool_group.py — 4 tiles + 5 remote xbars (source-tile-mod-N slot)
[✗ Step7 composition]  cachepool_cluster.py — group + NAPOT L2 xbar (insitu_cache_l2_addr.hpp) + peripheral + DRAMSys DDR4
[✗ Step7 must-fix #1]  cluster SYNCHRONOUS-SLAVE inline mode in insitu_cache_core.cpp — run the per-cycle
                       FSM to completion inside the request, inc_latency(emergent), return IO_REQ_OK (the
                       Spatz v1-ISS LSU is synchronous-only; mirror the controller's inline_sync_miss).
[✗ calibration]        wire the validated headers' per-cycle timing into the tick (fwd-buffer read-suppress,
                       coalescer CSHR window, sync drain) + fix the refill-latency emergence above; diff
                       per-access + region_cyc vs rtl_ref_1t_2026-06-16. Promote structural_mode=True only
                       when (a) structural vfadd 15/15, (b) open-loop per-access within band, (c) closed-loop
                       region_cyc within target.
```

Full plan + must-fixes: `insitu_cache_structural_plan_2026-06-16.md`.
