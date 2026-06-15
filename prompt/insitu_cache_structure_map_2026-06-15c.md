# InSitu Cache — Structure Map (2026-06-15c) — after Phase-2 increment 1

Supersedes `insitu_cache_structure_map_2026-06-15b.md`. Legend: **✓ implemented + calibrated** · **≈ approximated / partial** · **◐ structural, implemented + validated but gated OFF** · **✗ not yet modeled** (→ Phase) · **N/A** out of scope.

> **Change since 2026-06-15b (Phase-2 inc1):** the model can now build **one cache controller per core** within a tile (RTL `NumL1CacheCtrl = NumCores`), via `controllers_track_cores` (default **OFF**; core `d821214b` / pulp `b88f878`). When on, the cluster sets `num_controllers = nb_core` (verified: nb_core=2 → interco `N=10 M=2`, 2 controllers, vfadd passes). The model's **address routing was already RTL-faithful** (`(addr>>dynamic_offset)&mask`), so the L1-sharing node stays ✓ for intra-tile; what inc1 fixes is the **cardinality** (was hard-wired 4). Still gated OFF (default cluster = 4 controllers, vfadd 58001) until the per-port-class xbars (inc2) + capacity scaling (inc3) make it fully comparable. **Per-controller capacity not yet RTL-scaled** (total tile capacity tracks controller count → inc3).
>
> **Shared-L1 reminder:** L1 is shared, not private — the Tile L1 Xbar routes any core to any bank by address, extended cross-tile by the remote xbars.

---

## Unified hierarchy (badge = GVSoC model status)

```
CLUSTER                                                          model: single flat tile only — no cluster/group scale
│
├─ Inter-tile / remote-access xbar ("R" nodes)                   [✗ P2-inc5]   any CC → another tile's banks, by address
├─ Peripheral — cache_sync / L1D-flush CSRs + partition regs      [✗ P4]
├─ Refill AXI Mux 512b 16-to-1                                    [✗ P2]
├─ AMO / LR-SC tile shim (scalar lane, reservation table)        [✗ P5]
├─ Cluster Barrier                                               [N/A]
│
└─ GROUP (×N)                                                    [✗ P2-inc5 — model has none]
   ├─ LG Xbar 32b 4-to-4 · RG-to-T · Router                      [✗ P2]
   ├─ Bank Refill Xbar 512b 16×8 (→L2)                           [✗ P2]   model: simple L2 fan-in router [✓]
   ├─ AXI Mux · L2 I$ (RO) 8 KiB                                 [N/A]
   │
   └─ TILE (×4 per group)                                        model = ONE flat tile (1-tile only)
      ├─ CC0..CC3 — 4 Spatz cores (Snitch + Spatz vector)        [≈ exist; model builds nb_core/tile, default 2]
      │     each drives 5 TCDM ports (1 scalar + 4 VLSU lanes)
      ├─ L1 I$ (RO) · AXI Interco · Tile Barrier                 [N/A]
      │
      ├─ ★ Tile L1 Xbar 32b (4+X)→(4+X) — SHARED-L1 FABRIC       [≈]
      │     • ANY core → ANY bank BY ADDRESS (shared, not private) ── model: hashed N→M interco [✓]
      │       (one monolithic arbitration domain; RTL has 5 per-port-class xbars → P2-inc2)
      │     • +X remote ports (→LG/→RG) for cross-tile sharing     [✗ P2-inc5]
      │     • programmable address mapping                         [✗ P2-inc4]
      │     • runtime bank partition (private ↔ shared)            [✗ P2-inc6]
      │
      └─ L1 D$ = per-core SHARED BANKS  (one cache per core)       [◐ P2-inc1]  ◀── NEW: controllers_track_cores
         │   model: num_controllers = nb_core when flag on (validated nb_core=2→2 ctrls); default off = 4.
         │   capacity per controller NOT yet RTL-scaled → P2-inc3.
         └─ per-bank cache = cachepool_cache_ctrl (one wide 512b cache):
            ├─ par_coalescer (hitmap · 512b wide-merge · rsp-split)  [◐ P1]  structural component landed (gated),
            │      same-cycle/same-line read merge validated byte-identical; wide-merge/split = later.
            ├─ scalar bypass_xbar (2:1)                              [✗ P1/P2]  model: scalar latency knob   [≈]
            ├─ 4-beat refill burst FSM                               [✗ P1]  model: single-slot install   [≈]
            └─ single-wide 512b cache core                           [≈ geometry ok; structure pending]
               ├─ tag array + decoder/encoder (states, hit/miss)     [✓]
               ├─ LRU / hash-way victim                              [✓]
               ├─ in-situ MSHR (pending track + same-line merge)     [≈ side-deque]
               ├─ forwarding buffer (RAW fast path)                  [≈ 1 tracker]
               ├─ refill/eviction + occupancy (install-pipe)         [✓ defer_refills]
               ├─ pseudo-dual banks + WR-conflict penalty            [✗ P6]  model: set_busy cyclestamp   [≈]
               ├─ SPM partition (division-remap + separate path)     [✗ P4]  model: capacity-shrink fold  [≈]
               └─ flush/sync FSM (7-state, 4 cache_sync ops)         [✗ P4]  model: dormant flush_all() stub
```

**Open-loop calibrated (unchanged):** warm hit 10/7 · cold miss ML+17 · miss/coalesce/evict thr ≤7% · ceiling ~0.86.
**Closed-loop:** vfadd 15/15, cyc=58001 ✓ (default 4-controller topology).

## Phase-2 progress (topology → closed-loop comparison)

| Increment | Status |
|---|---|
| inc0. RTL single-tile reference cycle capture (`cachepool_1t.mk`, Burst=4) | ✗ **needs RTL sim run** (user / RTL env) |
| inc1. Per-core controller cardinality (`controllers_track_cores`) | ✅ **DONE** (core `d821214b`, pulp `b88f878`, gated off) |
| inc2. Per-port-class xbar fan-out (5 independent arbitration domains) | ✗ next |
| inc3. Per-controller capacity re-size to RTL (`capacity_tracks_rtl`) | ✗ |
| inc4. Programmable bank-mapping xbar + inert remote slot | ✗ |
| inc5. Inter-tile GROUP composite + remote-hop latency (num_tiles>1) | ✗ |
| inc6. Runtime private/shared partition (`num_private_cache`) + addr rotation | ✗ |

(Phase-1 par_coalescer foundation done in `2026-06-15b`. Full plan: `insitu_cache_dev_plan_2026-06-15.md`.)
