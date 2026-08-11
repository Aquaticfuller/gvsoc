# InSitu Cache — Structure Map (2026-08-11) — cachepool_v3: multi-group L1 mesh live at 256 cores

Supersedes `insitu_cache_structure_map_2026-08-04.md`. Legend: **✓** modeled + calibrated ·
**◐** modeled, data-correct, partially calibrated · **≈** approximated · **▣** transcribed, not
wired · **✗** not modeled · **N/A**.

> **Change since 2026-08-04:** a third target, **`cachepool_v3`**, puts the structural InSitu cache
> inside a multi-group shell and runs it **asynchronously**. The full design target —
> **4×4 groups × 4 tiles × 4 cores = 256 cores** — now boots and passes 8/8 kernels. New structure:
> the **L1 NoC** (one FlooNoc 2D mesh per port class) with **tunnel-based** cross-group routing,
> per-group **remote crossbars** carrying the NoC attach point, and the v1 peripheral's L1D CSR block
> ported over. The async path required four correctness fixes (async writeback data, arg-stack
> clobber, AMO overlap, a VLSU dependency violation) and three calibration steps that all share one
> shape: **a cost modelled by a latency stamp had to become real simulated time**, because the ISS
> discards stamped latency on the async path (`lsu.cpp` `data_response` zeroes `pending_latency`).
> `cachepool` (v1, synchronous, calibrated) is **byte-identical throughout** — every change is gated
> so the calibrated path cannot be perturbed.

---

## Unified hierarchy (badge = GVSoC model status)

```
CLUSTER — cachepool_v3 (4×4 groups × 4 tiles × 4 cores = 256 cores; verified)
│
├─ L1 NoC ×5 — one FlooNoc 2D mesh per port class          [◐ live; XY routing, 2 cyc/hop]
│  ├─ dim_x × dim_y = groups; one NI per group per class    [✓ 16 NIs per mesh at 4×4]
│  ├─ routing: dimension-ordered X-first + border rule      [≈ FlooNoc's own algorithm]
│  │    • at 2×2 every column is a border column, so it     [!] degenerates to Y-then-X
│  │      degenerates; 4×4 exercises genuine X-first
│  ├─ per-hop cost 2 cycles (queue delay 1 + FSM 1)         [◐ structural, not calibrated]
│  ├─ router = 5×5 crossbar, 1 req/input & 1/output per cyc [◐ round-robin over 5 input queues]
│  ├─ backpressure: input queue depth 2 (+1 slack) per dir  [◐ credit-like, unstall handshake]
│  ├─ narrow_width = 4 B → a 64 B line = 16 flits           [◐ injection serialization dominates]
│  ├─ NI admission: 1 pending burst per class + cap 32      [◐ DENIED requests queued, retried]
│  └─ ★ CROSS-GROUP ROUTING BY TUNNEL, not by address map   [✓ the P1 fix]
│       • the mesh CANNOT route on the real address: which
│         tile owns a line depends on the interleaving
│         granularity, and XBAR_OFFSET is runtime-writable
│         (fdotp sets log2(dim·4)). A map fixed at
│         elaboration delivered a group-7 address to group
│         14, which bounced it back forever.
│       • rxbar re-addresses off-group traffic to
│         tunnel_base + tgt_group·stride + addr; the map
│         strips it with remove_offset, so the destination
│         sees the original address and re-decodes it with
│         ITS OWN runtime geometry. One entry per group.
│       • closer to the RTL, which routes on a source-
│         computed TileID rather than re-decoding per hop.
│
├─ L2 refill path                                          [✗ P4 — flat AXI Router tree per group]
│  ├─ L2 NoC 2D mesh (second NoC level)                     [✗ P4]
│  ├─ memory channels at the mesh perimeter (16 for 4×4)    [✗ P4]
│  └─ backing store: memory.Memory, fixed latency 50        [≈ idealized; no DRAMSys, no DRAM timing]
│
├─ Peripheral — v1's ClusterRegisters (cachepool=True)      [✓ ported wholesale, P2]
│  ├─ HW_BARRIER 0x10 — counting barrier, 64-bit state      [✓ verified 256-way]
│  ├─ BOOT_CONTROL 0x20 / EOC 0x24                          [✓ v1 boot contract: MSIP wake + FETCHEN]
│  ├─ L1D CSR block 0x28–0x4c + COMMIT fan-out              [✓ flush + partition, 7/7 cases at 64 tiles]
│  └─ flush fan-out (1/bank) + config broadcast (1→N)       [✓ N = groups·tiles·(n_ppc+banks) + rxbars]
│
└─ GROUP ×16 (cachepool_v3_group.py)                        [✓ tiles + remote crossbars + NoC port]
   ├─ ★ REMOTE crossbars ×5, one per port class             [◐ routing ✓; no per-port occupancy]
   │    • group-aware: target group == mine → local tile
   │      slot; else → the NoC egress (slot 0)               [✓ P1]
   │    • remote ports per crossbar = n, CONFIGURABLE;
   │      a tile therefore has n×5 remote ports. Default
   │      n = 1 (five per tile) as designed.                 [✓ default fixed 2026-08-11]
   │    • n is STRUCTURE ONLY — `source % n` picks an output
   │      and forwards; no arbitration, no busy tracking.
   │      Hence n changes nothing at 1 group, yet moves 4×4
   │      results ±7-9% via slot→tile-input mapping
   │      (mechanism not traced).                            [≈ #37 open: should n be bandwidth?]
   │    • partition-config endpoint                          [✓ gate fixed — see below]
   ├─ 4→1 L1-icache-refill demux → group L2 I$              [✗ P3]
   ├─ group-level L2 instruction cache                       [✗ P3]
   ├─ 17→1 refill mux (16 bank ports + 1 L2 I$ port)         [✗ P3 — instr strict-prio, data RR,
   │                                                             response carries requester id]
   └─ refill fan-in (placeholder for the above)              [≈ flat, no arbitration modelled]

TILE ×4 per group (cachepool_v3_tile.py)                     [✓]
   ├─ Spatz cores ×4 — scalar + 4 VLSU lanes = 5 masters     [✓ all five go to their own xbar]
   │    • VLSU: nb_unfilled_bursts dependency gate           [✓ NEW — see fix 4 below]
   ├─ L1 I$ (Hierarchical_cache), private stacks             [✓]
   ├─ ★ 5 per-port-class cache crossbars (InsituCacheXbar)   [✓ SHARED L1: any core → any bank
   │      by ADDRESS, extended cross-tile by the remote
   │      crossbars and cross-group by the L1 NoC.
   │      NOT private per core.]
   │    • MSB rotation E1 + response-time unrotation         [✓ async: core unrotates at resp]
   │    • runtime partition setters (config port)            [✓ num_private / private_start / dyn_offset]
   │    • xbar_latency_cycles stamped                        [✗ DEAD on the async path — stamps are
   │                                                             discarded; convert or delete]
   ├─ AMO shim ×4, one in front of each bank                 [✓ per-bank, scalar lane only]
   │    • whole-lane park while an RMW is in flight          [✓ atomicity — narrow gate loses stores]
   │    • occupancy: ABSOLUTE window from RMW accept         [✓ structural on async (RTL core_ready);
   │                                                             additive latency stamp on sync]
   └─ InSitu cache banks ×4 (InsituCacheCore, per-cycle FSM) [◐ async, calibrated 2026-08-11]
        ├─ 2-stage pipeline (arbitrate/preread → decode/FSM) [✓]
        ├─ tag/LRU/hash-way, MSHR merge, refill, eviction    [✓ data-correct at 256 cores]
        ├─ async writeback carries a LINE-DATA SNAPSHOT      [✓ NEW — was writing 64 B of zeros]
        ├─ resp_latency_cycles = 8 (async only)              [✓ NEW — served latency 10.76 vs RTL 10]
        ├─ flush walk gates stage-0 admission                [✓ NEW — structural, was a dead stamp]
        └─ address scrambling                                [≈ Knuth hash, not RTL's polynomial]
```

---

## What changed this round, and why it mattered

### Four correctness fixes on the async path (it had never been run closed-loop)

| # | defect | symptom |
|---|---|---|
| 1 | async writeback queued only the ADDRESS; the drain sent a buffer only the sync/flush paths fill | 64 B of **zeros** written over L2; `dotp_l.M` went 0x2000→0 mid-run, so fdotp computed nothing and still "passed" by verifying zeros against zeros |
| 2 | `req->save()` pushed 4 args at `current_arg` = 0, but the scalar LSU keeps its request id in **absolute** slot 0 | responses dispatched to the wrong outstanding access; segfault on a VLSU port |
| 3 | AMO shim tracked ONE in-flight RMW — safe only when a sync cache resolves it inside the call | two RMWs completed into each other's result buffers |
| 4 | **VLSU** started the next vector memory op once bursts were ISSUED (`pending_size == 0`), never checking they had ARRIVED | `vle32.v v0` → `vse32.v v0` stored stale register elements; a few wrong words per core while the cache stayed perfectly self-consistent |

Fix 4 is worth remembering as a method lesson: a per-bank shadow of last-value-written found **zero**
cache mismatches while the test reported 81, which is what moved the search off the cache and onto the
core. The cache was innocent.

### Three calibration steps — all the same shape

Stamped latency is **discarded** on the async path, so any cost modelled by `inc_latency()` is
invisible. Each step converted one such cost into real simulated time:

1. **Per-access response latency.** Measured served latency (accept→resp) was **2.76 cycles** against
   the RTL's 10 isolated / 7 streaming. `resp_latency_cycles = 8` puts it at 10.76 — and byte-enable
   simultaneously lands within 1% of the calibrated sync path. Two independent references agreeing is
   what makes the value trustworthy rather than fitted.
2. **AMO lane window made ABSOLUTE from accept** instead of additive (it was charging ~28 cycles/RMW
   against the RTL's 15-20). The emergent cost (~19 cycles) already sits inside the RTL range, so the
   default 18 is deliberately **non-binding** — the cost stays emergent rather than fitted.
3. **Flush walk gate** — `flush_busy_until_` was set but never consulted on the async path.

**Async vs the calibrated synchronous path** (1 group × 4 tiles × 4 cores):
fdotp +1.1% · byte-enable +0.9% · spin-lock −2.3% · load-store −8.8%.

The load-store residual is a **deliberate non-goal**: both modes run the same 21,848 accesses and
near-identical refills, but sync counts 86.3% hits vs async 8.2%, because async has genuinely pending
lines and merges onto the MSHR. Served latency averages 693 cycles yet the total is *lower* — the async
path **overlaps** those waits (MLP the sync model cannot express). Since v1's load-store over-predicts
RTL by +52%, being under sync probably moves toward RTL. Closing it would fit a known-bad reference.

### Two wiring bugs the mesh hid

- **Orphaned rxbar config endpoint.** Gated on `tiles_per_group > 1` in two places while the crossbars
  exist for *any* off-tile traffic. At 1 tile/group the port was silently orphaned (GVSoC invents a
  placeholder VirtualPort rather than failing), so the crossbars kept `dyn_offset = 6` while the cache
  crossbars took the 9 software programmed. `addr_tile()` shifts by `dyn_offset + bank_bits`, so the two
  disagreed on tile ownership and bounced a request forever — burning a cycle's event budget at 2×2 and
  overflowing the stack at 4×4.
- **The static NoC map** (above) — replaced by the tunnel.

---

## Scale verification (2026-08-11)

**256 cores — 4×4 groups × 4 tiles × 4 cores, 64 tiles, 256 banks, 6.2 MB config. 8/8 kernels, first
attempt, no new bugs.**

| kernel | cycles | | kernel | cycles |
|---|---|---|---|---|
| fdotp_M32768 | 77,493 | | cache-vector-rw | 610,257 |
| fdotp_M65536 | 86,541 (48% util) | | byte-enable | 635,594 |
| load-store_M16 | 323,879 (7/7) | | cache-test-scalar | 2,698,989 |
| cache-test-vector | 2,948,376 | | spin-lock | 3,020,539 |

Proves at scale: the **256-way counting barrier** (a 32-bit bitmask cannot even represent 256
participants), **partition + flush across 64 tiles**, **256-way atomic contention completing**
(~11.8k cycles/core through one lock — impossible before the AMO occupancy fix), and cross-group mesh
traffic under a runtime-programmed interleaving.

Two caveats on those numbers: `cache-test-{vector,scalar}` cap verification at `MAX_CORES = 32`, so
their integrity verdict covers 32 of 256 cores (load-store and byte-enable check all cores and are the
stronger evidence); and fdotp's 31%→48% utilisation from M32768→M65536 is **workload**
(elements per core), not a model limit.

---

## Status table

| area | status | note |
|---|---|---|
| structural cache core (async) | ◐ | data-correct at 256 cores; calibrated on hit-dominated kernels to ~1% |
| structural cache core (sync) | ✓ | v1's deployed path, byte-identical throughout this round |
| tile cache crossbars ×5 | ✓ | shared L1, address-routed, runtime partitioning |
| AMO shim (per bank) | ✓ | whole-lane park + absolute occupancy window |
| remote crossbars ×5 per group | ◐ | routing + tunnel ✓; **no per-port occupancy** (#37) |
| L1 NoC (5 meshes) | ◐ | live at 4×4; hop/queue costs structural but uncalibrated |
| peripheral (barrier/boot/L1D CSRs) | ✓ | verified 256-way |
| group L2 I$ + 4→1 + 17→1 mux | ✗ | **P3 — next** |
| L2 refill NoC + memory channels | ✗ | **P4** |
| DRAM timing | ≈ | fixed-latency memory; no DRAMSys on this path |
| address scrambling | ≈ | Knuth hash, not the RTL polynomial |
| RTL anchoring for v3 topologies | ✗ | **the real calibration blocker** — everything above is measured against the sync path, itself only partly RTL-calibrated |

## Known-broken / open

- `CACHEPOOL_V3_CORES_PER_TILE=2` with multiple groups hangs (even byte-enable); 4 cores/tile is fine.
- Dead latency stamps: xbar `xbar_latency_cycles`, remote xbar `hop_latency_cycles`.
- Miss-side calibration term: RTL cold miss = MemLatency + 17; the model reaches ≈ +11.
- Barriers exist only as one cluster-wide peripheral barrier, not per-level modules.
- `0xa0000000` "uncached" window still treated as cacheable.
