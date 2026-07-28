# InSitu Cache — Unified Structure Map (implemented + not-yet-modeled) — 2026-06-15

Status legend: **✓ implemented + calibrated** · **≈ approximated (latency-only / partial)** · **✗ not yet modeled** (→ Phase) · **N/A out of scope**.

> **The L1 is SHARED, not private.** The 4 "per-core" L1 D$ controllers in a tile are address-interleaved **banks of one shared L1**: the **Tile L1 Xbar routes ANY core's request, by address, to the owning bank** — its own *or another core's*. The remote xbars (LG/RG + inter-tile) extend the same address-routed sharing across all 4 tiles, so all 16 cores share one L1 address space. "One cache per core" is only *physical placement*; functionally every bank is reachable by every core.
>
> **What the model does with this:** the GVSoC model's **hashed N→M interco → 4 controllers IS the intra-tile address-routed sharing** (any input port reaches any of the 4 banks by address) — so sharing *within one tile* is captured. What it lacks is the **cross-tile/remote** sharing, the **programmable mapping + partitioning**, and the **per-core cache structure** (single-wide cache + coalescer/bypass front-end). The model is one flat tile, no Group/Cluster.

---

## Unified hierarchy (badge = GVSoC model status; "model:" = what the model does instead)

```
CLUSTER                                                              model: single flat tile only — no cluster/group scale
│
├─ Inter-tile / remote-access xbar  ("R" nodes)                      [✗ P2]
│     → any CC reaches ANOTHER TILE's banks, routed by address (shared L1 spans all tiles)
├─ Peripheral — cache_sync / L1D-flush CSRs + partition-config regs  [✗ P4]
├─ Refill AXI Mux  512b  16-to-1                                     [✗ P2]
├─ AMO / LR-SC tile shim (scalar lane, reservation table)           [✗ P5]
├─ Cluster Barrier                                                   [N/A]
│
└─ GROUP (×N)                                                        [✗ P2 — model has none]
   ├─ LG Xbar 32b 4-to-4   (local↔group shared-bank routing)         [✗ P2]
   ├─ RG-to-T · Router                                               [✗ P2]
   ├─ Bank Refill Xbar 512b 16×8  (line-refill fabric → L2)          [✗ P2]   model: simple L2 fan-in router  [✓]
   ├─ AXI Mux                                                        [N/A]
   └─ L2 I$ (RO) 8 KiB                                               [N/A]
   │
   └─ TILE (×4 per group)                                            model = ONE flat tile
      ├─ CC0..CC3 — 4 Spatz cores (scalar Snitch + Spatz vector)     [≈ cores exist; model builds 2/tile, not a 4-CC tile]
      │     each drives 5 TCDM ports (1 scalar + 4 VLSU lanes)
      ├─ L1 I$ (RO) 8 KiB · AXI Interco · Tile Barrier               [N/A]
      │
      ├─ ★ Tile L1 Xbar 32b (4+X)→(4+X)  — THE SHARED-L1 FABRIC      [≈]
      │     • routes ANY core → ANY bank BY ADDRESS (shared, not private)   ── model: hashed N→M interco  [✓]
      │     • +X ports = remote in/out (→LG / →RG) for cross-tile sharing   [✗ P2]
      │     • programmable address mapping                                  [✗ P2]
      │     • runtime bank partition (private ↔ shared)                     [✗ P2]
      │
      └─ L1 D$ = 4 address-interleaved SHARED BANKS  (256 KiB / tile)       model: 4 controllers = the 4 banks  [✓ sharing analog]
         │   ONE cache per core physically, but every bank reachable by every core via the xbar (NOT private)
         └─ per-bank cache = cachepool_cache_ctrl (one wide 512b cache):
            ├─ par_coalescer (real): hitmap · 512b wide-merge · rsp-split   [✗ P1]   model: latency-window approx   [≈]
            ├─ scalar bypass_xbar (2:1 Snitch-scalar)                       [✗ P1]   model: scalar latency knob     [≈]
            ├─ 4-beat refill burst FSM                                      [✗ P1]   model: single-slot install     [≈]
            └─ single-wide 512b cache core                                  [✗ P1 structure;  internals below:]
               ├─ tag array + decoder/encoder (line states, hit/miss)       [✓]
               ├─ LRU / hash-way victim select                              [✓]
               ├─ in-situ MSHR (pending-line tracking + same-line merge)     [≈ side-deque]
               ├─ forwarding buffer (RAW fast path)                         [≈ 1 tracker, no FSM]
               ├─ refill / eviction + occupancy (install-pipe serialize)     [✓ defer_refills]
               ├─ pseudo-dual-port banks + WR-conflict penalty              [✗ P6]   model: set_busy cyclestamp     [≈]
               ├─ SPM partition (division-remap + separate access path)     [✗ P4]   model: capacity-shrink fold    [≈]
               └─ flush / sync FSM (7-state, 4 cache_sync ops, interlock)    [✗ P4]   model: dormant flush_all() stub
```

**Open-loop calibrated:** warm hit 10/7 · cold miss ML+17 · miss/coalesce/evict throughput ≤7% · ceiling ~0.86  (all ✓).
**Closed-loop:** vfadd 15/15, cyc=58001 ✓ (cluster-gated `inline_sync_miss` + `functional_writethrough`).

---

## Status table

| Block / mechanism | Status | Phase |
|---|---|---|
| Intra-tile address-routed shared banks (any core → any bank) | **✓** (hashed interco → 4 ctrls) | — |
| Per-controller tag array + hit/miss + LRU/hash victim | **✓** | — |
| In-situ MSHR same-line merge | **≈** (side-deque) | — |
| Refill / eviction + occupancy model (defer_refills) | **✓** | — |
| L2 fan-in router (vs RTL Bank Refill Xbar) | **✓** | — |
| Forwarding buffer | **≈** (1 tracker) | — |
| Bank model | **≈** (set_busy cyclestamp) | P6 |
| SPM | **≈** (capacity-shrink fold) | P4 |
| Write-through coalescer FSM | **≈** (dormant) | — |
| Calibrated latencies/throughputs; closed-loop Spatz run | **✓** | — |
| Single-wide 512b cache per core (structure) | **✗** | P1 |
| Real par_coalescer (hitmap / 512b wide-merge / rsp-split) | **✗** | P1 |
| Scalar bypass_xbar (2:1) | **✗** | P1 |
| 4-beat refill burst FSM | **✗** | P1 |
| Tile L1 Xbar structure: +X remote ports, programmable mapping | **✗** | P2 |
| Runtime bank partitioning (private ↔ shared) | **✗** | P2 |
| Group fabric (LG Xbar, RG-to-T, Router, Bank Refill Xbar) | **✗** | P2 |
| Remote-access nodes + inter-tile xbar (cross-tile sharing) | **✗** | P2 |
| Multi-tile / Group / Cluster hierarchy + 16-core scale | **✗** | P2 |
| Per-resource outstanding caps (MSHR subarray, resp/wt FIFO, 32/16 budget) | **✗** | P3 |
| SPM partition (division-remap + separate path) | **✗** | P4 |
| Flush / sync FSM + L1D peripheral delivery (cache_sync) | **✗** (dormant stub) | P4 |
| AMO / LR-SC tile shim | **✗** | P5 |
| Bank-conflict / WR-conflict penalty | **✗** | P6 |
| L1 I$, AXI interco, tile/cluster barriers, L2 I$ | **N/A** | — |

**Phase key:** P1 single-wide cache + real par_coalescer + scalar bypass + refill-burst · P2 Tile/Group shared-bank substrate + remote/inter-tile xbar + programmable mapping/partitioning · P3 per-resource caps · P4 SPM remap + flush/sync + peripheral · P5 AMO · P6 bank-conflict.
