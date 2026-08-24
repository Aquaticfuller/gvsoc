# InSitu Cache — Structure Map (2026-08-25) — L2 mesh re-anchored to the multi-group RTL

Supersedes `insitu_cache_structure_map_2026-08-11b.md`. Legend:
**✓** modeled + calibrated · **◐** modeled, data-correct, partially calibrated · **≈** approximated ·
**▣** transcribed, not wired · **✗** not modeled · **N/A**.

> **Change since 2026-08-11b:** the **L2 refill mesh was structurally wrong** and is now matched to
> `config/floonoc_cachepool_{4,16}g.yml` + `cachepool_group_noc_wrapper.sv`. It was a
> `(nb_x+2)×(nb_y+2)` grid with the groups on the interior and **16** channels around the whole
> perimeter; the RTL builds an `nb_x×nb_y` grid with the group on each node's **Eject** port and
> **8** channels hanging off the unused **West (x=0) / East (x=max)** mesh directions. The channel
> granule was 256 B; RTL decodes `addr[12:10]`, i.e. **1024 B**. DRAM was 16 MiB; RTL is **512 MiB**.
> Per-hop latency (2 cyc) and the L1 per-controller geometry were checked against RTL and are
> **confirmed correct**.

---

## Unified hierarchy (badge = GVSoC model status)

```
CLUSTER — cachepool_v3, verified at 4×4 groups × 4 tiles × 4 cores = 256 cores
│
├─ NoC LEVEL 1 — core→L1, ×5 (one mesh per port class)            [◐ live; uncalibrated]
│  ├─ dim = nb_x × nb_y groups; one NI per group per class         [✓]
│  ├─ XY routing — RTL floo_router RouteAlgo=XYRouting             [✓ confirmed]
│  ├─ 2 cyc/hop, 5-port router, in-queue depth 2                   [✓ MEASURED from RTL logs:
│  │                                                                   transit min/p50 = 2 cyc,
│  │                                                                   link = 0 cyc; InFifoDepth=2]
│  ├─ ★ cross-group routing by TUNNEL, not by address map          [✓ a static map cannot follow
│  │                                                                   the RUNTIME XBAR_OFFSET]
│  └─ ✗ RTL runs NumTilesPerGroup × NumNoCPortsPerTile PARALLEL    [✗ model runs 5 (per port class);
│        meshes (16 at 16g) + a per-tile 5→x concentration xbar        no concentration xbar]
│
├─ NoC LEVEL 2 — L1→mem, refill mesh                               [◐ RE-ANCHORED 2026-08-25]
│  ├─ mesh = nb_x × nb_y; group at each node's Eject port          [✓ 4×4 at the 16g config]
│  ├─ ★ 2×nb_y MEMORY CHANNELS on the West(x=0)/East(x=max) edges  [✓ 8 at 4×4 — RTL hbm0-3 West,
│  │     — an unused mesh DIRECTION, not an extra mesh node             hbm4-7 East. North of row 0
│  │                                                                    and South of row max unused]
│  ├─ channel = addr[12:10] → 1024 B granule, round-robin          [✓ = RTL getDramCTRLInfo:
│  │     (base=c*0x400, size=0x400, period=n_chan*0x400)                ConstantBits=clog2(64*16)=10]
│  ├─ channel NI has NO router → costs ZERO extra hops             [✓ = RTL floo_tcdm_chimney on an
│  │     (floonoc.cpp get_router_neighbour returns the NI)              edge router's unused port]
│  ├─ RTL uses SourceRouting here (model: XY)                      [≈ equivalent paths]
│  └─ all channels share one backing store                         [≈ models paths + contention,
│                                                                       not separate DRAM arrays]
│
├─ DRAM window 0x8000_0000 + 0x2000_0000 (512 MiB)                 [✓ = RTL dram_addr/dram_len;
│                                                                       was 16 MiB — too small to
│                                                                       even LOAD the RLC binaries]
├─ Peripheral — v1's ClusterRegisters                              [✓ barrier verified 256-way]
│
└─ GROUP ×16                                                       [✓]
   ├─ REMOTE crossbars ×5 (intra-group L1 + NoC attach)             [◐ routing ✓; NO per-port occupancy]
   │    • RTL: remote ports = n × 5 with TWO independent n's —
   │      NumLGPortCore (intra-group) and NumRemoteGroupPortCore
   │      (inter-group). 4g: lg=4, rg=1. 16g: lg=2, rg=1.           [✗ model collapses both into one
   │                                                                    num_remote_port_core]
   ├─ ★ 4→1 L1-icache-refill mux → group L2 I$                      [✓]
   ├─ ★ group L2 INSTRUCTION CACHE                                  [◐ RTL: 16 KiB / 4 sets /
   │                                                                    512 b line. Model geometry is
   │                                                                    still a placeholder]
   └─ ★ 17→1 refill mux: 16 bank ports + 1 L2 I$ port               [✓ instr strict-priority,
        • 1 request/cycle; downstream latency spent as REAL TIME         data round-robin]

TILE ×4 per group                                                   [✓]
   ├─ Spatz cores ×4 — scalar + 4 VLSU lanes = 5 masters            [✓ = RTL NrTCDMPortsPerCore=5]
   ├─ L1 I$ → tile icache_refill egress                              [✓]
   ├─ 5 per-port-class cache crossbars — SHARED L1, any core →       [✓ pure combinational router,
   │    any bank by ADDRESS, cross-tile via the remote crossbars          no arbitration]
   ├─ AMO shim ×4 (one per bank, scalar lane)                        [≈ no reservation table; RTL now
   │                                                                     keys LR/SC on {tile,core} with
   │                                                                     1024-cyc aging — not modelled]
   └─ InSitu cache ×4, ONE PER CORE (RTL NumL1CacheCtrl = NumCores)  [◐ see calibration below]
        ├─ 4-way × 256 entry/way × 64 B = 64 KiB/ctrl               [✓ = RTL: 256 KiB/tile ÷ 4,
        │    bank_factor = 2                                             L1BankFactor=2 hardcoded]
        ├─ resp_latency_cycles = 8 → isolated hit = 10               [✓ isolated / ✗ CLOSED-LOOP:
        │                                                                worth +46 % on the RLC kernel;
        │                                                                must become a FLOOR, not an
        │                                                                addend — see §4 of the report]
        ├─ eviction + flush writebacks carry LINE SNAPSHOTS          [✓]
        ├─ folded/skewed banks, hash-way, SRAM forwarding buffer     [✗ RTL has all three ON by
        │                                                                default at 4g and 16g]
        └─ functional write-through                                  [✗ OFF by default — unsafe with
                                                                         queueing downstream]
```

---

## Calibration status (2026-08-25)

**Measured against RTL, confirmed correct:** per-hop NoC latency **2 cycles** (from
`noc_profiling/session_0/l2_router_g*_req.log`, transit min = p50 = 2, link = 0); router input
queue depth 2; L1 per-controller geometry; the L2 channel decode.

**RLC `M1_N1350_K100`, 64 cores, 4 active cores — same binary both engines:**

| | RTL | model (default) | model @ `resp_lat=0` |
|---|---|---|---|
| fast pair | 150,175 / 150,183 | 213,587 / 214,306 | 149,248 / 149,678 |
| slow pair | 150,175 / 150,215 | 267,201 / 271,136 | 195,098 / 195,370 |
| mean vs RTL | — | **+60.8 %** | +14.8 % |
| core spread | **40** | 57,549 | 46,122 |

Two independent defects, both open:
1. `resp_latency_cycles` is additive with closed-loop time (≈ 8,100 cycles of runtime per cycle
   of the constant). Needs to become a floor on served latency, not a tail addend.
2. A 2-2 core asymmetry worth ~46 k cycles that survives every `resp_lat` value. The crossbar and
   the stage-0 arbiter are both fair; the suspect is the bounded accept queue / admission-stall
   re-admission order.

## Known-broken / open
- `CACHEPOOL_V3_CORES_PER_TILE=2` with multiple groups hangs (4 cores/tile is fine).
- `fdotp_M32768` fails its internal check at 256 cores — **also on the pre-change build**, so not a
  regression from this round. The CachePoolTests binaries were rebuilt in the RTL tree on
  2026-08-24; previously recorded passing numbers were measured against different binaries.
- Dead latency stamps: xbar `xbar_latency_cycles`, remote xbar `hop_latency_cycles`.
- Barriers exist only as one cluster-wide peripheral barrier, not per-level modules.
- `0xa0000000` "uncached" window still treated as cacheable.
