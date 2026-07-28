# InSitu Cache — Structure Map (2026-06-22b) — structural rewrite STRUCTURALLY COMPLETE (A1–A5)

Supersedes `insitu_cache_structure_map_2026-06-22.md`. Legend: **✓** approximate model, calibrated
(default runtime) · **◐** structural, runnable + data-correct, gated OFF, UNcalibrated · **▣** transcribed
+ standalone-validated, not wired · **≈** approximated · **✗** not modeled · **N/A**.

> **Change since 2026-06-22 (A1):** the structural cache CELL (A2 coalescer + A3 AMO), the cluster
> SYNCHRONOUS-SLAVE core mode (A4 → **closed-loop vfadd 15/15 PASS, cyc=59001**), and the multi-tile GROUP
> with cross-tile shared L1 (A5 → cross-tile data-correct) all landed. **The whole hierarchy
> GROUP→TILE→cell→core is now built, RTL-faithful, gated default-off.** Single-tile runs real Spatz
> kernels closed-loop; multi-tile routes cross-tile by TileID, data-correct. Remaining = the
> timing-CALIBRATION pass + cluster-level group wiring (DDR4/peripheral) for a 16-core run.

---

## Unified hierarchy (badge = GVSoC model status)

```
CLUSTER                                                  flat tile (default ✓) OR structural tile (◐, opt-in) OR group (◐)
│
├─ GROUP composite (insitu_cache_group.py)               [◐ A5 — N tiles + remote xbars, cross-tile data-correct]
│  ├─ per-port-class REMOTE xbars ×5 (insitu_cache_remote_xbar) [◐ route by target TileID; resp auto-routes back]
│  │     (RTL source-tile-mod-N slot pinning = timing-only, not needed functionally)
│  ├─ L2 fan-in (all tiles → o_L2)                         [◐]   DDR4/NAPOT channel split = ✗ (cluster step)
│  ├─ peripheral / CSR / flush controller / l1d_busy      [✗ MISSING]
│  │
│  └─ TILE ×N (insitu_cache_tile.py structural_tile)      [◐ A1 — runs closed-loop vfadd]
│     ├─ ★ 5 per-port-class xbars (InsituCacheXbar/route) [◐ shared-L1 any-core→any-bank by addr, validated]
│     │     • MSB rotation [✗ A1 off — strided sets, no aliasing] · remote slots [◐ A5]
│     ├─ remote-out/-in ports (cross-tile)                [◐ A5]
│     │
│     └─ cache CELL ×N (per core):
│        ├─ par_coalescer (4 VLSU lanes, InsituCacheCellCoalescer) [◐ A2 — wide-read+split, open-loop only;
│        │     can't batch under sync delivery so OFF for closed-loop]
│        ├─ AMO/LR-SC shim lane 4 (InsituCacheAmo)         [◐ A3 — pass-through validated; RMW closed-loop-only]
│        ├─ SPM remap / flush FSM                          [▣ spm_remap/sync_fsm.hpp; NOT wired]
│        └─ cache CORE (insitu_cache_core)                 [◐ runs; async (open-loop) + sync-slave (closed-loop)]
│           ├─ decode/encode (real XOR-fold hash)           [◐ wired]
│           ├─ 5-wide core port + sync-slave run_request_sync [◐ A4 — analytic inline OK, vfadd PASS]
│           ├─ in-situ MSHR / refill (latency emerges, b.0) [◐]
│           ├─ pseudo-dual bank + WR-conflict               [≈ WR-conflict wired; access-ctrl FSM not]
│           └─ forwarding buffer                            [▣ fwd_buffer.hpp; NOT wired]
```

## Phase status (structural rewrite + tile/group integration)

| Phase | Component | Validation |
|---|---|---|
| Steps 1–7 | all datapath headers (decode/bank/fwd/coalesce/route/spm/sync/amo/l2) | ▣ standalone g++ |
| b.0 | core refill latency emerges + deadlock fix | ◐ calib (cold miss scales w/ ML) |
| A1 | 5 per-port-class xbars + per-core cells (tile) | ◐ data_err=0, routing across banks |
| A2 | per-cell par_coalescer (4 VLSU lanes) | ◐ data_err=0 (wide-read+split) |
| A3 | AMO/LR-SC shim (lane 4) | ◐ pass-through data_err=0 |
| **A4** | **sync-slave core + cluster wiring** | **◐ CLOSED-LOOP vfadd 15/15 PASS, 59001** |
| **A5** | **multi-tile group + remote xbars** | **◐ cross-tile data_err=0 (2-tile)** |

All gated default-off (`structural_tile`, `cell_coalescer`, `amo_lane`, `inline_sync_`/`use_structural_insitu_cache`,
`INSITU_CALIB_GROUP`). Flat path byte-identical (vfadd 58001; calib fmatmul 3.9).

## Remaining

- **Timing CALIBRATION** (the deferred final phase): warm hit 9→10, cold miss ML+12→ML+17, the
  `coal_cold`/`coal_warm` multi-lane merge numbers (needs a same-line multi-lane trace), closed-loop
  `region_cyc`. Tune the per-tick/analytic constants vs `rtl_ref_1t_2026-06-16`.
- **Cluster-level group** for a real 16-core run: wire `InsituCacheGroup` into the cluster (currently the
  cluster builds one tile), DDR4 L2 (`l2_addr.hpp` scramble/NAPOT), peripheral/CSR/flush controller.
- **Wire the remaining ▣ headers** into the runtime (fwd_buffer, spm_remap, sync_fsm) during calibration.

Build/run env: g++-14.2.0 pinned + `LD_LIBRARY_PATH=/usr/pack/gcc-14.2.0-af/lib64` (see [[build_env]]).
Anchors: `insitu_cache_structural_tile_plan_2026-06-18.md`, RTL ref `ManyRVData_rebase/reports/cache_calib/`.
