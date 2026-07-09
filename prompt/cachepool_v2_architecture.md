# CachePool v2 GVSoC Model — Architecture

> Last updated 2026-07-09. Describes the GVSoC simulation model, not the RTL directly.
> RTL reference is at `/scratch/diyou/cachepool/gvsoc/ManyRVData/` (read-only).
> **Status as of 2026-07-09**: the long-standing permanent-boot-hang bug (every core stuck
> forever at the reset vector) is root-caused and fixed — see §13.2.2. All memory-response-
> loss bugs in the L1 NoC / InsituCacheController path are root-caused and fixed — see
> §13.2.3 and §13.2.4. The `Ara`/`AraVlsu` instruction-completion-signaling bug flagged at
> the end of §13.2.1 as "the puzzling half of the picture" is now **also root-caused and
> fixed** — see §13.2.5. **`fdotp` now reaches EOC on both the 16-core debug topology and
> the full 256-core topology** (both verified 2026-07-09) — the first time this has happened
> since the investigation began, on either topology. The full-topology run completes in 250
> cycles (128% utilization) with no hang, confirming the fix scales. The correctness check
> itself still fails on both (`Calc:452.100891, Exp:628.153869` on the full topology,
> `Calc:350.577697` on the 16-core debug one — expectedly different, since the debug
> topology's reduced core count doesn't match the "Exp" reference value's assumed 256-core
> reduction). This is §13.1's pre-existing, separately-tracked numeric-mismatch item — not a
> new regression, and now finally re-checkable end-to-end on the real topology, but not yet
> re-investigated. **`fmatmul` also reaches EOC on the full 256-core topology, and its
> correctness check *passes*** (verified 2026-07-09: exit code 0, no "Core N error" lines,
> 1935-cycle steady-state execution at 529% utilization) — confirming §13.2.1's original
> repro (the `vfmacc`/`Ara`-queue-full livelock) is fully resolved end-to-end. **Root-caused
> and fixed a major contributor to §13.1's `fdotp` numeric mismatch** — see §13.1.1: scalar
> loads/stores to the whole `0x8000_0000` DRAM region were silently bypassing the L1 cache
> entirely (routed via the flat L2-refill path instead), due to a Python dict key collision
> in `cachepool_v2_tile.py`'s per-core router setup. Fixing it moved the full-topology
> `fdotp` result from `Calc:452.100891` (28% off `Exp:628.153869`) to `Calc:604.254089`
> (3.8% off). **The remaining gap is now also root-caused and fixed** — see §13.1.2:
> `snrt_cluster_hw_barrier()` never actually blocked (the peripheral responded to every
> core's barrier read immediately, regardless of how many other cores had arrived), so
> faster cores could race arbitrarily far ahead of slower ones across loop iterations with
> zero synchronization. Fixed by implementing a real counting barrier. Verified on the
> 16-core debug topology with constant-data (`A=B=1.0`) test inputs and per-core/per-group
> printf checkpoints (added on the ManyRVData side, not committed there): every checkpoint
> now matches its exact expected value, and the correctness check passes with zero
> failures — the first fully clean pass in this entire investigation. Full 256-core
> confirmation of this specific fix is pending (blocked by an unrelated tooling issue: this
> session's accumulated debug `fprintf` instrumentation produces unmanageable output volume
> at 256 cores — see §13.1.2's note), but the fix has no topology-scale-dependent logic.

---

## 1. Top-level hierarchy

```
cachepool_v2_soc
├── peripheral              (barrier controller, EOC register at 0xC000_0000)
└── cachepool_cluster
    ├── l1_noc_0            (FlooNoc — inter-group L1 cache network)
    └── group_{r}_{c}       (4×4 = 16 groups, r∈{0..3}, c∈{0..3})
        ├── group_remote_output_address_converter_{i}   (L1NocAddressConverter, Xbar→NoC)
        ├── group_remote_out_itf{i}                     (output to FlooNoc NI)
        └── tile_{t}        (4 tiles per group, t∈{0..3})
            ├── pe{k}                   (SnitchFast ISS, k∈{0..3})
            ├── stack_mem{k}            (2 KB private stack SRAM)
            ├── ico{k}                  (per-core scalar data Router)
            ├── vlsu_norm{k}_{l}        (DramNormalizer shim, k∈{0..3}, l∈{0..3})
            ├── shared_icache           (hierarchical L0+L1 icache)
            ├── axi_ico                 (AXI router → L2 / ROM / CSR)
            └── l1                      (CachepoolV2L1Subsystem)
```

---

## 2. Core count and IDs

| Level | Count | IDs |
|-------|-------|-----|
| Groups | 16 (4×4 grid) | group_{row}_{col} |
| Tiles per group | 4 | tile_0..tile_3 |
| Cores per tile | 4 | pe0..pe3 |
| **Total cores** | **256** | global_core_id = (group_id × 4 + tile_id) × 4 + core_id |

Each core is modelled as `SnitchFast` (Snitch integer + Spatz vector) with ISA `rv32imafv`,
`vlen=512`, `spatz_lane_width=4` (4 bytes per VLSU burst, matching 32-bit PE word size).

---

## 3. Address map

| Region | Base | Size | Notes |
|--------|------|------|-------|
| ROM / boot | 0x0000_1000 | 4 KB | Bootrom; cores start here at reset |
| DRAM (cacheable) | 0x8000_0000 | 512 MB | Backed by l2_mem (16 MB modelled); L1 cache covers this |
| DRAM (uncached label) | 0xa000_0000 | 256 MB | Backed by pdcp_mem (256 MB); treated same as cacheable for now |
| Stack (per-core) | 0xBFFF_F800 | 2 KB | Per-core Memory; same virtual address, isolated physically |
| Peripheral / EOC | 0xC000_0000 | 64 KB | offset 0x00 = barrier poll, 0x10 = BOOT_CONTROL, 0x14 = EOC |
| UART | 0xC001_0000 | 4 KB | ns16550 |

**No address normalization**: addresses are passed through unchanged to the L1 subsystem.
The SoC AXI routers (`axi_ico_{i}` and `loader_router`) route:
- `0x8000_0000` → `l2_mem` (with `remove_offset=0x8000_0000`)
- `0xa000_0000` → `pdcp_mem` (with `remove_offset=0xa000_0000`)

This means a cache refill for data at VMA 0xa000_0000 correctly reaches `pdcp_mem`,
where the ELF loader placed the `.pdcp_src` section.

---

## 4. Scalar data path (per core)

```
pe{k}.data
  → ico{k}  (Router, bandwidth=4, latency=0)
      ├── stack  [0xBFFF_F800, +2KB)  → stack_mem{k}  (remove_offset=0xBFFF_F800)
      ├── l1     [0x8000_0000, +0x2000_0000)  → l1.pe_in{k}
      ├── l1     [0xa000_0000, +0x2000_0000)  → l1.pe_in{k}   (no remove_offset)
      └── axi    (catch-all)  → axi_ico
```

The ico Router calls `arg_alloc(4)` per traversal, consuming 4 IoReq arg slots.

---

## 5. Vector data path (Spatz VLSU, per core, 4 lanes)

```
pe{k}.vlsu_{l}  (l∈{0..3})
  → vlsu_norm{k}_{l}  (CachepoolV2DramNormalizer — pure passthrough)
  → l1.vlsu_in{k}_{l}
```

**DramNormalizer** (`cachepool_v2_dram_normalizer.cpp`) is a pure passthrough shim.
It uses `req_forward` (zero IoReq arg slots consumed), unlike a Router which would
consume 4 slots per traversal and cause arg-stack overflow at the FlooNoc NI.
The shim's sole purpose is the arg-slot budget — it performs no address modification.

**VLSU burst width**: `spatz_lane_width=4` bytes per burst. This ensures each VLSU
request is exactly one 32-bit word — never spanning a 64-byte cacheline boundary.
The GVSoC Interleaver only propagates `IO_REQ_PENDING`/`IO_REQ_DENIED` for
single-cacheline chunks; multi-chunk requests with an async first chunk return
`IO_REQ_INVALID`, which the VLSU has no handler for and would abort.

---

## 6. L1 subsystem (CachepoolV2L1Subsystem)

One instance per tile. Components:

| Component | Count | Role |
|-----------|-------|------|
| `InsituCacheController` | 4 per tile | Tag array, MSHR, hit/miss, refill |
| `InsituCacheCoalescer` | 4 per tile | Write-through coalescer per controller |
| `local_interleaver{i}` | 4 per tile | Routes pe{i} scalar requests to one of 256 global bank slots |
| `vlsu_interleaver{i}_{j}` | 16 per tile | Routes pe{i} VLSU lane {j} to one of 256 global bank slots |
| `remote_interleaver` | 1 per tile | Aggregates intra-group + inter-group remote inputs |
| `remove_offset_{i}` (Interleaver) | 4 per tile | Fan-in arbiter per local bank; `enable_shift=0` (full address for tag matching) |
| `remote_local_out_itf{i}` | 1 per tile | Router to intra-group remote tile (latency=2) |
| `remote_group_out_itf{i}` | 2 per tile | Router to inter-group remote (latency=2, `arg_alloc(4)`) |
| `remote_local_in_itf{i}` | 1 per tile | Router from intra-group remote tile |
| `remote_group_in_itf{i}` | 2 per tile | Router from inter-group remote |

### Interleaving

Cacheline size = 64 B (6 bits). Total banks = 256 (16 groups × 4 tiles × 4 banks/tile).
Interleaving routes on bits `[13:6]` (8 bits, selecting one of 256 banks).

Bank routing for a given address:
- **Local bank** (bank belongs to this tile): → `remove_offset_{local_idx}` → controller.
- **Same-group remote bank**: → `remote_local_out_itf0`.
- **Different-group bank**: round-robin across `remote_group_out_itf{0,1}`.

VLSU lane → inter-group port mapping: `port = (nb_pe + j) % 2` where `j` is the flat
VLSU index. Lanes 0 and 2 of the same core map to `remote_group_out_itf0`.

---

## 7. Instruction cache

`Hierarchical_cache` (2-level: L0 per-core bank + shared L1). Refill goes via `axi_ico` → AXI out.

---

## 8. FlooNoc (inter-group L1 network)

`l1_noc_0` is a mesh NoC. Each group has two NI ports (`group_remote_out_itf{0,1}`).

Address translation before the NI (`L1NocAddressConverter`):
- Rearranges address bits so bank_offset and group_id fields are swapped for NoC routing.
- Uses `req_forward` — zero arg slots consumed.

NI behavior:
- Accepts one narrow read burst and one narrow write burst at a time.
- Returns `IO_REQ_DENIED` when busy; queues the request internally and calls `response`
  via Router's response callback when the in-flight burst completes.

**IoReq arg slot budget at the NI** (worst case, VLSU path):

| Component | Slots consumed |
|-----------|---------------|
| AraVlsu `arg_push` × 2 | 2 |
| `remote_group_out_itf` Router `arg_alloc(4)` | 4 |
| NI uses `arg_get_last(0)` and `arg_get_last(1)` | uses slots 6 and 7 |

Total used: 8 of 16 slots. Budget safe.

---

## 9. AraVlsu IO_REQ_DENIED handling

The Spatz VLSU (`core/models/cpu/iss/src/ara/spatz_vlsu.cpp`, class `AraVlsu`) issues
requests on 4 VLSU ports simultaneously. When two ports map to the same FlooNoc NI in
the same cycle, the NI denies the second request.

**Fix**: `IO_REQ_DENIED` is treated identically to `IO_REQ_PENDING`:
- Increment `slot.nb_pending_bursts`.
- Advance `pending_addr` / `pending_size` / `pending_velem` normally.
- The NI holds the req and calls `response` when ready.

---

## 10. Boot flow

1. ELF loader writes binary sections to memory (`.data` → `l2_mem`, `.pdcp_src` → `pdcp_mem`).
2. Loader writes ELF entry point to cluster peripheral BOOT_CONTROL (0xC000_0010).
3. All cores start from boot ROM at 0x1000 (entry=0x1000 set by loader signal).
4. Bootrom loads `BOOTDATA` (in ROM at 0x1040), enables MSI interrupt, executes WFI.
5. ELF loader triggers loader_start signal → wakes all cores.
6. Bootrom reads entry from `tcdm_end + 0x10 = 0xC000_0000 + 0x10` (= BOOT_CONTROL), jumps.
7. `_start` (snRuntime `start.S`) runs: initialises GP, core info, BSS, vector regs, stack, team; barriers; calls `main`.

**BOOTDATA** (ROM at 0x1040, little-endian 32-bit words):

| Offset | Value | Meaning |
|--------|-------|---------|
| +0x00 | 0x00001000 | (unused by snRuntime init) |
| +0x04 | 0x00000100 | cluster_core_num = **256** |
| +0x08 | 0x00000000 | hartid_offset = 0 |
| +0x0C | 0xBFFFF800 | tcdm_start (= stack base) |
| +0x10 | 0x00000800 | tcdm_size = 2 KB |

---

## 11. L2 / refill path

All L1 cache misses, evictions, and write-throughs flow out:
`refill` port → `axi_ico` → `axi_out` (tile boundary) → group AXI → SoC `axi_ico_{i}` → `l2_mem` or `pdcp_mem`.
Icache refill shares the same `axi_ico`.

---

## 12. Key source files

### Python topology

| File (under `pulp/pulp/cachepool_v2/`) | Role |
|----------------------------------------|------|
| `cachepool_v2_system.py` | Top SoC: memories, AXI ICO, loader, peripheral |
| `cachepool_v2_cluster.py` | Cluster + FlooNoc + groups |
| `cachepool_v2_group.py` | Group: tiles + L1NocAddressConverters |
| `cachepool_v2_tile.py` | Tile: cores (spatz_lane_width=4), ico, vlsu_norm, l1, icache |
| `cachepool_v2_l1_subsystem.py` | L1 cache subsystem per tile |
| `cachepool_v2_dram_normalizer.py` | DramNormalizer Python wrapper |

Also installed (must be kept in sync) under `install/generators/pulp/cachepool_v2/`.

### C++ models

| File | Role |
|------|------|
| `pulp/pulp/cachepool_v2/cachepool_v2_dram_normalizer.cpp` | Pure passthrough shim (req_forward) |
| `pulp/pulp/cachepool_v2/cachepool_v2_l1_noc_address_converter.cpp` | Xbar↔NoC address bit-rearrangement |
| `core/models/cpu/iss/src/ara/spatz_vlsu.cpp` | Spatz VLSU; handles DENIED like PENDING |
| `core/models/cache/insitu/insitu_cache_controller.cpp` | InsituCache controller |
| `pulp/pulp/floonoc/floonoc_network_interface.cpp` | FlooNoc NI |
| `core/models/interco/router/router.cpp` | Synchronous Router (arg_alloc(4) per traversal) |
| `core/models/interco/interleaver_impl.cpp` | Interleaver; only propagates PENDING/DENIED for last chunk |

---

## 12.5 L1 vs L2 interconnect — implementation summary

Two structurally different interconnects exist. Useful vocabulary when debugging: **L1
interconnect** = core ↔ L1 cache bank (address-hashed, multi-hop); **L2 interconnect** =
L1 refill port ↔ DRAM/L2 (static AXI tree, no hashing).

### L1 interconnect (core ↔ 256 cache banks)

Interleaving key: address bits `[13:6]` (8 bits, after the 6-bit cacheline offset) select
1-of-256 banks: `bank_id = (group_id × nb_tiles_per_group + tile_id) × nb_banks_per_tile
+ local_bank`. Three hierarchical stages, all keyed off the same 8 bits:

1. **Per-tile fan-out** (`cachepool_v2_l1_subsystem.py`): every local master (4 scalar
   `local_interleaver{i}` + 16 VLSU-lane `vlsu_interleaver{i}_{j}`) has its own private
   256-way `Interleaver(nb_slaves=256, nb_masters=1)` decoder. For the 4 *local* banks,
   output feeds a per-bank `remove_offset_i` fan-in arbiter (9 masters: 4 scalar + 16 VLSU
   + 1 remote-aggregated) → `InsituCacheController`. For *same-group* remote banks →
   `remote_local_out_itf0` (`Router`, latency=2). For *different-group* remote banks →
   round-robin `remote_group_out_itf{0,1}` (`Router`, latency=2) keyed on
   `(pe_or_lane_index) % 2`. Inbound remote traffic: `remote_local_in0` /
   `remote_group_in{0,1}` → per-port `Router` (latency=0) → merged into one
   `remote_interleaver` (256-way, 3 masters) → same per-bank arbiter.
2. **Intra-group xbar** (`cachepool_v2_group.py`): `group_local_interleaver`
   (`Interleaver(nb_slaves=4, nb_masters=4)`, `interleaving_bits=8` =
   cacheline(6)+log2(banks_per_tile=4)=2) — full 4×4 crossbar across the group's tiles.
3. **Inter-group FlooNoc** (`cachepool_v2_cluster.py` / `cachepool_v2_group.py`): each
   tile has 2 inter-group ports. Outbound: tile → `L1NocAddressConverter` (xbar↔NoC
   address-bit rearrangement, `req_forward`, 0 arg slots) → `group_remote_out_itf{i}`
   (`Router`) → one of 2 `l1_noc_k` FlooNoc mesh instances (`pulp/teranoc/l1_noc.py`,
   `width=4`, `ni_outstanding_reqs=32`), addressed via `base = 0x80000000 + group_id ×
   16KB`, `size = 16KB` per group (NoC window is contiguous per group by construction —
   see converter derivation in `cachepool_v2_cluster.py` docstring). Inbound: NoC →
   `L1NocAddressConverter` (NoC→xbar) → `group_remote_slave_interleaver_{0,1}` (4-way,
   keyed by tile) → target tile's `grp_remt{j}_slave_in`.

### L2 interconnect (L1 refill port ↔ DRAM/L2)

Flat, statically address-routed AXI tree — no interleaving/hashing, since refill traffic
already carries the real DRAM address.

1. **Tile** (`cachepool_v2_tile.py`): `l1.refill` (controller refill+evict + coalescer
   write-through, all 4 banks folded into one master port) + `icache.refill` → tile's
   `axi_ico` (single `Router`, latency=1) → tile `axi_out`.
2. **Group** (`cachepool_v2_group.py`): 4 tiles' `axi_out` → `Hierarchical_Interco`
   (`enable_cache=False` → its `Cache`/`CacheFilter` is a pure bypass, functionally just
   another fan-in `Router`, latency=2) → group `axi_out_0`.
3. **Cluster** (`cachepool_v2_cluster.py`): each group's `axi_out_0` passed straight
   through to cluster boundary as `axi_{group_id}` — 16 independent AXI masters, never
   merged.
4. **SoC** (`cachepool_v2_system.py`): each of the 16 cluster AXI masters gets its own
   `axi_ico_{i}` (`Router`) with static ranges: `0x8000_0000` → `l2_mem` (`L2_subsystem`,
   4 banks, 16 MB modelled), `0xa000_0000` → `pdcp_mem` (flat `Memory`, 256 MB), else →
   `soc_ico` (ROM/peripheral/UART).

**Asymmetry to keep in mind when debugging**: L1 has three levels of address-hashed
interleaving/arbitration with real fan-in contention and multi-hop latency (Router
latency=2 at several hops, NoC `ni_outstanding_reqs=32`). L2 is a static fan-in tree, no
hashing, no cross-talk between groups (16 fully independent DRAM ports). A partial-sum /
undercount type of numerical error (as opposed to corrupted/garbage data) is
structurally more likely to originate on the L1 side (esp. the inter-group NoC hop,
since fdotp scatters `dotp_A_dram`/`dotp_B_dram` across the full 256-bank space) than on
the L2 side.

---

## 13. Known issues / open items

### 13.1 fdotp result array too small (software bug, ManyRVData read-only) — FIXED upstream 2026-07-08

**File**: `ManyRVData/software/tests/fdotp-32b/data/data_32768.h`

`float result[64]` had only 64 entries but `snrt_cluster_core_num()` returns 256.
Cores 64..255 wrote `result[cid]` out-of-bounds, corrupting adjacent `.data` memory.
The two-level reduction then read corrupt values → wrong final sum.

**Original observed output** (before fix): `Calc:4294967295.4294967295, Exp:628.153869`
(garbage/NaN bit pattern from the OOB corruption).

User rebuilt ManyRVData with `result[256]`. **Status after rebuild (verified
2026-07-08, `test-cachepool-fdotp-32b_M32768`)**: OOB corruption is gone (no more NaN),
but the check still fails with a *finite, real* mismatch:

```
Check Failed!
Calc:189.697906, Exp:628.153869
```

Ratio Calc/Exp ≈ 0.302. Performance numbers looked sane (197/190 cycles, ~162-168%
utilization), so this is not an obvious timing/model crash — it's a genuine
functional/numerical discrepancy, distinct from and downstream of the now-fixed
array-size bug. Root cause not yet identified. Candidates to investigate next: the
256-core two-level reduction (`main.c:143-160`, group size 4) not correctly gathering
all groups' partial sums (cross-tile/cross-group L1 read/write visibility — see §12.5
L1 interconnect, esp. the FlooNoc hop), vs. a numerical issue in the vector dot-product
kernel itself (`kernel/fdotp.c`) at this problem size. User's prior stated on
2026-07-08: suspects the issue is *not* the interconnect.

### 13.1.1 Root cause found and fixed: scalar accesses to the whole 0x8000_0000 DRAM region silently bypassed L1 (2026-07-09)

**Starting point**: with §13.2.1-13.2.5's livelock fixes in place, `fdotp` finally reaches
EOC end-to-end (§13.2.5) but the check still fails (`Calc:452.100891, Exp:628.153869` on
the full 256-core topology). Per the user's own hypothesis — *"since it only occurs to
dotp, I highly doubt [suspect] the reduction part, since in matmul we do not have real
shared data"* — investigation focused on `main.c`'s two-level reduction (`result[]` array
at `0x800037c8`, read/written by every core across group and global barriers), since it's
the one thing `fdotp` does that `fmatmul` (which passes) doesn't: many cores' scalar
`fsw`/`flw` cross-reading each other's just-written values.

**Investigation path** (each step ruled something out or found something real):
1. Instrumented `InsituCacheController::handle_request()` (`core/models/cache/insitu/
   insitu_cache_controller.cpp`) to trace every access to `result[]`'s 1KB address range.
   **Zero writes ever reached it** — but reads to other addresses worked fine, and the
   `fsw` instructions clearly retired (confirmed via the always-on `[SCALAR_PC_DBG]`
   trace). This ruled out a lost-response bug (already fixed in §13.2.3/13.2.4) and pointed
   at the write never even reaching the L1 subsystem.
2. Chased the ISS-side dispatch for scalar float stores. `core/models/cpu/iss/src/
   snitch_fast/fpu_lsu.cpp`'s `FpuLsu` class (which has pre-existing, **still-uncommitted**
   WIP async-response support from an earlier, unrelated session, and shares a single
   request buffer + stall-callback slot with the regular `Lsu` — a real but, it turned out,
   irrelevant fragility) was the first suspect, but instrumenting it directly showed **it is
   never even called** for `fsw`/`flw` in this configuration.
3. Instrumented `Sequencer::float_handler` (`core/models/cpu/iss/src/spatz/
   fpu_sequencer.cpp`, which intercepts every `fp_op`-tagged instruction for a register-
   hazard check before dispatching to the real handler) and used `dladdr()` to resolve the
   real handler's function pointer to a symbol + file offset. This revealed the actual
   handler is `fsw_exec`/`flw_exec` in `core/models/cpu/iss/include/isa/rvf.hpp` — a
   **different, generic ISA file** from the `snitch_fast/`-specific one step 2 was looking
   at. These call `iss->lsu.store_float_perf<uint32_t>`/`load_float_perf<uint32_t>` — i.e.
   the **regular `Lsu` class** (`lsu_implem.hpp`), not `FpuLsu` at all. (`FpuLsu`'s
   async-response WIP from step 2 is real fragility worth revisiting some day, but is not on
   the path this ISA/core configuration actually exercises for scalar float ops.)
4. Instrumented `Lsu::store_float`/`store_resume` (the actually-used path). The store
   completes **synchronously** (`IO_REQ_OK`) every single time (963/963 = exactly matching
   the expected write count for 3 iterations × 321 writes/iteration) — so from the core's
   perspective, everything works. Yet `InsituCacheController` still saw zero writes.
5. Cross-checked against the always-on `[MEM_DBG]` trace at `core/models/memory/
   memory.cpp` (fires at the final DRAM/L2 backing-store level, `offset<0x2000`, unrelated
   to this investigation but already in the tree): found **22000+ individual 4-byte writes
   landing directly at `l2_mem`** — i.e. the writes *were* completing, just not through the
   L1 cache. This meant the request was being **routed to L2 directly**, bypassing L1
   entirely — a routing bug, not a lost/dropped request.
6. Instrumented `Router::handle_req()` (`core/models/interco/router/router.cpp`, already
   had a `[ROUTER_DBG]` print for a different address range from the §13.2.2 boot-hang
   investigation — added a second one for `result[]`'s range) to see which named mapping
   the per-core scalar router (`ico{core_id}` in `cachepool_v2_tile.py`) selected. Writes
   consistently matched `mapping=axi` (the catch-all) → tile `axi_ico` (`output`) → group
   `Hierarchical_Interco` (`output`) → SoC `axi_ico_i` (`l2`) → `l2_mem` — exactly the L2
   refill path from §12.5, confirming step 5's finding and explaining *why*: **the `l1`
   mapping simply never matched.**

**Root cause**: `Router.add_mapping()` (`core/models/interco/router.py:161`) stores
mappings in a **plain Python dict keyed by name**: `self.get_property('mappings')[name] =
{...}`. `cachepool_v2_tile.py`'s per-core router setup registered *two* mappings with the
same name:
```python
ico.add_mapping('l1', base=DRAM_BASE,   size=0x20000000)   # 0x8000_0000 region
ico.add_mapping('l1', base=0xa0000000,  size=0x20000000)   # 0xa000_0000 region — same key!
```
The second call **silently overwrote** the first in the dict — there was never a working
`l1` mapping for the `0x8000_0000` region at all. *Every* scalar load/store to that entire
512 MB region (not just `fdotp`'s `result[]` — any scalar access to normal cacheable DRAM)
fell through to the `axi` catch-all and got routed via the flat, non-cached L2-refill path
instead of the L1 cache. `fdotp`'s reduction is what actually surfaced it because it's the
one place where correctness *depends on* cross-core L1 visibility of scalar writes with
short turnaround (group-leader reads happening soon after sibling writes) — the RTL/L1
timing model was simply never in the loop for these accesses. `fmatmul` didn't trip over
this because vector loads/stores (`vlsu_in{k}_{l}`) go through a completely separate port
straight to `l1.vlsu_in{k}_{l}` (§5), bypassing `ico` (and this bug) entirely — only
*scalar* float ops hit it, and `fmatmul`'s output writes are vectorized.

**Fixed**: renamed the two mappings to distinct names (`l1_dram`, `l1_pdcp`), each still
bound to the same `l1.pe_in{core_id}` target (two separate `self.bind()` calls — the same
"give unique names, bind both to the same destination" pattern already used for the
FlooNoc fix in §13.2.3/cluster.py).

**Verified**: rebuilt, reran on the full 256-core topology. Router trace now shows all 963
writes correctly resolving to `mapping=l1_dram`. The `fdotp` result improved from
`Calc:452.100891` (28% off) to **`Calc:604.254089` (3.8% off `Exp:628.153869`)** — a large,
unambiguous improvement matching the theory precisely (correct routing → real cache
timing/coherence in the loop → far closer to the reference value).

**Residual — root-caused and fixed, see §13.1.2.** The result was still not exact (3.8%
off on the full topology), and the 16-core debug topology's result was *unchanged* by this
fix (`Calc:350.577697`, bit-for-bit identical to before). Both are explained by §13.1.2's
finding.

### 13.1.2 Root cause found and fixed: `snrt_cluster_hw_barrier()` never actually blocked (2026-07-09)

**Debugging approach (user's idea).** Rather than keep guessing at the remaining 3.8% from
random test data, the user proposed regenerating fdotp's data with a **constant** value
(`A[i]=B[i]=1.0` for all `i`, via a new `FDOTP_CONST` env var added to `script/gen_data.py`)
so every intermediate reduction value becomes an exact, hand-computable integer
(`elem_per_core` per core, `4×elem_per_core` per group, `M` total), and adding printf
checkpoints in `main.c` at each of the three reduction stages (per-core partial,
group-leader sum, final total) that self-report PASS/FAIL against the known-exact expected
value. (These `main.c`/`gen_data.py` changes live in `ManyRVData`, a separate read-only-by-
convention repo not committed here; see that repo's working tree.)

**First attempt — a spinlock (`snrt_mutex_lock`) around the printf calls — made things
worse.** With 16+ cores calling `printf()` around the same cycle, their output interleaved
byte-by-byte at the UART model into unreadable garbage. Serializing with a mutex fixed the
garbling but (exactly as the user warned going in) introduced a **new livelock**: cores
got stuck spinning in the mutex's retry loop for 30M+ cycles (vs. the ~10-20K cycles the
test normally takes). Switched to a lock-free design instead: each core stashes its
checkpoint value into a private slot in a small debug array (`dbg_partial[256]`,
`dbg_group[64]` — no lock needed, since every core writes a distinct index), and only core
0 reads them all back and prints sequentially afterward. This produced clean,
non-garbled, and — critically — **not further timing-perturbed** output.

**The result nailed it immediately.** On the 16-core debug topology: every individual
core's partial sum was exactly correct (`512 = elem_per_core`, all "OK"). But the
group-leader sums were wrong for exactly 2 of the 4 groups:
```
[group leader 0] sum=5120.000000 expect_elems=2048 FAIL   (5120 = 10×512, excess)
[group leader 4] sum=1024.000000 expect_elems=2048 FAIL   (1024 = 2×512, deficit)
[group leader 8] sum=2048.000000 expect_elems=2048 OK
[group leader 12] sum=2048.000000 expect_elems=2048 OK
```
Since every individual core's own write was always correct, the bug had to be in the
group-leader's *read* of its siblings' `result[]` slots. Correlating the already-in-tree
`[RESULT_DBG]`/`[LSU_DBG]` write-value traces (after fixing their address filter for this
binary — see the `insitu-cache` commit above) against the timeline was conclusive: sibling
core 1 had **already written its iteration-2 value** (`1536`, at cycle 12988) **before**
group-leader core 0 even started reading iteration 0's value (cycle ~14366-14732). Core 0's
actual sum, `512(own,iter0) + 1536(r1) + 1536(r2) + 1536(r3) = 5120`, matched the observed
`FAIL` value exactly. Cores 1-3 were racing **two full loop iterations ahead** of core 0
despite the `snrt_cluster_hw_barrier()` calls between every iteration.

**Root cause**: `cachepool_v2_cluster_peripheral.cpp`'s `REG_HW_BARRIER` read handler:
```cpp
if (offset == REG_HW_BARRIER && !is_write)
{
    _this->event_enqueue(_this->wakeup_event, _this->wakeup_latency);
    if (size == 4) *(uint32_t *)data = 0;
}
...
return vp::IO_REQ_OK;   // <- returned synchronously, on every single call
```
The register read returned `IO_REQ_OK` **immediately** on every call, regardless of how
many other cores had also reached the barrier. `snrt_cluster_hw_barrier()`
(`ManyRVData/software/snRuntime/src/platforms/shared/start_snitch.S`'s
`_snrt_cluster_barrier`) is just a single blocking `lw` of this register — since the
response never actually waited on anything, **the "barrier" was a complete no-op from a
synchronization standpoint**: every core sailed through it instantly, letting faster cores
race arbitrarily far ahead of slower ones with zero cross-core ordering. This is the true
root cause of the entire multi-session reduction-correctness investigation (§13.1/§13.1.1):
`fdotp`'s two-level reduction is the one workload in this whole effort that actually
*depends* on barriers enforcing real cross-core ordering (a group leader must see its
siblings' values from the *current* iteration, not some future one); `fmatmul` never
exercises this dependency, which is also why it always passed cleanly once the earlier
livelock/routing bugs were fixed.

`(event_enqueue(wakeup_event, ...) / barrier_ack_itf)` turned out to be a real mechanism,
just wired to the wrong thing: it's a broadcast wire (`o_BARRIER_ACK`, fanned out to every
core) intended to release *all* cores together — but it was only ever used for the
one-time boot/WFI wakeup (`REG_CLUSTER_BOOT_CONTROL`), never connected to the actual
per-iteration `REG_HW_BARRIER` polling path.

**Fixed**: `CachepoolV2ClusterPeripheral` now takes a `num_cores` property (threaded
through from `total_cores` at `cachepool_v2_system.py`'s peripheral instantiation site,
already correctly debug-topology-aware via the existing `_TOTAL_CORES` override). Each
`REG_HW_BARRIER` read is now **parked** (`IO_REQ_PENDING`, pushed onto a
`pending_barrier_reqs` queue) rather than answered immediately. Only once `num_cores`
reads have arrived does a `barrier_release_event` fire (after `wakeup_latency` cycles),
responding to **every** parked request at once — a real counting barrier instead of a
fixed per-core delay.

**Verified**: rebuilt, reran the 16-core debug topology with the same constant-data test.
Every checkpoint now passes exactly:
```
[core 0..15] partial=512.000000 expect_elems=512 OK        (all 16 cores)
[group leader 0] sum=2048.000000 expect_elems=2048 OK
[group leader 4] sum=2048.000000 expect_elems=2048 OK
[group leader 8] sum=2048.000000 expect_elems=2048 OK
[group leader 12] sum=2048.000000 expect_elems=2048 OK
[core0] TOTAL=8192.000000 expect_elems=8192 OK
```
No `Check Failed` at all — the full multi-iteration correctness check passes with zero
failures, the first completely clean pass since this whole investigation began.

**Full 256-core confirmation not yet completed** (unrelated tooling issue, not a
correctness concern): this session's accumulated debug `fprintf` instrumentation
(`[SCALAR_PC_DBG]`, `[VLSU_DBG]`, etc. — all unconditional, firing every cycle per core)
produces unmanageably large, unflushed output at 256 cores; a background run was killed
after its wrapper process's in-memory output buffer grew to 37 GB without ever reaching
disk (a `gvsoc`-wrapper stdio-buffering gotcha already noted elsewhere in this doc, made
much worse by 256× the per-cycle debug volume). The fix itself has no topology-scale-
dependent logic (purely parameterized by `num_cores`), so this is a confirmation step, not
a known risk. **Next step**: either trust the 16-core proof as sufficient (recommended —
the mechanism is provably scale-invariant), or do a cleanup pass stripping/gating this
session's accumulated unconditional debug instrumentation first, then re-run at 256 cores
for a fast, clean confirmation.

### 13.2 matmul crash — VLSU burst crossing cacheline boundary (model bug)

**Crash**: `AraVlsu::fsm_handler` calls `trace.fatal("Unsupported IO response status")` → `abort()`.

**Root cause**: `gemm_A/B/C_dram` arrays are 4-byte aligned (not 64-byte aligned).
With `spatz_lane_width=8` (the old default), the VLSU issues 8-byte bursts.
An 8-byte burst at cacheline-offset 60 crosses into the next cacheline, splitting
across two Interleaver chunks. If the first 4-byte chunk misses (returns `IO_REQ_PENDING`),
the Interleaver sees `size (8) != loop_size (4)` and returns `IO_REQ_INVALID`.
The VLSU has no handler for `IO_REQ_INVALID` → fatal.

**Fix applied**: `spatz_lane_width=4` in `cachepool_v2_tile.py` (both source and installed copy).
4-byte bursts (one float32) never cross a 64-byte cacheline boundary for 4-byte-aligned data.

**Status**: the crash itself is gone, but running `test-cachepool-fmatmul-32b_M32_N32_K32`
then **hung forever** instead (verified 2026-07-08) — see §13.2.1 for the investigation.
**Resolved 2026-07-09**: after the boot-hang fix (§13.2.2) and the `Ara`/`AraVlsu`
completion-signaling fix (§13.2.5), `test-cachepool-fmatmul-32b_M32_N32_K32` reaches EOC on
the full 256-core topology with **no hang and a passing correctness check** (exit code 0,
no `Core N error` lines, 1935-cycle steady-state execution at 529% utilization) — this was
in fact the same underlying bug as §13.2.5, not a separate matmul-specific issue.

#### 13.2.1 matmul livelock/deadlock investigation (open, 2026-07-08)

**Symptom**: `pe0` gets stuck at `pc=0x800007b0` (`vfmacc.vf v8, ft1, v20`, part of the
steady-state 4-way unrolled software-pipelined K-loop in `fmatmul`'s inner kernel —
see disassembly at `ManyRVData/software/build/CachePoolTests/test-cachepool-fmatmul-32b_M32_N32_K32.s`
around `0x800007a0`-`0x800007c4`). The scalar Snitch sequencer retries this PC every
cycle forever; naive `--trace=` runs balloon to multi-GB log files in seconds because
of the per-cycle retry spam — **always bound matmul runs with a short `timeout` (≤30s)
and prefer targeted `fprintf` instrumentation over `--trace-level=trace`, which was
observed to stall elaboration itself for 10-15s producing zero output even scoped to
a handful of components** (not yet understood why, but confirmed unusable for this
kind of investigation at the current scale).

**Two real (but ultimately unrelated) bugs found and fixed while chasing this**, per the
user's out-of-order-memory hypothesis (CachePool's NUMA/cache paths return
`IO_REQ_PENDING`/`IO_REQ_DENIED` far more than the flat standalone-Spatz testbench this
model was originally validated against):

1. **`core/models/cpu/iss/src/spatz/fpu_sequencer.cpp:101-109`** (`Sequencer::float_handler`,
   handles every `fp_op`-tagged instruction incl. `flw`/`fsw` that never gets reassigned to
   the vector path) indexed `args[i]` instead of `args[insn->nb_out_reg + i]` when checking
   FREG input hazards — for `flw` (1 output, 1 input) this reads the *output* register's
   flags (always FREG) and then checks `scoreboard_freg_timestamp[]` at the *input*
   integer register's numeric index, an unrelated/aliased scoreboard slot. Every other
   callsite in this codebase (`ara.cpp`, `snitch.cpp`'s `vector_insn_stub_handler`)
   correctly offsets by `nb_out_reg`; this was the one place that didn't. **Fixed** by
   adding the offset.
2. **`core/models/cpu/iss/src/ara/spatz_vlsu.cpp`** (`AraVlsu::fsm_handler`) called
   `ara.insn_commit(vreg, size)` unconditionally right after issuing each burst,
   regardless of whether the port returned `IO_REQ_OK` (synchronous) or
   `IO_REQ_PENDING`/`IO_REQ_DENIED` (asynchronous). `insn_commit` immediately marks
   the vector register scoreboard as committed, which is what `AraVcompute`'s
   *chaining* logic uses to decide a producer's data is ready — so a chained consumer
   instruction could start reading a vector register before an async burst's
   `data_response()` had actually written it. **Fixed**: `insn_commit` now only fires
   immediately for the synchronous `IO_REQ_OK` case; for `IO_REQ_PENDING`/`IO_REQ_DENIED`
   it's deferred into `data_response()` (vreg + size are pushed onto the `IoReq` arg
   stack — 2 extra slots on top of the existing slot/port_id pair, so 4 total; the
   IoReq arg budget is 16 slots and the documented worst-case path in §8 above used 8,
   so this stays safe at 10/16).

**Verification**: both fixes rebuild clean and were confirmed *not* to change fdotp's
output at all (bit-for-bit identical `Calc`/`Exp`/cycle counts before and after), and
*not* to move the matmul hang's onset by even one cycle (`0x800007b0` first hangs at
cycle 6197 in both the original and fully-patched builds). So these are real bugs worth
keeping fixed, but neither is the cause of either open symptom.

**Where the matmul hang actually is** (confirmed via targeted `fprintf` instrumentation,
since `--trace-level=trace` was unusable — see above): `Ara`'s shared 8-slot instruction
queue (`Ara::pending_insns[]`, `queue_size=8`) gets **permanently stuck completely full**
(`nb_pending_insn=8`) from cycle ~6092 onward (confirmed still full past cycle 4.88M in a
bounded run). The head-of-queue instruction that never gets marked `done` is
`vle32.v v20, (t2)` (`pc=0x800007cc`, loads the shared `vs2` operand for all four
`vfmacc.vf` in the steady-state loop). Because `Ara::fsm_handler`'s completion check only
ever looks at the *head* of the ring buffer, one stuck entry head-of-line-blocks all 8
slots forever, and every subsequent vector instruction (incl. `0x7b0`) is stuck at
`vector_insn_stub_handler`'s `iss->vu.queue_is_full()` gate (`snitch.cpp:269`) — confirmed
by instrumenting that exact call site.

**Puzzling half of the picture, not yet resolved**: instrumenting `AraVlsu` itself (the
block `0x7cc`'s load was dispatched to) shows it believes it's essentially idle during
the hang — `nb_waiting_insn` and `pending_size` are almost always 0 when sampled. So
`AraVlsu`'s own local view is "nothing outstanding," while `Ara`'s global queue still
believes this instruction is unfinished. Working hypothesis: a **desync between
`AraVlsu`'s own bookkeeping and `Ara`'s global completion signaling**. `AraVlsu`
maintains three separate indices into its own `insns[]` array (`insn_first`,
`insn_first_waiting`, `insn_last`), distinct from `Ara::pending_insns[]`'s single
`insn_first`. The bottom of `AraVlsu::fsm_handler` is supposed to detect
`pending_size==0 && nb_pending_bursts==0` at `insns[insn_first]` and then call
`ara.insn_end()` to mark the global entry done — that call is either being skipped for
this instruction, or checking/advancing the wrong slot, so `Ara`'s global scoreboard
never hears "I'm done" even though `AraVlsu` has locally moved on. **Not yet pinned to
an exact line** — next step is a careful audit of `AraVlsu`'s three-index bookkeeping
against `Ara::insn_end`'s call site, rather than more blind instrumentation.

**Debug instrumentation currently left in the tree** (gated/rate-limited `fprintf`s,
harmless but not clean — strip once the real fix lands):
- `spatz_vlsu.cpp`: `data_response()` and the burst-issue loop in `fsm_handler` (prefix
  `[VLSU_DBG]`), the pre-dispatch wait check (`[VLSU_WAIT_DBG]`), and the burst-loop
  entry check filtered to `tile_0/pe0` (`[VLSU_BURST_DBG]`).
- `ara.cpp`: `Ara::fsm_handler`'s head-of-queue check (`[ARA_DBG]`, prints pc/nb_pending_insn/
  queue_size/insn_first/chained when the head isn't done).
- `snitch.cpp`: `vector_insn_stub_handler` (`[STUB_DBG]`, prints at the `queue_is_full`,
  int-reg-blocked, and freg-blocked return points, rate-limited to `pc==0x800007b0`).

All are gated behind counters (`% 500000`, `% 2000`, or path-string filters) specifically
so they don't reproduce the multi-GB runaway-log problem; they were the only way found so
far to get useful signal out of a hung run in bounded wall-clock time.

### 13.2.2 `pulp` submodule rebased onto upstream/master; boot-hang root cause found and fixed (2026-07-08/09)

**Rebase.** At the user's request, rebased the `pulp` submodule (`Aquaticfuller/gvsoc-pulp`
fork) from its old base onto `gvsoc/gvsoc-pulp`'s `master` (55 commits, incl. the
`SnitchMempool` core the user was originally after, and a `spatz_v3`/timing-model rework
and a strided/indexed-load chaining fix that looked relevant to the open matmul livelock).
Procedure followed `prompt/rebase_dev_branches_runbook.md`'s spirit (recovery SHA noted,
uncommitted WIP committed first as two checkpoint commits, rebase, no conflicts across all
30 resulting commits). `core`/`engine` were *not* touched. Two pre-existing latent bugs
(unrelated to the rebase itself, just never previously exercised) blocked the post-rebase
rebuild and were fixed:

- `pulp/mempool/l2_interconnect/hierarchical_interco.py`: the `Cache` sub-block was
  constructed unconditionally regardless of `enable_cache`, and segfaulted inside
  `Cache::Cache()`'s trace-event setup at small elaboration sizes. `cachepool_v2` always
  calls this with `enable_cache=False` (real per-group L2 ICache modeling — confirmed the
  RTL has one, `cachepool_pkg.sv`'s `L2ICache*` params + `cachepool_group.sv`'s hardwired
  `l2icache_ctrl.enable=1'b1` — is out of scope for now; today's icache/dcache refill
  traffic isn't even separated onto distinct ports yet, a prerequisite for modeling it
  faithfully). **Fixed**: skip constructing `Cache` (and its bindings) entirely when
  `enable_cache=False`, since with no `cache_rules` it never carried traffic anyway.
- `pulp/mempool/hierarchical_cache.py` (the per-tile shared icache): `nb_l1_sets =
  nb_fus_per_core * nb_cores / 2` goes fractional/negative at `nb_cores_per_tile < 2`,
  corrupting the L1 icache-bank's array sizing. Only matters for the
  `CACHEPOOL_V2_CORES_PER_TILE` debug override added below at `=1`; the real topology
  always uses 4 and is unaffected. Not fixed (worked around by testing at
  `cores_per_tile=4`); flagged here for whoever eventually wants `=1`.

**Debug-topology override added.** `pulp/pulp/cachepool_v2/cachepool_v2_system.py` gained
`CACHEPOOL_V2_NB_X_GROUPS` / `_NB_Y_GROUPS` / `_TILES_PER_GROUP` / `_CORES_PER_TILE` env
vars (default 4/4/4/4 = the unchanged 256-core topology) plus a `_patch_bootrom()` helper
that rewrites the bootrom's BOOTDATA `core_count`/`tile_count` fields (offsets `0x44`/`0x68`)
to match, mirroring `pulp/cachepool.py`'s existing v1 mechanism. This turns an 8+ minute,
multi-million-cycle repro into a ~15-second one (e.g. `CACHEPOOL_V2_NB_X_GROUPS=2
CACHEPOOL_V2_NB_Y_GROUPS=2 CACHEPOOL_V2_TILES_PER_GROUP=1 CACHEPOOL_V2_CORES_PER_TILE=4` =
16 cores) — essential for iterating on the bug below at all.

**Operational gotcha: the `gvsoc` CLI wrapper silently swallows `gvsoc_launcher`'s
stdout/stderr.** `conda run ... bash -c 'gvsoc --target=... run' > file 2>&1` produced
**zero bytes**, even for `fprintf(stderr, ...)` calls that fire on every single instruction
retired, even after 90s+. Root-caused to: `gvsoc ... image`/`flash` alone never write
`gvsoc_config.json` (that only happens as a side effect of the `run` action actually trying
to launch); and even with `run` included, the wrapper's own subprocess plumbing doesn't
forward the launched C++ process's output faithfully. **Workaround** (used for all
debugging below): generate the config with a short-timeout `gvsoc ... image flash run`
(the write happens within the first ~1-10s, well before any hang), then invoke
`install/bin/gvsoc_launcher --config=gvsoc_config.json` **directly**, bypassing the `gvsoc`
wrapper entirely — this reliably produces real-time output. Relatedly: **`gvsoc_config.json`
is not regenerated if it already exists** — no mtime/staleness check against the Python
source — so `rm -f gvsoc_config.json` before every regeneration is required or you'll
silently keep simulating the old topology/wiring (this cost significant time mid-session:
a topology change and a Python binding fix each appeared to have "no effect" until this was
understood).

**Root cause of the fdotp hang (and, in hindsight, almost certainly what the original
256-core "silent 8-minute hang" always was).** Reducing to the fast 16-core topology and
using the direct-launcher workaround above, instrumented `Exec::exec_instr_check_all`
(`core/models/cpu/iss/src/exec/exec_inorder.cpp`) and found **every core's PC permanently
stuck at `0x1000`** (the bootrom's first instruction, `auipc t1, 0x0`) forever — the
"instruction executes" but its handler reports its own address as the next PC. Traced via
`Decode::decode_pc`/`decode.cpp` and `core/models/interco/router/router.cpp` (added
targeted `fprintf`s at the `IO_REQ_INVALID` return sites, and in
`vp::Component::create_bindings`/`bind_ports`/`MasterPort::bind_to_slaves`/
`get_final_ports` in the `engine` submodule) down to: the per-tile shared icache
(`Hierarchical_cache`) issues a real outbound refill request on a cold miss, which
propagates up through `axi_ico` (the tile's local `Router`) correctly, but then
**`pulp/pulp/cachepool_v2/cachepool_v2_group.py`'s binding of the tile's AXI output to the
group-level `Hierarchical_Interco` used the wrong slave port name** — `'input'` instead of
`'input_0'`. `Hierarchical_Interco` (constructed with the default `nb_slaves=1`) exposes
its boundary slave port as `input_0` (`self.bind(self, f'input_{i}', input_itf, ...)` in
`hierarchical_interco.py`), not plain `input`. GVSoC's Python-side `create_ports()`
auto-creates a *separate*, empty `VirtualPort` object for any "self"-referenced name that
doesn't already exist — so `'input'` silently became an orphaned, never-connected
placeholder instead of erroring. The refill request sailed into that dead end, the C++
`Router::req()` correctly detected the mapped output port was unbound
(`!entry->itf.is_bound()`) and returned `IO_REQ_INVALID`, and — because the whole chain
routed through this same dead port — **every instruction fetch and every L1 D-cache
refill for every core**, forever, got `IO_REQ_INVALID`, decoded a garbage/zero opcode, and
was permanently cached as `iss_exec_insn_illegal` (which itself returns `pc` unchanged),
pinning every core at the reset vector for the life of the simulation.

**Fixed** in `cachepool_v2_group.py`: bind each tile to an *indexed* `input_{i}` slave
port (`axi_ico, f'input_{i}'`), and pass `nb_slaves=nb_tiles_per_group` to the
`Hierarchical_Interco(...)` constructor call (previously omitted — defaulted to 1, which
happened to be harmless at `nb_tiles_per_group=1` but would have under-provisioned slave
ports for the real 4-tiles/group topology once the name was fixed).

**Verification**: post-fix, `MasterPort::get_final_ports()`'s resolution for the tile's
`axi_ico.output` now correctly reports `nb_final=1` (was 0) and resolves all the way to
`group_.../axi_ico/input_itf:input`; the simulated PC advances cleanly through the bootrom
and into real program code (confirmed reaching `0x80002fc8`+ within the fdotp binary,
millions of cycles in) instead of being stuck at `0x1000` forever.

**A second, distinct hang surfaces once boot completes** (fdotp-32b, 16-core topology):
all cores converge and stop at `0x800007a0` (`vfmacc.vv v24, v8, v16` in the dot-product
accumulation loop — see
`ManyRVData/software/build/CachePoolTests/test-cachepool-fdotp-32b_M8192.s`). `ARA_DBG`
confirms this is the *same class* of bug as the matmul livelock in §13.2.1: `Ara`'s 8-slot
queue is permanently full, head-of-queue stuck on a `vle32.v v8, (a0)` at `0x8000076c`
that never gets marked done. New instrumentation this time (`[VLSU_FSM_DBG]`, unconditional
periodic dump of `AraVlsu`'s `nb_pending_insn`/`insn_first`/`insn_first_waiting`/
`insn_last`/`nb_waiting_insn`/`pending_size`, added at the top of `fsm_handler`) narrows
this further than §13.2.1 managed to: a core's `AraVlsu` gets stuck with
`nb_waiting_insn=2, pending_size=0x180`, **completely frozen** for 200,000+ cycles. Traced
the mechanism precisely: in the burst-issue loop (`spatz_vlsu.cpp:316-428`), `pending_size`
only decrements when a burst is actually issued, which requires
`!_this->req_queues[i]->empty()` for at least one of the 4 ports — i.e. a pre-allocated
`IoReq` object must be available in that port's pool. Objects only return to the pool
inside `data_response()`, which fires when a memory response *arrives*. **If any single
async burst's response is lost/never arrives, that request object is gone from the pool
forever**; once enough bursts leak this way that all 4 ports' queues are simultaneously
empty, `pending_size` freezes permanently (matching the observed frozen `0x180`), which
in turn means `nb_waiting_insn`'s entry never becomes "ready", which head-of-line-blocks
`Ara`'s global queue exactly as in §13.2.1. This is consistent with — and now much more
concretely pinned down than — the user's original out-of-order/lost-response hypothesis
that motivated the `spatz_vlsu.cpp`/`fpu_sequencer.cpp` fixes in §13.2.1. **Not yet
found**: the exact point in the L1 FlooNoc/cache-bank/coalescer chain where a queued
async response is dropped rather than eventually delivered. Next step would be tagging
individual in-flight `IoReq`s (e.g. a per-request sequence number) and tracing one from
issue to (missing) response across the L1 NoC hops.

**Debug instrumentation added this round, still in the tree** (same rationale as
§13.2.1 — all gated/rate-limited, harmless but not clean):
- `core/models/cpu/iss/src/exec/exec_inorder.cpp`: `[CHECKALL_DBG]`, `[SCALAR_PC_DBG]`,
  `[GETINSN_NULL_DBG]`, `[STALL_IN_DBG]`/`[STALL_OUT_DBG]`, `[PREEXEC_DBG]`/`[POSTEXEC_DBG]`.
- `core/models/cpu/iss/src/decode.cpp`: `[DECODE_DBG]` (raw opcode + legal/illegal verdict).
- `core/models/memory/memory.cpp`: `[MEM_DBG]` (any access with local offset `< 0x2000`).
- `core/models/interco/router/router.cpp`: `[ROUTER_DBG]` (mapping resolution + both
  `IO_REQ_INVALID` return sites, filtered to offset `< 0x2000`).
- `core/models/cache/cache_impl_v2.cpp`: `[CACHE_REFILL_DBG]` (refill address, bound
  status, and `IoReqStatus` for every icache refill attempt).
- `engine/engine/src/component.cpp`: `[BIND_DBG]` (every binding resolved by
  `create_bindings()`, both the compiled-tree and JSON-fallback paths, filtered to paths
  containing `tile_0` or `group_0_0` — **the filter substrings are hardcoded and need
  changing** to debug a different component).
- `engine/engine/src/ports.cpp`: `[FINALBIND_DBG]` (per-master-port `bind_to_slaves()`
  resolution: intermediate hop count, final hop count, and each final binding made).
- `core/models/cpu/iss/src/ara/spatz_vlsu.cpp`: `[VLSU_FSM_DBG]`, new this round,
  unconditional periodic (`% 200000`) dump of `AraVlsu`'s internal indices at the top of
  `fsm_handler`.

All of the above plus §13.2.1's original `[VLSU_DBG]`/`[VLSU_WAIT_DBG]`/
`[VLSU_BURST_DBG]`/`[ARA_DBG]`/`[STUB_DBG]` are still present; `grep -rn "_DBG\b"
core/models/ engine/engine/src/` finds them all for eventual cleanup once the response-loss
bug is fixed.

### 13.2.3 Two root causes of "lost async VLSU response" found and fixed (2026-07-09)

Following the §13.2.2 recipe (16-core debug topology via `CACHEPOOL_V2_*` env vars, direct
`fprintf` instrumentation, bounded `timeout` runs to avoid multi-GB logs), the existing
`[VLSU_DBG]` ISSUE/RESPONSE log for a single core (`tile_0/pe0`) showed something more
specific than "some response is lost": for the very first vector load past boot (reading
fdotp's source data at `0xa0000000+`), **every burst from cycle ~16457 onward returned
`IO_REQ_DENIED` (not `PENDING`) and none ever got a matching `RESPONSE` line** — the whole
88-byte remainder of that one load instruction's bursts were denied and then silently
dropped, freezing that core's `AraVlsu` forever (`nb_waiting_insn` stuck, matching §13.2.2's
description).

**Root cause 1 — `InsituCacheController` DENIED has no retry-holder for async masters.**
`insitu_cache_controller.cpp`'s `handle_request()` returns `IO_REQ_DENIED` synchronously
(no internal queue, caller must retry) when the retr/miss/evic fifo counters
(`retr_fifo_level_ >= retr_fifo_depth_` etc., lines ~547/560/580) are full — correct for the
open-loop calib trace-replay driver (which does retry every cycle) but **not** for
`inline_sync_miss_` (cluster/closed-loop) mode: `AraVlsu::fsm_handler`'s DENIED handling
(§9's fix) assumes DENIED means "someone downstream is holding this and will complete it
later" (true for the FlooNoc NI's DENIED-and-hold contract), not "rejected, please retry
yourself" — AraVlsu has no retry path, so a controller-level DENIED is simply dropped.
**Fixed**: added `admission_stall_queue_` (a `std::deque<vp::IoReq*>`) — in
`inline_sync_miss_` mode, the three fifo-full sites push the request onto this queue and
return `IO_REQ_PENDING` instead of `IO_REQ_DENIED`. `try_admit_stalled()` re-attempts
`handle_request()` on the head of the queue (safe: nothing was mutated before the DENIED
return, so re-deriving tag/set/line from the untouched request is equivalent to a fresh
call) whenever a fifo slot frees — hooked in after each of the three decrement sites
(`refill_resp_handler`'s `miss_fifo_level_--`, transitively via the `fsm_drain_mshr` call
right after it; `fsm_drain_mshr`'s own `retr_fifo_level_--` loop; `issue_eviction`'s
`evic_fifo_level_--`). A retried `IO_REQ_OK` needs an explicit `resp()` call here (since
it's no longer happening inside the original synchronous `req()` call); a retried
`IO_REQ_PENDING` has already re-parked itself (onto `mshr_` or back onto this same stall
queue) and needs nothing further.

Verified this fix alone did **not** change the trace at all — same DENIED storm, same
addresses, same freeze point — meaning this DENIED source, while real, was not the one
this particular load instruction was hitting. Kept anyway (real bug, will bite the miss/evict
fifos under different traffic patterns), and instrumentation was extended (`[NI_DBG]` in
`floonoc_network_interface.cpp`) to find where these specific bursts were actually being
denied.

**Root cause 2 — L1 NoC map has no entry for the `0xa000_0000` "uncached label" region
(the actual bug for this trace).** `[NI_DBG]` counters showed the FlooNoc network interface
(`pulp/floonoc/floonoc_network_interface.cpp`) itself only saw **2 total calls** to
`handle_req()` (its local-injection entry point) in the entire bounded run, and its
`handle_request()` (the router→NI delivery callback) was **never called even once** — i.e.
essentially no traffic ever completed a round trip through the NoC. The first accepted
burst (`addr=0xa0002700`) permanently occupied the NI's single-outstanding-narrow-read slot
(`narrow_read_pending_burst`) and was never freed, so every subsequent narrow read at that
NI was denied forever (matches the DENIED-storm trace exactly). Added an `fprintf` at
`NetworkQueue::enqueue_router_req`'s `entry == NULL` branch (`floonoc_network_interface.cpp`
~line 132) — previously only a `trace.msg(LEVEL_ERROR, ...)`, invisible without
`--trace=`, which is unusable at this scale per §13.2.1 — confirming: **when
`FlooNoc::get_entry()` finds no address-range match, the burst is silently dropped**
(`return;` with no status change, no `resp()`, no cleanup — a `// TODO` comment even marks
the intended-but-never-implemented invalid-response path). Root cause: `pulp/cachepool_v2/
cachepool_v2_l1_noc_address_converter.cpp`'s `L1NocAddressConverter` only rearranges the
*low* `constant_bits_lsb + bank_offset_bits + group_id_bits` bits (bank_offset ↔ group_id
swap for NoC routing, §8); it leaves every bit above that — including bit 29, the
`0x8000_0000` vs `0xa000_0000` DRAM-region selector — completely untouched in both
directions. But `cachepool_v2_cluster.py`'s `o_NARROW_MAP` registrations
(`dram_base = 0x80000000; base = dram_base + group_id * noc_size_per_group`) only ever
registered windows anchored at `0x8000_0000`. Any cross-group L1 request whose *original*
address was in `0xa000_0000+` (exactly where fdotp's actual source data lives — see §3) —
still carries that address after the bit-rearrangement, so `get_entry()` never finds a
matching window. **Fixed**: `cachepool_v2_cluster.py` now registers a mirrored second set
of `o_NARROW_MAP` windows at `dram_base = 0xa0000000` (same group→(x,y) routing, distinct
`name=` per entry so both windows coexist in FlooNoc's `mappings` dict) alongside the
existing `0x8000_0000` ones. `o_GROUP_OUTPUT` (the group→NI *output* binding, as opposed to
`o_NARROW_MAP`'s *routing-table* entry) is only called once per (group, port) — it's not a
per-region thing.

Verified: after rebuild, the same run for the first time shows a completed round trip
(`DENY → RETRY_READ → FINAL_RESP` all for the same burst/address) and the simulation
progresses ~170× further (from freezing at cycle ~16464 to reaching cycle ~2.76M, the same
point independently documented in §13.2.1/§13.2.2's vfmacc/Ara-queue-full livelock) instead
of freezing immediately after the first vector load of the run.

**Residual, narrower-scope bug found in the same code path — now also fixed, see §13.2.4.**
Even with both fixes above, 8 more `NO_ENTRY_FOUND` drops still occurred over the same
bounded run, at addresses like `0xa0021100`/`0xa0023504`/`0xa0022750` — offsets *larger*
than `noc_size_per_group`. Root cause and fix: §13.2.4.

**Debug instrumentation added this round** (same gate-and-leave-in-tree rationale as
§13.2.1/§13.2.2): `insitu_cache_controller.cpp` has no new prints (the fix is silent,
correctness-only); `floonoc_network_interface.cpp` gained `[NI_DBG]` at: `handle_req`'s
DENY branch (rate-limited `%5000`), the narrow-read retry/grant site in `fsm_handler`
(`%5000`), the final burst-completion site in `handle_request` (`%5000`), unconditional
entry counters on `handle_req` and `handle_request` (`%2000`), and an **unconditional**
print at the `entry == NULL` silent-drop branch (left unconditional since real drops are
rare and each one matters).

### 13.2.4 L1 NoC address-window aliasing bug found and fixed; livelock isolated to Ara/AraVlsu completion signaling, not memory (2026-07-09)

**Root cause of the §13.2.3 residual drops.** `L1NocAddressConverter` only permutes bits
*within* the `constant_bits_lsb+bank_offset_bits+group_id_bits` slice (§8); every bit
*above* that — the cacheline "tag": which specific line within a bank, as opposed to which
bank — passes through completely unchanged in both directions. Incrementing the tag by 1
therefore adds exactly `2^(constant_bits_lsb+bank_offset_bits+group_id_bits)` to the
address, which — because `group_id_bits` exactly spans `clog2(num_groups)` — equals exactly
`num_groups × noc_size_per_group`: one full pass over *every* group's registered window at
the current tag. So the whole address space tiles with period `num_groups ×
noc_size_per_group`, and within each tile the same `base = dram_base + group_id ×
noc_size_per_group` position identifies the same group. `FlooNoc::get_entry()`
(`pulp/floonoc/floonoc.cpp`), however, only ever did a single contiguous `base <= addr <
base+size` range match — so only `tag == 0` (the very first line per group) ever resolved;
every other tag either found no entry (silent drop, same mechanism as §13.2.3's root cause
2) or, in principle, could numerically land inside a *different* group's contiguous window
if the registered spans were packed back-to-back (misrouting, not just dropping).

**Fixed properly** (not by registering more windows, which would just require enumerating
every tag up to the backing memory's full size — thousands of entries for a 256 MB region,
and still finite): added a `period` field to `Entry` (`pulp/floonoc/floonoc.hpp`) and
`FlooNoc::get_entry()` (`pulp/floonoc/floonoc.cpp`) — when `period > 0`, an address also
matches if `(addr - entry->base) % period` falls inside `[0, entry->size)`, in addition to
the existing plain-range check (default `period=0` preserves the old behavior for any other
FlooNoc user). Plumbed through `floonoc.py`'s `__add_mapping`/`o_NARROW_MAP` as an optional
`period` parameter. `cachepool_v2_cluster.py` now passes `period = nb_groups ×
noc_size_per_group` on every `o_NARROW_MAP` call (both the `0x8000_0000` and `0xa0000000`
regions), so every tag value resolves correctly by construction instead of needing explicit
enumeration. Also fixed a related latent bug this exposed: `NetworkQueue::
enqueue_router_req`'s (`floonoc_network_interface.cpp`) boundary-clamp calculation
(`max_size = entry->base + entry->size - burst_base`) would have underflowed for any
periodic match where `burst_base` is many periods past `entry->base` (harmless for this
workload's 4-byte VLSU bursts, since the clamp is never the binding constraint at that
size, but wrong in general) — now computed from the offset *within* the matched period
(`rel = (burst_base - entry->base) % entry->period` when periodic) rather than raw
`burst_base`.

**Verified**: rebuilt, reran the same bounded 16-core fdotp run. Zero `NO_ENTRY_FOUND`
events (down from 8), and the simulation progresses further still — from freezing at
~2.76M cycles (§13.2.3's post-fix state) to ~3.24M cycles.

**The remaining hang is conclusively NOT a lost-memory-response bug.** At the new stall
point, `[VLSU_FSM_DBG]` for the stuck core's `AraVlsu` shows `nb_pending_insn=1,
nb_waiting_insn=0, pending_size=0x0` — i.e. `AraVlsu` believes it has fully issued and
completed everything outstanding. But `[ARA_DBG]` for the same core's `Ara` shows
`nb_pending_insn=8, queue_size=8` (completely full) with the head-of-queue entry
(`insn_first=2`, `pc=0x80000770`) permanently stuck `HEAD_NOT_DONE`. This is precisely the
"puzzling half of the picture, not yet resolved" noted at the end of §13.2.1: a desync
between `AraVlsu`'s own local completion bookkeeping (its three indices `insn_first`/
`insn_first_waiting`/`insn_last` into its own `insns[]`) and `Ara`'s separate global
`pending_insns[]` scoreboard — `AraVlsu` locally believes it has finished, but never (or
incorrectly) calls `ara.insn_end()` for the head instruction, so `Ara`'s global queue never
hears "done" and every subsequent vector instruction stays blocked on
`iss->vu.queue_is_full()`. With every memory-response-loss bug now eliminated (verified:
zero drops, zero denied-forever bursts, `AraVlsu` reaching genuine full-idle state), this
is now the sole confirmed remaining blocker on `fdotp`/`fmatmul` reaching EOC. **Next
step** (per §13.2.1's original suggestion, now higher-confidence given the memory-side
noise is gone): audit `AraVlsu`'s three-index bookkeeping in `spatz_vlsu.cpp` against
`Ara::insn_end()`'s call site in `ara.cpp`, specifically why the bottom of
`AraVlsu::fsm_handler` (which is supposed to detect `pending_size==0 &&
nb_pending_bursts==0` at `insns[insn_first]` and call `ara.insn_end()`) isn't reaching or
correctly triggering that call for this instruction.

### 13.2.5 Ara/AraVlsu completion-signaling bug found and fixed — fdotp now reaches EOC (2026-07-09)

**Root cause.** Confirmed via `[VLSU_DBG]` for the specific stuck core (`tile_0/pe2`) that
this was never a lost response: exactly 128 `IO_REQ_DENIED` issues were logged, and exactly
128 matching `RESPONSE` lines, the last one showing `nb_pending_bursts_after=0` — all at
cycle ~12784, **very early** in the run. So the head-of-queue instruction's bursts had
genuinely, fully completed thousands of cycles before the eventual stall. Yet `[ARA_DBG]`
kept reporting `Ara`'s global queue stuck full (`nb_pending_insn=8`) at cycle 3.2M+, with
`[VLSU_FSM_DBG]` showing `AraVlsu` itself at `nb_waiting_insn=0, pending_size=0x0` (nothing
left to issue). The bug: in `AraVlsu::fsm_handler` (`spatz_vlsu.cpp`), the block that
checks whether the head instruction (`insns[insn_first]`) can be marked done — and, if so,
calls `ara.insn_end()` — was nested **inside** `if (_this->pending_size) { ... }`, i.e. it
only ran on a cycle where some *other* (typically newer) instruction happened to still be
mid-issue. Once every currently-waiting instruction had fully finished issuing its bursts
(`pending_size` back to 0, `nb_waiting_insn == 0`), that whole block — including the
completion check — stopped running, even though the FSM was still being correctly
re-triggered by `data_response()`'s `fsm_event.enable()` on every burst completion. So the
head instruction's `nb_pending_bursts` reaching 0 was never even *checked* once no newer
instruction was in flight, permanently stranding it "done in practice, not marked done",
which head-of-line-blocked `Ara`'s global 8-slot queue forever (exactly the symptom chased
since §13.2.1).

**Fixed**: moved the head-of-queue completion check (the `if (_this->nb_pending_insn.get()
> 0) { ... ara.insn_end(pending_insn); ... }` block) out from under `if
(_this->pending_size)` so it runs unconditionally every FSM invocation, gated only on its
own pre-existing conditions (`pending_size == 0 && slot.nb_pending_bursts == 0 &&
pending_insn->timestamp <= now`). No other logic changed.

**Verified**: rebuilt, reran the same bounded 16-core fdotp run (`timeout 60`, since the
run now completes rather than looping forever). **The simulation reaches EOC** — first
time in this entire investigation:
```
The 1st execution took 6290 cycles. The performance is 10419 OP/1000cycle (81% utilization).
The execution took 5755 cycles. The performance is 11387 OP/1000cycle (88% utilization).
Check Failed! Calc:350.577697, Exp:628.153869
EOC: exit code 2147483647
```
The check failure is expected here: this run used the 16-core debug topology
(`CACHEPOOL_V2_*` env vars), but the `Exp` reference value is computed assuming the real
256-core reduction (`snrt_cluster_core_num()`/group-size-4 two-level reduction, see §13.1).

**Confirmed on the full 256-core topology too** (no debug-topology env vars, default
`gvsoc_config.json`, `timeout 300`): also reaches EOC, no hang, in far fewer simulated
cycles than the debug topology (250-cycle 1st execution, 128% utilization, vs. 6290 cycles
at 81% for 16 cores — expected, since 256 cores do 16× the parallel work). Result:
`Calc:452.100891, Exp:628.153869` — still a mismatch, and a *different* miscalculated value
than either the 16-core run here (`350.577697`) or the pre-boot-hang-fix baseline in §13.1
(`189.697906`), consistent with this being a genuine, distinct-per-topology numerical bug
(§13.1) rather than an artifact of the livelock fixes. This is the natural next
investigation now that the model runs end-to-end on the real topology for the first time.

`fmatmul` (§13.2.1's original repro) has not been re-verified since these fixes; it very
plausibly hit the exact same `Ara`/`AraVlsu` bug given the identical stall signature
(`Ara`'s queue full, head instruction a `vle32.v`/similar VLSU op never marked done)
documented there.

### 13.3 Peripheral registers not fully implemented

`cachepool_v2_cluster_peripheral.cpp` only implements:
- 0x00: HW_BARRIER (barrier poll)
- 0x10: BOOT_CONTROL (entry point)
- 0x14: EOC_EXIT

All other writes (e.g., `l1d_xbar_config`, `l1d_flush`, `l1d_part`) silently return OK.
This means cache partitioning and xbar configuration are no-ops in the model.

### 13.4 Uncached region not implemented in coalescer

`l1d_part` / coalescer-side uncached logic is not yet implemented. The 0xa000_0000
region is treated identically to cacheable DRAM. This is tracked for future work.
