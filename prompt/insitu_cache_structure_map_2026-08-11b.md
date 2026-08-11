# InSitu Cache — Structure Map (2026-08-11b) — the designed topology is COMPLETE at 256 cores

Supersedes `insitu_cache_structure_map_2026-08-11.md` (same day, earlier: P1/P2 only). Legend:
**✓** modeled + calibrated · **◐** modeled, data-correct, partially calibrated · **≈** approximated ·
**▣** transcribed, not wired · **✗** not modeled · **N/A**.

> **Change since 2026-08-11 (a):** **P3 and P4 landed.** The group hub exists (4→1 icache mux, group
> **L2 instruction cache**, **17→1 refill mux** with instruction strict-priority / data round-robin /
> requester id) and the **second NoC level** exists (L2 refill mesh with **memory channels on the
> perimeter** — 16 for a 4×4 group grid). Every structural element of the architecture now runs
> together at **256 cores**, data-correct. `cachepool` (v1, synchronous, calibrated) remains
> byte-identical throughout.

---

## Unified hierarchy (badge = GVSoC model status)

```
CLUSTER — cachepool_v3, verified at 4×4 groups × 4 tiles × 4 cores = 256 cores
│
├─ NoC LEVEL 1 — core→L1, ×5 (one FlooNoc mesh per port class)   [◐ live; uncalibrated]
│  ├─ dim = groups; one NI per group per class                    [✓]
│  ├─ XY routing, 2 cyc/hop, 5×5 router, queue depth 2            [◐ structural]
│  ├─ narrow_width 4 B → a 64 B line = 16 flits                   [◐ injection dominates]
│  └─ ★ cross-group routing by TUNNEL, not by address map         [✓ P1 — a static map cannot
│        (rxbar re-addresses to base+group*stride+addr; the map        follow the RUNTIME-programmable
│         strips it via remove_offset)                                 XBAR_OFFSET)
│
├─ NoC LEVEL 2 — L1→mem, refill mesh                              [◐ P4 LIVE; uncalibrated]
│  ├─ mesh = (nb_x+2) × (nb_y+2); groups on the INTERIOR nodes     [✓ 6×6 at 4×4]
│  ├─ ★ MEMORY CHANNELS on the boundary ring minus corners        [✓ 2*(nb_x+nb_y) = 16 at 4×4,
│  │     = one per outbound edge port                                   one per edge port as designed]
│  ├─ channel map interleaves across the WHOLE space               [✓ 256 B granule, period-based;
│  │     (base=c*gran, size=gran, period=n_chan*gran)                   full coverage is mandatory —
│  │                                                                    FlooNoc drops unmatched bursts]
│  ├─ per-channel SoC router keeps the l2/pdcp/soc decode          [✓ so the mesh only picks a channel]
│  ├─ BOTH widths must be real: only wide WRITE DATA rides the     [!] narrow_width=0 starves every
│  │     wide plane; every request/address rides the narrow "req"      refill READ
│  └─ all channels share one backing store                         [≈ models channel paths and
│                                                                      contention, not separate DRAM]
│
├─ Peripheral — v1's ClusterRegisters                             [✓ barrier verified 256-way]
│
└─ GROUP ×16                                                      [✓]
   ├─ REMOTE crossbars ×5 (intra-group L1 + NoC attach)            [◐ routing ✓; NO per-port occupancy]
   │    • remote ports per crossbar = n, configurable; a tile has
   │      n×5. Default n=1 → five per tile.                        [✓ #37: n is structure, not bandwidth]
   ├─ ★ 4→1 L1-icache-refill mux → group L2 I$                     [✓ P3]
   ├─ ★ group L2 INSTRUCTION CACHE (Cache, 8 KiB/4-way/64 B)       [◐ P3 — geometry + hit cost are
   │                                                                   PLACEHOLDERS, refill_latency=0]
   └─ ★ 17→1 refill mux: 16 bank ports + 1 L2 I$ port              [✓ P3 — instr strict-priority,
        • 1 request/cycle; downstream latency spent as REAL TIME        data round-robin, requester id]

TILE ×4 per group                                                  [✓]
   ├─ Spatz cores ×4 — scalar + 4 VLSU lanes = 5 masters           [✓ each to its own crossbar]
   │    • VLSU nb_unfilled_bursts dependency gate                  [✓]
   ├─ L1 I$ → tile icache_refill egress (P3)                        [✓ was riding the tile AXI]
   ├─ 5 per-port-class cache crossbars — SHARED L1, any core →      [✓]
   │    any bank by ADDRESS, extended cross-tile by the remote
   │    crossbars and cross-group by NoC level 1. NOT private.
   ├─ AMO shim ×4 (one per bank, scalar lane)                       [✓ whole-lane park + ABSOLUTE
   │                                                                   occupancy window from accept]
   └─ InSitu banks ×4 (per-cycle FSM, async)                        [◐ calibrated on hit-dominated
        ├─ per-bank wide egress l2_0..l2_3 (P3)                          kernels to ~1%]
        ├─ resp_latency_cycles = 8 → served latency 10.76 vs RTL 10 [✓]
        ├─ eviction + flush writebacks carry LINE SNAPSHOTS         [✓]
        ├─ flush walk gates stage-0 admission                       [✓ structural]
        └─ functional write-through                                 [✗ OFF by default — unsafe with any
                                                                        queueing downstream; redundant]
```

---

## Verification at full scale (2026-08-11)

**256 cores, complete structure** (both NoC levels, group hub, 16 channels):
`fdotp_M32768` **64,501** (prints `(32768)`, 24% util) · `load-store_M16` **200,130** (**7/7**
partition + flush, `Cores:256 Tiles:64`). Both data-correct.

**Mesh cost, clean A/B** (write-through off in both arms):

| kernel | config | mesh off | mesh on | delta |
|---|---|---|---|---|
| fdotp_M32768 | 2×2 (8 chan) | 31,736 | 38,640 | +21.8% |
| fdotp_M32768 | 4×4 / 64c (16 chan) | 48,008 | 51,923 | +8.2% |
| fdotp_M32768 | 256c (16 chan) | 61,761 | 64,501 | **+4.4%** |
| load-store_M16 | 2×2 (8 chan) | 159,432 | 163,799 | +2.7% |
| load-store_M16 | 256c (16 chan) | 185,740 | 200,130 | **+7.7%** |

The mesh does **not** blow up at 256 cores. But the per-kernel trends run in **opposite** directions, so
this is not yet evidence of clean bandwidth scaling: fdotp's shrinking share is partly because it is not
memory-bound at that size (128 elements/core, 24% utilisation). **A memory-bound workload at full scale
is what would actually test channel bandwidth, and the kernel set does not contain one.**

## Status table

| area | status | note |
|---|---|---|
| tile: cores, crossbars, banks, AMO, L1 I$ | ✓ | shared L1, runtime partitioning, per-bank wide egress |
| group: 4→1 icache mux, 17→1 refill mux | ✓ | instruction strict-priority, data round-robin |
| group: L2 instruction cache | ◐ | works (82% hit rate measured); geometry + hit cost are placeholders |
| NoC level 1 (core→L1) ×5 | ◐ | live at 4×4; tunnel routing; hop costs uncalibrated |
| NoC level 2 (L1→mem) + 16 channels | ◐ | live; hop cost, channel granularity uncalibrated |
| async cache calibration | ◐ | hit-dominated kernels ~1% vs the sync path; see #34 |
| remote-port occupancy | ✗ | #37 — n is structure, not modelled bandwidth |
| per-channel DRAM storage / DRAMSys | ✗ | one shared backing store; no DRAM timing |
| RTL anchoring for v3 topologies | ✗ | **the real calibration blocker** |
| address scrambling | ≈ | Knuth hash, not the RTL polynomial |

## Known-broken / open
- `CACHEPOOL_V3_CORES_PER_TILE=2` with multiple groups hangs (4 cores/tile is fine).
- Dead latency stamps: xbar `xbar_latency_cycles`, remote xbar `hop_latency_cycles` (discarded on the
  async path).
- Miss-side calibration term: RTL cold miss = MemLatency + 17; the model reaches ≈ +11.
- Barriers exist only as one cluster-wide peripheral barrier, not per-level modules.
- `0xa0000000` "uncached" window still treated as cacheable.
- **Any single shared request object submitted fire-and-forget is a latent stall** the moment something
  downstream queues. Three were found this session (flush writeback loop, eviction queue, functional
  write-through); `funcwr_req_` remains the pattern to avoid re-introducing.
