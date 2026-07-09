# CachePool v2 GVSoC Model — Architecture

> Last updated 2026-07-09. Describes the GVSoC simulation model, not the RTL directly.
> RTL reference is at `/scratch/diyou/cachepool/gvsoc/ManyRVData/` (read-only).
> **Status as of 2026-07-09**: the long-standing permanent-boot-hang bug (every core stuck
> forever at the reset vector) is root-caused and fixed — see §13.2.2. A second, distinct
> vector-pipeline livelock (same class as the matmul hang in §13.2.1/§13.2.2, lost async
> VLSU memory responses) now blocks `fdotp` shortly after boot; neither `fdotp` nor
> `fmatmul` reaches EOC yet. The fdotp numeric-mismatch item in §13.1 predates the boot-hang
> fix and has **not** been re-verified since (blocked by the new vector livelock before it
> can reach the final check).

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
now **hangs forever** instead (verified 2026-07-08) — see §13.2.1 for the ongoing
investigation. Not yet a working matmul run.

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
