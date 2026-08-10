# cachepool_v3 — implementation plan

**Date:** 2026-08-10 · **Status:** plan for review · **Companion:** the architecture artifact
(tile / group / cluster block diagrams, model-fidelity badges)

Goal: one target that has **both** the calibrated structural cache **and** the intended two-mesh
network hierarchy, so multi-group scaling studies mean something. Priority set by the user: get
multi-group working first, then return to software-side work.

---

## 1. Delta — intended architecture vs. the code we have

Legend: **✓** exists and is calibrated · **≈** exists, not tuned · **✗** absent.
"v1" = `cachepool` (calibrated, single group). "v2" = `cachepool_v2` (mesh, flat cache).

### Tile

| Intended | v1 | v2 | Work |
|---|---|---|---|
| 4 Spatz CC × 5 TCDM ports | ✓ | ✓ | — |
| 5 cache xbars, address-routed, partition CSRs on them | ✓ `InsituCacheXbar` | ✗ (interleavers) | — |
| 1 AMO per bank, on that bank's scalar input | ✓ `amo_{cb}` | ✗ | — |
| 4 InSitu banks (coalescer + core) | ✓ | ≈ flat `InsituCacheController` | — |
| flush-class mask (private / shared / all) | ✓ | ✗ | — |
| **L1 I$ per tile** | ✗ — one cluster-wide icache | ✓ per tile | **T1 — inherited free from v2** |
| tile barrier | ≈ flattened into cluster | ≈ | T2 (defer) |

### Group

| Intended | v1 | v2 | Work |
|---|---|---|---|
| N tiles | ✓ | ✓ | — |
| 5 L1 remote xbars (by tile id) | ✓ `InsituCacheRemoteXbar` | ≈ interleavers | — |
| L1 NoC NI + router | ✗ | ✓ | **G1** (adopt v2's) |
| **16 bank refill ports → 17→1 mux (+1→17 demux)** | ✗ — 16 masters fan straight into one `o_L2` | ✗ | **G2** |
| **4 L1 I$ ports → 4→1 mux** | ✗ | ✗ | **G3** |
| **L2 I$ (group), its miss = 17th port** | ✗ | ✗ | **G4** |
| **L2 NoC router (1 per group)** | ✗ | ✗ | **G5** |

### Cluster

| Intended | v1 | v2 | Work |
|---|---|---|---|
| X × Y groups | ✗ (exactly 1) | ✓ 4×4 | **C1** |
| L1 NoC 2D mesh (narrow) | ✗ | ✓ FlooNoc | **C2** (adopt) |
| **L2 NoC 2D mesh (wide)** | ✗ | ✗ | **C3** |
| **Memory channels on the mesh perimeter (16 on 4×4)** | ✗ — flat mem, 4-channel interleaver | ✗ — router tree → L2 banks | **C4** |
| cluster barrier | ✓ counting | ✓ counting | — |
| peripheral incl. L1D CSR block + flush fan-out | ✓ | ✗ **no L1D block** | **C5** |
| bootrom · UART · narrow AXI | ✓ | ✓ | — |

**Summary:** the calibrated cache is complete at tile level and needs nothing. Everything missing is
**above** the bank: refill aggregation, the instruction hierarchy above L1, and the second mesh.

---

## 2. Two findings that make this much cheaper than expected

**(a) The NoC model already has a wide plane, and v2 leaves it unused.**
`FlooNoc2dMeshNarrowWide` takes `narrow_width` *and* `wide_width` and exposes
`i_WIDE_INPUT(x,y)` / `o_WIDE_MAP(...)` / `o_WIDE_BIND(...)`. v2's `L1_noc` constructs it as
`(width, 0)` — narrow only. So the L2 mesh needs **no new NoC model**: instantiate a second
FlooNoc with `wide_width=64, narrow_width=0`.

**(b) `FlooNocClusterGridNarrowWide` is already the edge-attached-target topology — and its port
count matches the intended design exactly.**
It builds a `(N+2) × (M+2)` grid, places **routers only at the inner N×M positions**, and network
interfaces on the perimeter. For a 4×4 inner grid the perimeter has 20 positions, of which the 4
diagonal corners have no orthogonal router neighbour, leaving **16 attach points** — and they
distribute as **2 per corner router, 1 per edge router**, which is precisely the intended
"16 memory channels on the edge of a 4×4 mesh". This is a structural match, not an approximation.

**(c) Port facades already line up** for the tile swap: v2's L1 subsystem exposes
`pe_in{i}` + `vlsu_in{i}_{j}` = 5 per core, and one composite `refill` master — the same shape as
our structural tile's `i_INPUT(i*5+j)` and `o_L2`.

---

## 3. New components to write

| Component | Purpose | Notes |
|---|---|---|
| `insitu_refill_mux.{cpp,py}` | N→1 request arbiter + 1→N response demux | one component serves both the 17→1 and the 4→1 case (parameterise N). Needs a real arbitration policy + per-beat occupancy, because instruction and data refill contend here — see §6. |
| `cachepool_v3_group.py` | group composite: structural tiles + L1 remote xbars + L1 NoC ports + refill aggregation + L2 I$ + L2 NoC port | fork of `insitu_cache_group.py` extended with the wide plane |
| `cachepool_v3_tile.py` | tile with the per-tile L1 I$ (T1) | thin wrapper over `InsituCacheTile` + `Hierarchical_cache` |
| `cachepool_v3_cluster.py` / `cachepool_v3.py` | two meshes, peripheral, memory channels at the L2 perimeter | reuses v2's converters + peripheral, plus C5 |
| L2 I$ | group instruction cache | **reuse** the existing `cache.Cache` model, read-only, 1 refill master — no new code |
| L2 mesh | wide mesh + perimeter channels | **reuse** `FlooNocClusterGridNarrowWide(wide_width=64, narrow_width=0)` |

---

## 4. Phases and gates

Sequencing constraint worth stating up front: **G2 is a prerequisite for C3.** The mesh offers one
wide injection port per group; today a group has 16 independent refill masters. The aggregation must
exist before the mesh can be attached.

### P0 — v3 skeleton, structural cache inside the v2 shell
Fork v2's cluster/group/tile; replace the flat L1 subsystem with `InsituCacheTile`. No mesh yet.
- **R1** 1 group × 1 tile × 4 cores — fdotp data-correct.
- **R2** 1 group × 4 tiles × 4 cores — remote xbars alive; fdotp + fmatmul correct; **cycle-diff vs
  v1 at the same 16-core config** (same cache, different shell → should be close; any gap is shell
  overhead and must be explained before moving on).

### P1 — L1 mesh live (G1, C1, C2)
Adopt v2's converters + narrow mesh; group pre-decoder in front of the structural xbars (off-group →
NI, else local).
- **R3** 2×2 groups × 1 tile × 4 cores — first cross-group traffic, data-correct. Watch the known v2
  traps: NI burst-slot occupancy, converter window `period`, the 0xA000_0000 mirror window.

### P2 — peripheral parity (C5)
Port the L1D register block (partition CSRs, flush insn/commit/status, config broadcast) from v1's
`cluster_registers.cpp` onto the v3 peripheral.
- **Gate:** the partition-aware load-store kernel passes on v3 with all five modes and both flush
  isolations — the same seven verdicts it produces on v1.

### P3 — refill aggregation + instruction hierarchy (G2, G3, G4)
4→1 icache mux; group L2 I$; 17→1 refill mux (instruction-priority, data round-robin).
T1 is inherited: v2's tile already carries a per-tile icache.
- **Gates:** refill/eviction counts conserved end-to-end (sum of per-bank counters == mux output ==
  memory-side count); L2 I$ hit/miss counters plausible against instruction-fetch volume;
  **instruction-vs-data contention visible** at the 17→1 mux (a knob to disable the L2 I$ path should
  measurably change data refill latency — if it doesn't, the arbiter is transparent and wrong).

### P4 — L2 mesh + perimeter channels (C3, C4)
Second FlooNoc instance, wide plane; memory channels bound to the 16 perimeter NIs; address →
channel mapping.
- **Gates:** every group can reach every channel; no traffic dropped (the v2 lesson: an unmatched
  window silently drops a burst and wedges the NI); channel load distribution matches the intended
  interleave; deadlock-free with both meshes active.

### P5 — scale
- **R4** 2×2 × 4 × 4 = 64 cores. **R5** 4×4 × 4 × 4 = 256 cores.
- RLC per-group instances (level-a acceptance from the kernel handover). Report as **capability**,
  with the fabric explicitly flagged uncalibrated.

---

## 5. What cannot be calibrated, and must be labelled

The RTL has **no multi-group and no mesh**: `cachepool_pkg.sv` declares `NumGroups` but instantiates
no second group, and `config.mk` errors above `num_tiles=16`. The intended L2 NoC — group L2 I$,
17→1 mux, per-group L2 router, perimeter channels — exists in **neither** RTL nor model today.

So v3 is a **calibrated cache on an uncalibrated fabric**. Concretely:
- Bank-internal latency and throughput keep the ±4% RLC / exact-testbench pedigree.
- Anything crossing a group boundary, and any refill-arbitration or L2-mesh hop timing, is a
  **structural model with invented latencies**. Every number that crosses those boundaries must say so.
- The first RTL that implements the L2 NoC becomes the calibration target; until then the useful
  outputs are *capability* (it runs, data is correct, traffic is conserved) and *relative* studies
  (A vs B under the same fabric assumptions).

---

## 6. Decisions — settled 2026-08-10

1. **17→1 arbitration:** **instruction has strict priority**; the sixteen data requesters
   round-robin among themselves. So: if the L2 I$ port has a request, it wins; otherwise the next
   data port in round-robin order goes.
2. **Response routing:** the response **carries a requester id / user field**, so the demux is a
   lookup — no transaction table in the mux.
3. **Round scope:** **P0–P2 first**, then P3 and P4 as a second round.
4. **v2:** kept untouched as the working reference. v3 is a separate target; where v3 shares v2 code
   it does so behind a default-off flag, so v2's elaborated config stays byte-identical.

## 6b. Remaining open items (not blocking)

1. **17→1 arbitration policy.** Round-robin, instruction-priority, data-priority, or weighted? This
   is a real architectural choice: instruction misses stall a whole tile's fetch, data misses stall
   one bank's requesters. The model needs a policy and it will be visible in results.
2. **Response routing at the mux.** Does the response carry a requester id / user field (so the demux
   is a lookup), or must the mux keep a transaction table? Changes what the model tracks.
3. **Scope of P3/P4 in this round** — do we build the full intended L2 path now, or land P0–P2
   (structural cache on the L1 mesh, partition control at scale) first and treat P3/P4 as a second
   round? P0–P2 already unblocks multi-group RLC and near-data work; P3/P4 is the part with no RTL
   reference at all.
4. **v2's fate.** Keep `cachepool_v2` untouched as the working reference (recommended), or retire it
   once v3 passes its gates?

---

## 7. Rough shape of effort

| Phase | Nature | Risk |
|---|---|---|
| P0 | composition, port mapping | low — facades already match |
| P1 | reuse v2 machinery + a group pre-decoder | medium — the v2 NoC traps are documented but real |
| P2 | port known-good C++ | low |
| P3 | one new component + two reuses | medium — the arbiter is where fidelity lives |
| P4 | reuse the grid NoC, wire 16 channels | medium — address mapping and drop-free routing |
| P5 | runs and reporting | low, but wall-clock heavy at 256 cores |
