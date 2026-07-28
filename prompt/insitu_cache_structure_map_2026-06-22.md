# InSitu Cache — Structure Map (2026-06-22) — structural TILE built (Phase A1): per-port-class xbars + per-core cells

Supersedes `insitu_cache_structure_map_2026-06-18.md`. Legend:
**✓** approximate model, calibrated (default runtime) · **◐** structural, runnable + data-correct, gated
OFF, calibration in progress · **▣** structural datapath transcribed + standalone-validated, NOT wired ·
**≈** approximated · **✗** not yet modeled · **N/A** out of scope.

> **Change since 2026-06-18:** the **structural TILE now exists and is validated** (core `9ad67c88`, pulp
> `6e0da96`). The transcribed `route.hpp` is now **WIRED** into `InsituCacheXbar` (one per port-class), and
> `insitu_cache_tile.py::_build_structural_tile()` composes **5 per-port-class xbars + N per-core
> multi-lane `InsituCacheCore` cells**. Validated open-loop (calib, 4 banks, sample ML=50): **13/13
> respond, data_err=0**, lane-j accesses route across all 4 banks by address, responses return to the
> originating ports — the **shared-L1 intra-tile routing is faithful + data-correct**. Gated behind
> `structural_tile` (default off; flat tile byte-identical). Also b.0 (refill latency emerges) shipped
> 06-16/21. Toolchain pinned to g++-14.2.0 (see memory [[build_env]]).

---

## Unified hierarchy (badge = GVSoC model status)

```
CLUSTER                                                  model: single flat tile — structural composite Step 7
│
├─ Inter-tile / remote-access xbar ("R" nodes)           [▣ route.hpp wired in xbar; remote slots OFF (single-tile)]
├─ Peripheral — cache_sync/L1D CSRs + partition          [✗ MISSING]
├─ Refill AXI Mux 512b 16→1 → L2/DDR4                     [✗ Step7]   model: flat l2_router fan-in [✓]
├─ AMO / LR-SC tile shim (scalar lane j=4)               [▣ amo.hpp transcribed; NOT wired — A3]
├─ Cluster L2 RR arbiter / DDR4 channels                 [✗ MISSING]
│
└─ GROUP (×N)                                            [✗ A5 — no group composite yet]
   ├─ remote xbar 4→4 (source-tile-mod-N)                [▣ route.hpp covers it; composite ✗]
   └─ TILE (×4)                                          ◐ STRUCTURAL TILE BUILT (single-tile, gated)
      ├─ CC0..CC3 — Spatz cores × 5 TCDM ports            [≈ exist]
      │
      ├─ ★ 5 per-port-class xbars (SHARED-L1 routing)     [◐ DONE — InsituCacheXbar ×5, route.hpp]
      │     • any core lane-j → any bank BY ADDRESS         ── validated data_err=0 across 4 banks ✓
      │     • MSB rotation (hide routing bits)              ── [✗ A2; off in A1 → strided set use, no aliasing]
      │     • remote ports (cross-tile)                     ── [✗ A5; num_remote_port_core=0 now]
      │
      └─ L1 D$ = per-core SHARED BANKS (cache cell):
         ├─ par_coalescer (4 VLSU lanes → 1 wide beat)      [▣ coalesce.hpp; NOT wired — A2]
         │     runtime: multi-lane core processes lanes serially (no merge yet)
         ├─ internal 2:1 bypass (scalar lane)               [▣ route.hpp BypassXbar; NOT wired — A2]
         ├─ SPM partition / flush FSM                       [▣ spm_remap/sync_fsm.hpp; NOT wired]
         └─ cache CORE (insitu_cache_core, multi-lane)      [◐ runs in tile, data_err=0]
            ├─ decode/encode (real XOR-fold hash)            [◐ wired]
            ├─ 5-wide core port (num_input_ports)            [◐ DONE — lanes feed one in_q_]
            ├─ in-situ MSHR / refill (latency EMERGES)       [◐ b.0 — cold miss scales w/ ML, serialized]
            ├─ pseudo-dual bank + WR-conflict                [≈ WR-conflict wired; access-ctrl FSM not]
            └─ forwarding buffer                             [▣ fwd_buffer.hpp; NOT wired]
```

## Component-datapath status (microarchitecture inventory)

| Component (file) | Transcribed | In runtime? | Notes |
|---|---|---|---|
| decode/encode (`insitu_cache_decode.hpp`) | ✅ | ✅ core | real hash-way |
| pseudo-dual bank (`bank_array.hpp`) | ✅ | ◐ partial | WR-conflict wired |
| forwarding buffer (`fwd_buffer.hpp`) | ✅ | ❌ | A2+ |
| cache core (`insitu_cache_core.{cpp,py}`) | ✅ | ◐ **runs in tile**, b.0 refill emerges, multi-lane port | |
| **per-port-class xbar (`insitu_cache_xbar` + `route.hpp`)** | ✅ | ◐ **WIRED + validated** | 5/tile, shared-L1 routing |
| par_coalescer (`coalesce.hpp`) | ✅ | ❌ | A2 — into the cell |
| AMO/LR-SC (`amo.hpp`) | ✅ | ❌ | A3 — lane 4 |
| route SPM/sync (`spm_remap/sync_fsm.hpp`) | ✅ | ❌ | later |
| L2 scramble/NAPOT (`l2_addr.hpp`) | ✅ | ❌ | A5/cluster |

**Still missing entirely:** write-through merger + WT FIFO; group/cluster composite; peripheral/CSR/
flush-controller/l1d_busy; DRAMSys DDR4.

## Build/validation status

- **Structural tile (A1): DONE + validated** — 5 xbars route any lane→any bank by address, data_err=0;
  fallbacks byte-identical. Gated `structural_tile` (default off).
- **Open-loop calib:** b.0 cold-miss latency emerges + scales (56@ML50, 106@ML100); serialized misses.
- **Next:** A2 structural cache CELL (par_coalescer on 4 VLSU lanes + internal 2:1 bypass + core),
  validated vs the calib cell reference (warm hit 10/7, coal_cold) → A3 AMO (lane 4) → A4 sync-slave mode
  (analytic) → closed-loop vfadd → A5 group (remote xbars + source-tile-mod-N + DDR4).

Anchors: tile plan `insitu_cache_structural_tile_plan_2026-06-18.md`; gap audit
`insitu_cache_precalibration_gap_audit_2026-06-16.md`; RTL ref `ManyRVData_rebase/reports/cache_calib/`.
