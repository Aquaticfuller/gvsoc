# InSitu Cache — Architecture & Microarchitecture Documentation

> Intended audience: engineers building a cycle-accurate (GVSoC-style, event-based) performance model of the InSitu cache as integrated in the CachePool system.
>
> All file references are relative to the repository root unless otherwise noted. Line numbers correspond to the checkout at the time of writing (2026-04-19) and may drift slightly.

## Repository Location

**Absolute path of the CachePool project**:
```
/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData
```

All paths below are relative to this root. For direct RTL inspection, prepend the absolute path:

| Component | Absolute path |
|-----------|---------------|
| Cluster (top) | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/hardware/src/cachepool_cluster.sv` |
| Tile | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/hardware/src/cachepool_tile.sv` |
| Core complex | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/hardware/src/cachepool_cc.sv` |
| Cache package | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/hardware/src/cachepool_pkg.sv` |
| Cache top | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/working_dir/insitu-cache/src/insitu_cache/insitu_cache_top.sv` |
| Cache wrapper | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/working_dir/insitu-cache/src/insitu_cache/insitu_cache_tcdm_wrapper.sv` |
| Cache core | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/working_dir/insitu-cache/src/insitu_cache/insitu_cache_core.sv` |
| Forwarding buffer | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/working_dir/insitu-cache/src/utilities/sram_forwarding_buffer.sv` |
| Coalescer (write merger) | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/hardware/deps/insitu-cache/src/coalesce_unit/write_merger/write_through_merger.sv` |
| Config | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/config/cachepool.hjson`, `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/config/config.mk` |
| Software tests | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/software/tests/` |
| Simulation script | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/sim/bin/cachepool_cluster.vsim` |
| This doc | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData/working_dir/insitu-cache/doc/insitu_cache_architecture.md` |

**Note on modified vs. original files**: The `working_dir/insitu-cache/` directory is a local Bender checkout where RTL modifications live (forwarding buffer, FSM changes, etc.). The `hardware/deps/insitu-cache/` tree is the vendored original. When inspecting cache behavior, always refer to `working_dir/insitu-cache/`.

**Git branch**: `zexin/cachepool_dev_refactoring` (in the `working_dir/insitu-cache/` submodule). The parent `ManyRVData` repo is on `dev/cache-refactoring-multi-tile`.

---

## 1. System Overview

### 1.1 Top-Level Integration

```
             ┌─────────────────────────────────────────────────┐
             │                  CachePool Cluster              │
             │                                                 │
             │  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
             │  │  Tile 0  │  │  Tile 1  │  │  Tile N-1│      │
             │  │          │  │          │  │          │      │
             │  │  Cores   │  │  Cores   │  │  Cores   │      │
             │  │   ↕      │  │   ↕      │  │   ↕      │      │
             │  │ TCDM IC  │  │ TCDM IC  │  │ TCDM IC  │      │
             │  │   ↕      │  │   ↕      │  │   ↕      │      │
             │  │ L1 D$    │  │ L1 D$    │  │ L1 D$    │      │
             │  │ (4 ctrl) │  │ (4 ctrl) │  │ (4 ctrl) │      │
             │  └────┬─────┘  └────┬─────┘  └────┬─────┘      │
             │       │             │             │             │
             └───────┼─────────────┼─────────────┼────────────┘
                     └──── AXI ────┴─────────────┘
                                   │
                              ┌────▼────┐
                              │ L2/DRAM │
                              └─────────┘
```

### 1.2 Key Files

| File | Purpose |
|------|---------|
| `hardware/src/cachepool_cluster.sv` | Top-level cluster, tile instances, AXI top-level |
| `hardware/src/cachepool_tile.sv` | Tile with cores + cache controllers + TCDM interconnect |
| `hardware/src/cachepool_cc.sv` | Core complex: Snitch scalar + Spatz vector |
| `working_dir/insitu-cache/src/insitu_cache/insitu_cache_top.sv` | Cache top-level: write merger, refill FIFOs, etc. |
| `working_dir/insitu-cache/src/insitu_cache/insitu_cache_tcdm_wrapper.sv` | Cache controller: core FSM, SRAM banks, LRU RF, dirty RF, access controllers |
| `working_dir/insitu-cache/src/insitu_cache/insitu_cache_core.sv` | Cache core: main FSM, MSHR, hazard detection, refill/eviction logic |
| `working_dir/insitu-cache/src/utilities/sram_forwarding_buffer.sv` | 1-entry write-back forwarding buffer (per access controller) |

### 1.3 Canonical Configuration (cachepool_512)

| Parameter | Value | Source |
|-----------|-------|--------|
| `num_tiles` | 1 | `config/config.mk` |
| `num_cores` | 4 | `config/config.mk` |
| `num_cores_per_tile` | 4 | `config/config.mk` |
| `l1d_cacheline_width` | 512 bits | `config/config.mk` |
| `l1d_num_way` | 4 (per cache controller) | `config/config.mk` |
| `l1d_tile_size` | 256 KB | `config/config.mk` |
| `l1d_depth` | 4096 entries (per tile) | derived |
| `l1d_bank_factor` (`L1BankFactor`) | 2 | `cachepool_pkg.sv` |
| `PartSplit` (data bank) | 4 (folded) | `cachepool_pkg.sv` |
| `NumPseudoDualBanks` | 2 | `cachepool_pkg.sv` |
| `NumL1CacheCtrl` | 4 (one per core) | `cachepool_pkg.sv:118` |
| `NumL1CtrlTile` | 4 (controllers per tile) | `cachepool_pkg.sv:119` |
| `SetAssociativity` (per ctrl) | 4 | derived |
| `CacheBankDepth` | 128 (`NumCacheEntry / SetAssoc`) | derived |
| `vlen` (Spatz) | 512 bits | `config/cachepool.hjson` |
| `NumSpatzFPUs` | 4 | `cachepool_cc.sv` |
| `TCDMPorts per core` | 5 (1 Snitch + 4 Spatz) | `cachepool_cc.sv:101` |
| `NarrowDataWidth` | 32 bits | `cachepool_pkg.sv` |
| `RefillDataWidth` | 128 bits | `cachepool_pkg.sv:140` |
| `UseHashWaySelect` | 1 (hash-based way selection) | `cachepool_cluster.sv` |

---

## 2. Data Path Overview

### 2.1 Core → Cache (request path)

```
Snitch/Spatz TCDM port (32b data)
        │
        ▼
TCDM cache interconnect (tcdm_cache_interco)
  · per-port arbiter
  · address-based controller selection
  · routes each request to one of N cache controllers
        │
        ▼
Cache controller [i] (1 per core)
  · insitu_cache_tcdm_wrapper (SRAM banks + access controllers)
  · insitu_cache_core (FSM, MSHR, refill/eviction)
        │
        ▼ on miss
Refill/eviction request (128b wide)
        │
        ▼
AXI interconnect → L2 / DRAM
```

### 2.2 Cache → Core (response path)

```
On cache hit:
  bank SRAM → access controller → cache core FSM → response FIFO
      → arbiter (winfo FIFO for writes) → TCDM response

On cache miss:
  wait for refill → merge refill with MSHR subarrays
      → retr_fifo → response arbiter → TCDM response
```

### 2.3 Address Interleaving Across Controllers

Addresses are hashed/scrambled to distribute across controllers. The `dynamic_offset` (cachepool_tile.sv:547) controls which address bits select the controller.

- `tile address bits[dynamic_offset +: log2(NumL1CtrlTile)]` selects the cache controller
- For `NumL1CtrlTile=4`, `dynamic_offset=2` (cache-line interleaving at 4-byte granularity), bits [3:2] select

Cores use `l1d_xbar_config(offset)` (see `cache-line-rw-smoke/main.c`) to configure this at runtime.

---

## 3. Configuration Parameters Reference

### 3.1 Compile-Time Parameters

From `cachepool_pkg.sv`:
```systemverilog
localparam int unsigned NumCores           = NUM_CORES;          // default 4
localparam int unsigned NumTiles           = NUM_TILES;          // default 1
localparam int unsigned NumL1CacheCtrl     = NumCores;           // 1:1
localparam int unsigned NumL1CtrlTile      = NumL1CacheCtrl/NumTiles; // 4
localparam int unsigned L1AssoPerCtrl      = L1D_NUM_WAY;        // 4
localparam int unsigned L1LineWidth        = L1D_CACHELINE_WIDTH; // 512
localparam int unsigned L1CacheWayEntry    = L1D_DEPTH;          // 1024 per way
localparam int unsigned L1BankFactor       = 2;
localparam int unsigned NumDataBankPerCtrl = (L1LineWidth/WordWidth) * L1AssoPerCtrl * L1BankFactor;
```

### 3.2 Derived Cache Geometry

For `l1d_tile_size=256KB`, `cacheline=512b`, `num_cores_per_tile=4`, `num_way=4`:

| Quantity | Computation | Value |
|----------|-------------|-------|
| Total entries per tile | 256 KB / 64 B | 4096 |
| Entries per controller | 4096 / 4 ctrl | 1024 |
| Entries per way (`CacheBankDepth`) | 1024 / 4 ways | 128 |
| Data banks per way | 16 words × 2 pseudo-banks | 32 |
| Meta banks per way | 2 pseudo-banks | 2 |
| Total data TCDM banks | 32 × 4 ways × 4 ctrl | 512 |

### 3.3 FIFO Depths (insitu_cache_top.sv)

| FIFO | Purpose | Depth |
|------|---------|-------|
| `WriteThroughFifoDepth` | Coalesced write requests to L2 | 4 |
| `WRespFifoDepth` | Pending write-response infos | 4 |
| `RespFifoDepth` | Read hit responses | 4 |
| `RetrFifoDepth` | MSHR retrievals (refill responses) | 4 (16 in newer builds) |
| `MissFifoDepth` | Miss requests to L2 | 4 |
| `EvicFifoDepth` | Eviction (writeback) requests to L2 | 4 |

---

## 4. Core Complex (Snitch + Spatz) Interface

### 4.1 TCDM Ports per Core

`cachepool_cc.sv:100-101`:
```systemverilog
parameter int unsigned NumMemPortsPerSpatz = NumSpatzFUs;         // =4
parameter int unsigned TCDMPorts = RVV ? NumMemPortsPerSpatz + 1 : 1;  // =5
```

- **Port 0..3**: Spatz vector memory ports (used by FPU/IPU for vle/vse etc.)
- **Port 4**: Snitch scalar load/store (lw/sw, stack)

### 4.2 TCDM Request/Response Format

From `cachepool_pkg.sv`:
```systemverilog
// tcdm_req_chan_t (32b address, 32b data, 4b strobe, user)
typedef struct packed {
    logic [31:0]      addr;
    logic             write;
    logic [31:0]      data;
    logic [3:0]       strb;
    tcdm_user_t       user;  // {core_id, is_amo, req_id, is_fpu}
} tcdm_req_chan_t;

// tcdm_rsp_chan_t
typedef struct packed {
    logic [31:0] data;
    logic        error;
    logic        write;
} tcdm_rsp_chan_t;

// Full tcdm_req_t (valid/ready for both directions)
typedef struct packed {
    logic             q_valid;
    tcdm_req_chan_t   q;
    logic             p_ready;
} tcdm_req_t;

typedef struct packed {
    logic             q_ready;
    logic             p_valid;
    tcdm_rsp_chan_t   p;
} tcdm_rsp_t;
```

### 4.3 Core-Side Response Buffering

`cachepool_cc.sv:330-362`: Each core has a per-port response FIFO (depth = `NumSpatzOutstandingLoads`, default 32). This lets the core issue up to 32 outstanding loads per port before needing a response.

The `req_id` field (log2 of outstanding loads) is used to tag requests and match responses.

---

## 5. TCDM Cache Interconnect

`cachepool_tile.sv:553-576`

- Each core has 5 TCDM ports
- Each port feeds into a `tcdm_cache_interco` instance
- The interco routes to one of the N cache controllers based on the address

**Per-port per-tile**:
- 5 TCDM master ports per core (from cc)
- 4 cache controllers per tile
- Total: 5 × 4 = 20 request paths from the 4 cores of one tile, each arbitrated into 4 cache controllers

**Arbitration**: Round-robin (see `tcdm_cache_interco` module). Backpressure is via ready signals.

**Timing**:
- Request: 1 cycle through interco to cache
- Response: 1 cycle back
- Total round-trip adds **2 cycles** over the bare cache latency

---

## 6. Cache Controller (insitu_cache_tcdm_wrapper.sv)

### 6.1 Hierarchy

```
insitu_cache_tcdm_wrapper
├── insitu_cache_core          (FSM, MSHR, hazard detection)
├── lru_rf                     (LRU register file)
├── dirty_rf                   (dirty flags register file)
├── gen_cache_banks[way]       (per-way, for SetAssociativity ways)
│   ├── insitu_cache_bank_access_controller (data)
│   │   ├── sram_forwarding_buffer
│   │   └── (feeds pseudo_dual_port for data)
│   ├── pseudo_dual_port_tcdm_wrapper (data bank)
│   ├── insitu_cache_bank_access_controller (meta)
│   │   ├── sram_forwarding_buffer
│   │   └── (feeds pseudo_dual_port for meta)
│   └── pseudo_dual_port_tcdm_wrapper (meta bank)
└── coalescer (in insitu_cache_top, write_through_merger)
```

### 6.2 Data & Meta SRAM Banks

**Data bank (per way, per pseudo-bank):**
- Stores `CacheLineWidth / WordWidth = 16` words per entry
- With `PartSplit=4`: folded — 4 parts × 4 words per part = 16 words
- Each word is a separate TCDM bank (4-byte granularity)
- Total TCDM data ports per way: `NumPseudoDualBanks × NumWordsPerLine = 2 × 16 = 32`

**Meta bank (per way, per pseudo-bank):**
- Width: `$bits(cache_meta_t)` = tag + status + dirty + mask + miss_meta + LRU ≈ 80 bits
- `PartSplit = 1` (never folded for meta)
- `NumWordsPerLine = 1`

**Physical organization (Folded, PartSplit=4):**
- `FoldedDataDepth = CacheBankDepth × PartSplit = 128 × 4 = 512` per physical SRAM
- Skewed addressing: `ColIdx = group × EffectiveFoldWayGroup + ((way + part) % EffectiveFoldWayGroup)`
- Ways share physical columns via skewed mapping
- Reduces SRAM instances by `PartSplit` at the cost of partial reads

### 6.3 Address Decomposition (at the cache controller)

Input address from interco → set index, way index, part index.

```
[31: ] [x:y]    [y-1: z]  [z-1: w]  [w-1: 0]
 tag    set idx  part idx  word idx  byte offset
```

- **Set index** (`bank_read_cache_addr`): `$clog2(CacheBankDepth)` bits → selects row in SRAM
- **Part index**: `$clog2(PartSplit)` bits → selects which part to read (folded mode only)
- **Way**: hash-computed (`UseHashWaySelect=1`) or LRU-selected
- **Word index within part**: `$clog2(PartWords)` bits
- **Byte offset**: `$clog2(WordWidth/ByteWidth) = 2` bits

### 6.4 LRU Register File (`lru_rf`)

`insitu_cache_tcdm_wrapper.sv:1187-1211`

- **Storage**: `way_ptr_t [SetAssociativity-1:0] lru_rf [CacheBankDepth-1:0]`
- **Depth**: `CacheBankDepth = 128`
- **Width**: `SetAssociativity × $clog2(SetAssociativity) = 4 × 2 = 8` bits per entry
- **Ports**: dual-port (1R + 1W per cycle)
  - Read: combinational from `bank_read_cache_addr_q` (1-cycle registered)
  - Write: edge-triggered on `bank_write_LRU_req | bank_write_cache_req`
- **Purpose**: Avoids meta SRAM write on pure LRU updates (every read hit)

### 6.5 Dirty Register File (`dirty_rf`)

`insitu_cache_tcdm_wrapper.sv:1214-1239`

- **Storage**: `logic [SetAssociativity-1:0] dirty_rf [CacheBankDepth-1:0]`
- **Depth**: `CacheBankDepth = 128`
- **Width**: `SetAssociativity = 4` bits per entry (1 bit per way)
- **Ports**: 1R (combinational) + 1W (edge-triggered on `bank_write_cache_req`)
- **Purpose**: Fast dirty bit tracking; avoids meta SRAM write on dirty-only updates

### 6.6 Meta Skipping

Meta SRAM writes are skipped when:
- Only LRU changed (`bank_write_LRU_req` without `bank_write_cache_req`) → LRU RF handles it
- Only dirty changed (write hit on VALID line) → dirty RF handles it (`bank_write_meta_skip=1`)

This is the reason `meta_proc_write_req` is gated at `insitu_cache_tcdm_wrapper.sv:1349-1359`:
```systemverilog
if (bank_write_cache_req && !bank_write_meta_skip &&
    !mc_suppress_meta_write &&
    (proc_write_cache_way == way_ptr_t'(i))) begin
    meta_proc_write_req = 1'b1;
end
```

---

## 7. Cache Core Microarchitecture (insitu_cache_core.sv)

### 7.1 Core FSM States

`insitu_cache_core.sv:377-385`:
```systemverilog
typedef enum logic [3:0] {
    REQ_PROC = '0,          // Normal request processing
    RESP_STALL,             // Response FIFO full
    MISS_STALL,             // Miss FIFO full
    EVIC_STALL,             // Eviction FIFO full (or PartSplit full-read needed)
    ALL_PEND_STALL,         // All ways are pending (no victim available)
    MSHR_FULL_STALL,        // Read hits pending line, MSHR subarrays full
    WR_CONFLICT_STALL       // Write/read conflict on pending lines
} cache_fsm_status_t;
```

### 7.2 Pipeline Stages

**Request-side pipeline** (upstream request → bank read issue):

```
┌──────────────────────┐
│ Stage 0 (cycle 0):   │ Upstream request arrives at input.
│ upstream_req_valid   │
└──────────┬───────────┘
           │ (combinational: req_buf_push = upstream_req_valid & upstream_req_ready)
           ▼
┌──────────────────────┐
│ Stage 1 (cycle 1):   │ Request latched into req_buf_q (1-entry buffer).
│ req_buf_q            │ Stored with hold bit if hazard detected.
└──────────┬───────────┘
           │ (preread_request_valid → arbiter)
           ▼
┌──────────────────────┐
│ Stage 2 (cycle 1):   │ Preread arbiter selects between requests and refills.
│ stream_arbiter       │ Combinational — output in same cycle.
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ Stage 3 (cycle 2):   │ preread_task_q latched (task ready for FSM).
│ preread_task_q       │
└──────────┬───────────┘
           │ (combinational from preread_task_q)
           ▼
┌──────────────────────┐
│ Stage 4 (cycle 2):   │ FSM REQ_PROC processes task.
│ bank_read_valid_o=1  │ Bank read issued on this cycle.
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ Stage 5 (cycle 3):   │ SRAM data returns (1-cycle SRAM latency).
│ bank_read_cache_data │
└──────────┬───────────┘
           │ (combinational: hit/miss detection)
           ▼
┌──────────────────────┐
│ Stage 6 (cycle 3):   │ Response FIFO push (if hit).
│ resp_fifo_push       │ OR miss FIFO push (if miss).
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ Stage 7 (cycle 4):   │ Response FIFO output → upstream response arbiter.
│ upstream_resp_valid  │
└──────────────────────┘
```

**Total read hit latency: ~4 cycles** from upstream request to upstream response.

### 7.3 Request Buffer (`req_buf_q`)

`insitu_cache_core.sv:519-545, 843-870`

- **Depth**: 1 entry (single register)
- **Fields**: `req_buf_q` (payload), `req_buf_valid_q`, `req_buf_hold_q`, `req_buf_issued_q`
- **Loaded when**: `req_buf_push = upstream_req_valid_i & upstream_req_ready_o`
- **Freed when**: `req_buf_pop = preread_request_valid & preread_request_ready`
- **Hold condition**: `req_buf_hold_d = upstream_req_hazard_match | upstream_req_issue_hazard_now`

**Ready logic (line 841)**:
```systemverilog
upstream_req_ready_o = preread_req_flow_allow & (~req_buf_valid_q | req_buf_pop);
```

### 7.4 Preread Arbiter

`insitu_cache_core.sv:827-836`
- 2-input `stream_arbiter`: requests (port 0) vs. refills (port 1)
- Refills have priority when both are valid (stream_arbiter priorities low-index)
- Output: `bank_read_valid_arb`, `preread_arbiter_payload` (contains `is_refill` flag)

### 7.5 Hazard Detection

`insitu_cache_core.sv:797-804`:
```systemverilog
upstream_req_issue_hazard_now = upstream_req_valid_i & bank_write_req_o &
                                ~bank_write_data_buf_hit_i &
                                (bank_write_addr_o == upstream_req_depth_tmp) &
                                (bank_write_cache_tag_o[bank_write_way_o] == upstream_req_tag_tmp);

req_buf_issue_hazard_now = req_buf_valid_q & bank_write_req_o &
                           ~bank_write_data_buf_hit_i &
                           (bank_write_addr_o == req_buf_depth_tmp) &
                           (bank_write_cache_tag_o[bank_write_way_o] == req_buf_tag_tmp);
```

**Semantics**: A request targeting the same cache line as an in-flight write is delayed. Relaxed when the forwarding buffer absorbed the write.

**Countdown hazard** (`preread_req_hazard_valid_q`): optional N-cycle guard after a write. Default `PrereadReqHazardCycles=0` (disabled — forwarding buffer handles same-cycle conflicts).

### 7.6 MSHR (Miss Status Handling Registers)

`insitu_cache_core.sv:228-239`

**Structure**:
```systemverilog
typedef logic [MaxNumSubarray-1:0][InfoStoreWidth-1:0] mshr_subarrays;
// MSHR data is stored IN the cache bank for pending lines
```

- **Subarrays per line**: up to `MaxNumSubarray = CacheLineWidth / InfoStoreWidth`
- **Global limit**: `RetrFifoDepth` entries (each entry holds subarrays for one refilled line)
- **Status encoding**:
  - `VALID` — line in cache, data valid
  - `READ_PEND` — miss in flight, this line is reserved, pending reads queued
  - `WRITE_PEND` — write-miss in flight, write data merged on refill
- **Pending info storage**: When a read hits a READ_PEND line, the request's `info_t` is stored into the next subarray slot. On refill, all pending infos are retrieved and responded to.

### 7.7 Eviction Path

`insitu_cache_core.sv:2130-2186`

**Victim selection**:
- `UseHashWaySelect=1`: way is deterministic (hash of tag/depth) — no LRU needed for victim selection
- `UseHashWaySelect=0`: LRU-selected (oldest way)

**Eviction data capture**:
- If `PartSplit=1` (unfolded): data is available in the same cycle as meta (1-cycle SRAM read). Direct push to `evic_fifo`.
- If `PartSplit>1` (folded): only 1 part was read initially. Must issue a **full-line read** to get all parts.
  - Sets `evict_full_read_req=1` → 1 cycle
  - Waits for `bank_read_ready_i` → 1 cycle
  - Captures `evict_full_data_q` → 1 cycle
  - **Total: 3-4 cycles** for folded eviction data capture

**Eviction FIFO**: `EvicFifoDepth = 4` entries. Each entry is `{addr, data, mask}` (full cache line). Drained by downstream (L2) via `downstream_req_evic_valid_o`.

### 7.8 Refill Path

`insitu_cache_core.sv:2226-2720`

**Flow**:
1. Refill response arrives at `downstream_resp_refill_valid_i` (128 bits per beat)
2. Accumulated into a full cache line (4 beats for 512-bit line with 128-bit refill width)
3. Pushed into the preread arbiter as a refill task (`is_refill=1`)
4. When arbiter selects refill:
   - `bank_read_all_parts=1` (reads entire line — useful for dirty merge)
   - FSM processes in `REQ_PROC` with `is_refill` branch
5. Merge refill with any dirty bytes (if was WRITE_PEND)
6. Write merged data to cache banks (`bank_write_req_o=1`)
7. If the line was READ_PEND: retrieve MSHR subarrays, push to `retr_fifo`, serve pending responses

**Retrieval FIFO** (`retr_fifo`): `RetrFifoDepth` entries, each containing `{data, subarrays}`. Responses cycle through subarrays, one beat per subarray.

---

## 8. Access Controller + Forwarding Buffer (per way)

### 8.1 Access Controller (`insitu_cache_bank_access_controller`)

`insitu_cache_tcdm_wrapper.sv:1754-2070`

**Purpose**: Serializes read and write to a single SRAM bank (data or meta). Hosts a forwarding buffer for faster repeated access.

**FSM**:
```systemverilog
typedef enum logic {
    ACCESS_THROUGH,   // Normal: passes reads/writes to SRAM
    ACCESS_STALL      // Write stalled (bank_gnt_i=0), resends when granted
} access_status_t;
```

Plus an overlay state `wb_active_q` for explicit writeback.

**Key parameters**:
- `AllowReadDuringWrite`: If 1, allows concurrent R+W via pseudo_dual_port WR_SAME_ADDR. **Disabled for data** (folded banking coherence issue with PartSplit>1). Enabled for meta would be safe but currently off.
- `UseForwardingBuffer`: Enable the 1-entry write-back buffer. Currently: **ON for meta, OFF for data**.
- `UseSpecWbIdle` / `UseSpecWbAddrTrans`: Speculative writeback (fire-and-forget writeback during idle cycles or address transitions).

**Signal flow**:
```
Upstream (from core processing):             Downstream (to pseudo_dual_port):
  upstream_read_valid_i      ─────gate────►   downstream_read_valid_o
  upstream_read_addr_i       ─────gate────►   downstream_read_addr_o
  upstream_read_ready_o     ◄─────gate─────   downstream_read_ready_i
  upstream_read_data_o      ◄────mux─────    fwd_rdata (buffer or sram)
                                              sram_rdata_i
  upstream_write_req_i       ─────gate────►   downstream_write_req_o
  upstream_write_addr_i      ─────gate────►   downstream_write_addr_o
  upstream_write_data_i      ─────gate────►   downstream_write_data_o
  upstream_write_mask_i      ─────gate────►   downstream_write_mask_o
```

### 8.2 Forwarding Buffer (`sram_forwarding_buffer`)

`working_dir/insitu-cache/src/utilities/sram_forwarding_buffer.sv`

**Design**: 1-entry, register-based, write-back cache for one SRAM row.

**State registers**:
```systemverilog
data_t  buf_data_q;                       // Cached row data
addr_t  buf_addr_q;                       // Cached row address (set index)
logic   buf_valid_q;                      // Buffer has valid data
logic   buf_dirty_q;                      // Data modified, needs writeback
logic [PartIdxWidth-1:0] buf_part_idx_q;  // Which part (if PartSplit > 1)
logic                    buf_all_parts_q; // All parts cached (full-line read/write)
```

**Hit types**:
1. **`wr_buf_hit`**: Standard hit — buffer valid, address matches, parts covered, not during SRAM populate
2. **`wr_concurrent_hit`**: SRAM read arriving for the same address in the same cycle — merge write into arriving SRAM data
3. **`wr_full_hit`**: Full-line write (all bytes in mask) to a safe buffer state — populate directly without reading SRAM

**Read hit**: `rd_hit_comb_o=1` → `downstream_read_valid_o=0` (SRAM read suppressed). Buffer provides data one cycle later via registered `buf_rd_data_q` to match SRAM timing.

**Write hit**: `wr_hit_comb_o=1` → `downstream_write_req_o=0` (SRAM write suppressed). Buffer merges bytes, sets `buf_dirty_q=1`.

**Writeback**: When `wb_needed_o=1` (buffer dirty) and a miss occurs, the access controller enters `wb_active_q` state:
- Issues `downstream_write_req_o` with buffer data
- On `bank_gnt_i`: `wb_done` asserted → buffer clean
- Then returns to ACCESS_THROUGH or ACCESS_STALL (if stalled write was pending)

**Speculative writeback** (when enabled): Issues writeback alongside reads during idle cycles or address transitions. Uses pseudo_dual_port's WR_DIFF_BANK to hide writeback latency.

### 8.3 Performance Statistics (per buffer instance)

The buffer exposes 8 stat counters (32b each):
- `stat_rd_hit`, `stat_rd_miss`, `stat_rd_total`: read-side hit tracking
- `stat_wr_merge`, `stat_wr_inval`, `stat_wr_total`: write-side absorption/invalidation
- `stat_sram_rd`: actual SRAM reads issued
- `stat_wb`: writebacks performed

These are emitted at end-of-simulation via a `$display` in a `final` block.

---

## 9. Pseudo-Dual-Port SRAM (`pseudo_dual_port_tcdm_wrapper`)

`insitu_cache_tcdm_wrapper.sv:1429-1724`

**Purpose**: Implements a pseudo-dual-port SRAM from two single-port banks, with per-word read/write arbitration.

**Status states**:
```systemverilog
IDLE, W_ONLY, R_ONLY, WR_DIFF_BANK, WR_SAME_ADDR, WR_CONFLICT
```

### 9.1 Physical Layout

- `NumPseudoDualBanks` physical banks per pseudo-dual-port (typical: 2)
- Lower bits of SRAM address select between banks (even/odd row alternation)
- Each bank has `NumWordsPerLine` word columns (or `NumWordsPerLine/PartSplit` for folded)
- `write_line_buffer` captures last-cycle write data for WR_SAME_ADDR forwarding

### 9.2 Read/Write Status Resolution

```systemverilog
if (read_valid_i & write_has_data) begin
    if (read_bank_select != write_bank_select)
        status = WR_DIFF_BANK;        // Different banks → both proceed
    else if (read_bank_addr == write_bank_addr)
        status = WR_SAME_ADDR;        // Same bank, same row → per-word forwarding
    else
        status = WR_CONFLICT;         // Same bank, different row → read blocked
end else if (read_valid_i) status = R_ONLY;
else if (write_has_data)   status = W_ONLY;
else                       status = IDLE;
```

**Backpressure on conflict**:
```systemverilog
if (status == WR_CONFLICT) begin
    read_ready_o = 1'b0;              // Read cannot proceed this cycle
end
```

### 9.3 Per-Word Forwarding (WR_SAME_ADDR)

For each word `j` of the line:
```systemverilog
bank_rdata_words[i][j] =
    (word_read_en_q[i][j] & word_write_en_q[i][j]) ? write_line_buffer_words[j] :
     word_read_en_q[i][j]                           ? tcdm_bank_rdata_i[...] :
                                                      '0;
```

If a word is both read and written in the same cycle, the forwarding buffer provides the written value (write-first semantics). Otherwise, SRAM read data passes through.

**⚠ Known bug**: With `PartSplit > 1` and `AllowReadDuringWrite=1`, this forwarding has a subtle coherence issue. Currently `AllowReadDuringWrite=0` for data banks.

### 9.4 PartSplit (Folded Mode)

`insitu_cache_tcdm_wrapper.sv:1569-1577`:
```systemverilog
localparam int unsigned WordPart = (j / PartWords);
assign word_in_part[i][j] = read_all_parts_i ? 1'b1 :
    ((PartSplit > 1) ? (read_part_idx_i == WordPart) : 1'b1);
assign word_read_en[i][j] = bank_req_read[i] & read_valid_i & word_in_part[i][j];
```

In folded mode, only `PartWords` words per access are read from SRAM (e.g., 4 words for PartSplit=4). The other positions in `bank_rdata_words[i]` are 0. This halves/quarters SRAM access energy at the cost of multi-cycle full-line access.

---

## 10. Coalescer (Write-Through Merger)

`hardware/deps/insitu-cache/src/coalesce_unit/write_merger/write_through_merger.sv`

**Purpose**: Merges multiple small writes (word-level, 32b) to the same cache line into one wide write (full-line, 512b) before sending to memory.

**FSM**:
```
IDLE → WRITE_COAL (on first write) → FLUSH (on coalescer issue) → IDLE
                 ↓
                 (merge if same tag, flush if new tag / timeout / read conflict)
```

**Parameters**:
- `WatchDogMax = 4` cycles (default): timeout before forcing a flush of the current coalesced line

**Flush triggers**:
1. **New tag** (different cache line): flush current, start new
2. **Watchdog timeout** (`dog_cnt_q==0`): no new writes for 4 cycles, flush
3. **Read conflict**: upstream read monitors pending coalesce; if read address matches pending tag, flush immediately

**Merge logic** (per byte):
```systemverilog
for (int bt = 0; bt < NumBytes; bt++) begin
    if (upstream_req_wmask_i[bt])
        cache_data_in_bytes[bt] = write_data_in_bytes[bt];  // new byte wins
end
coal_meta_d.wmask = coal_meta_q.wmask | upstream_req_wmask_i; // merge masks
```

---

## 11. Downstream Interface (Cache → L2/DRAM)

### 11.1 Interfaces

`insitu_cache_top.sv:120-134` / `insitu_cache_core.sv:130-146`

**Miss request** (`downstream_req_miss_*`):
- `downstream_req_miss_valid_o`
- `downstream_req_miss_addr_o` (cache-line aligned)
- `downstream_req_miss_info_o`: {way, depth, for_write_pend}

**Eviction request** (`downstream_req_evic_*`):
- `downstream_req_evic_valid_o`
- `downstream_req_evic_addr_o`
- `downstream_req_evic_data_o` (full 512-bit line)
- `downstream_req_evic_mask_o` (64-bit byte mask)

**Refill response** (`downstream_resp_refill_*`):
- `downstream_resp_refill_valid_i`
- `downstream_resp_refill_data_i` (128-bit per beat)
- `downstream_resp_refill_info_i`: {way, depth}

### 11.2 AXI Burst Conversion

`cachepool_cluster.sv`
- Cache line: 512 bits
- AXI beat width: 128 bits (typical)
- Burst length: 4 beats per line refill
- Multiple outstanding transactions possible (AXI ID tagging)

---

## 12. Cycle-Accurate Latencies (for Performance Model)

### 12.1 Read Hit Latency

| Stage | Cycles | Cumulative |
|-------|--------|------------|
| Core TCDM request out → interco arbitration | 1 | 1 |
| Interco → cache controller (request buffer) | 1 | 2 |
| req_buf_q → preread_task_q (via arbiter) | 1 | 3 |
| preread_task_q → bank read issue (combinational) | 0 | 3 |
| Bank SRAM read → data available | 1 | 4 |
| Hit detection → response FIFO push (combinational) | 0 | 4 |
| Response FIFO → upstream arbiter | 1 | 5 |
| Cache response → interco → core | 1 | 6 |
| Core response FIFO → consumer | 1 | 7 |

**Total read-hit latency: ~7 cycles** from core request issue to core response receive (steady-state, no stalls).

### 12.2 Read Miss Latency

Added on top of read hit:
- `MissFifoDepth` push: 1 cycle
- L2 latency: D (memory-specific, e.g., 20-100 cycles for L2, more for DRAM)
- Refill beats: `CacheLineWidth / RefillDataWidth = 4` beats
- Refill arbitration + bank write: 2-3 cycles
- MSHR retrieval: 1+ cycles (1 per pending subarray)

**Total read miss latency ≈ 7 + D + 6** cycles (conservative estimate).

### 12.3 Write Latency (write-through on miss, write-back on hit)

**Write hit** (line in cache):
- Same pipeline as read hit through REQ_PROC
- Bank write: 1 cycle
- Write response: 1 cycle after request via winfo_fifo
- **Total: ~4 cycles** (fire-and-forget — core doesn't wait)

**Write miss**:
- Coalescer captures
- After coalescing window (up to 4 cycles): flush to downstream
- Meanwhile, miss request sent to L2 to allocate
- Eviction (if dirty line evicted): + eviction pipeline latency

### 12.4 Backpressure Sources

1. `upstream_req_ready_o = 0` when req_buf holds a hazard
2. `bank_read_ready_i = 0` when any bank's access controller reports not-ready (write in progress without AllowReadDuringWrite, writeback pending, etc.)
3. `resp_fifo_full` or `retr_fifo_full` → FSM enters RESP_STALL
4. `miss_fifo_full` → FSM enters MISS_STALL
5. `evic_fifo_full` → FSM enters EVIC_STALL
6. `downstream_req_*_ready_i=0` → FIFOs back up

---

## 13. Key Signals for Performance Modeling

### 13.1 Per-cycle observables

| Signal | Location | Meaning |
|--------|----------|---------|
| `upstream_req_valid_i / _ready_o` | core boundary | Request handshake |
| `bank_read_valid_o / _ready_i` | core → banks | Bank read handshake |
| `bank_read_cache_ready` | wrapper | AND of all ways' readiness |
| `data_bank_read_ready[i]` | per way | Per-way data bank ready |
| `meta_bank_read_ready[i]` | per way | Per-way meta bank ready |
| `fwd_rd_hit / fwd_wr_hit` | per access controller | Buffer hit (combinational) |
| `fwd_wb_needed` | per access controller | Buffer dirty, needs writeback |
| `cache_status_q` | core FSM | Current FSM state |
| `req_buf_valid_q / _hold_q / _issued_q` | core | Request buffer state |
| `preread_task_q.valid` | core | Task at FSM stage |
| `downstream_req_miss_valid_o / _evic_valid_o` | to L2 | Miss/eviction request issue |
| `downstream_resp_refill_valid_i` | from L2 | Refill response arrival |

### 13.2 Event-based model hooks

For a GVSoC event model, track these as events:

| Event | Source |
|-------|--------|
| `core.tcdm_req_issued` | Per TCDM port on core |
| `interco.arbitrated` | When request wins interco arbitration |
| `cache.req_accepted` | `upstream_req_valid & ready` at cache |
| `cache.req_buf_loaded` | `req_buf_push=1` |
| `cache.preread_issued` | `preread_task_d.valid=1` |
| `cache.bank_read_issued` | `bank_read_valid_o=1` |
| `cache.hit_detected` | FSM detects hit (combinational in REQ_PROC) |
| `cache.miss_issued` | `miss_fifo_push=1` |
| `cache.eviction_issued` | `evic_fifo_push=1` |
| `cache.refill_arrived` | `downstream_resp_refill_valid_i=1` |
| `cache.bank_write_issued` | `bank_write_req_o=1` |
| `cache.resp_pushed` | `resp_fifo_push=1` |
| `cache.resp_issued` | `upstream_resp_valid_o=1` |
| `buf.read_hit` / `buf.write_hit` | Per access controller forwarding buffer |
| `buf.writeback_issued` | Writeback write issued from buffer |

---

## 14. Arbitration Policies

- **TCDM interco → cache**: Round-robin across cores (per port direction)
- **Cache controllers**: Address-based routing (interleaving)
- **Preread arbiter (inside cache core)**: Priority — refills first, then requests (stream_arbiter low-index priority)
- **Response arbiter (inside cache core)**: Priority — MSHR retrievals first (read miss completions), then hit responses
- **Cache top response mux**: Prioritize read/refill responses over write acks; lock selection briefly to avoid oscillation
- **Access controller ↔ pseudo_dual_port**: Pseudo-dual-port FSM resolves R/W conflicts per bank

---

## 15. Known Architectural Properties (Important for Modeling)

1. **Cache is write-back for hits, write-through for coalesced writes** (the coalescer accumulates word writes and sends full lines to L2).

2. **Hash-way selection** (`UseHashWaySelect=1`): eliminates LRU dependency chain; way is deterministic from tag+set. Reduces bank read pressure (only one way's data read per request). LRU RF can be removed.

3. **LRU and dirty stored in register files** (not meta SRAM): separates frequent updates from bulk meta SRAM.

4. **Folded cache (PartSplit=4)**: data SRAMs store 1/4 of a cache line per access. Reduces SRAM port count but requires multi-cycle access for full-line operations (eviction, refill readback).

5. **Meta SRAM uses PartSplit=1**: tag/status is small; always accessed fully.

6. **MSHR stored in cache bank** (not separate structure): subarrays written directly into the cache line's data position. Compact but limits concurrent miss count to subarrays-per-line.

7. **All ways broadcast `bank_write_cache_req`**: writes target one way, but the request signal reaches all ways' access controllers (only the targeted way has non-zero mask). This has performance implications (non-written ways momentarily block reads) and correctness implications for the forwarding buffer (all-ways broadcast can cause cross-way buffer interference).

8. **Preread pipeline has a 1-cycle hold stage** (`req_buf_q`): provides hazard-detection window before issuing to banks.

9. **Forwarding buffer is in wrapper, between access controller FSM and pseudo_dual_port**: acts as a read-miss cache for same-address reuse and a write-absorption buffer (currently only active on meta banks).

---

## 16. Parameter Reference (for model configuration)

```
Cache line width:       512 bits (64 bytes)
Refill beat width:      128 bits (4 beats per line)
Tiles:                  1 (configurable)
Cores per tile:         4
Cache controllers:      4 per tile (1:1 with cores)
Ways per controller:    4 (SetAssociativity)
Entries per way:        128 (CacheBankDepth)
Total cache per tile:   256 KB
Pseudo-dual banks:      2 per way
PartSplit (data):       4 (folded)
PartSplit (meta):       1
Spatz vector length:    512 bits
TCDM ports per core:    5 (1 Snitch + 4 Spatz)
TCDM word width:        32 bits
FIFO depths:            4 (write-through, write-resp, resp, retr, miss, evic)
Preread buffer depth:   1 entry
Forwarding buffer:      1 entry per access controller
UseHashWaySelect:       1
AllowReadDuringWrite:   0 (data) — disabled for folded banking coherence
```

---

## 17. Suggested Event Graph for GVSoC Model

```
 TCDM Request           │
     │                  │       The main pipeline latency accumulation:
     ▼                  │          t0: request arrives
 [Interco Arb] ─1cyc────►   1    t1: interco forwarded
     │                  │          t2: req_buf_q loaded
     ▼                  │          t3: preread_task_q loaded
 [Cache Req Buf] ─1cyc──►   2    t4: bank read issued, SRAM accessed
     │                  │          t5: SRAM data ready, hit/miss detected
     ▼                  │          t6: resp_fifo output
 [Preread Arb+Task]─1cyc►   3    t7: upstream response
     │                  │
     ▼                  │       Add on miss:
 [FSM REQ_PROC]   1cyc  │   4      + miss_fifo insert (1 cyc)
  │                     │          + L2 latency D
  │  ┌─────┐            │          + refill beats (4 × AXI beats)
  └─►│SRAM │  1cyc      │   5      + bank write (1 cyc)
     │Bank │            │          + MSHR retrieve (1 cyc/subarray)
     └─────┘            │
     │                  │       Backpressure: any FIFO full → STALL states
     ▼                  │          (cycle-by-cycle observable via cache_status_q)
 [Hit detect]   1cyc    │   6
     │                  │
     ▼                  │
 [Resp FIFO] ─1cyc──────►   7
     │
     ▼
 TCDM Response
```

Use this diagram as the skeleton for the event-driven model; each arrow is a cycle transition, each box consumes at least 1 cycle of latency in the best case, with additional latency under backpressure.

---

## Appendix A — Minimum Set of Events to Model Accurately

For a GVSoC performance model, these events are sufficient to capture cycle-level cache behavior:

1. **Request lifecycle**: `req_accepted`, `req_buffered`, `preread_issued`, `bank_read_issued`, `hit_detected`, `miss_detected`
2. **Miss/refill lifecycle**: `miss_pushed`, `refill_received`, `refill_applied`, `mshr_drained`
3. **Eviction lifecycle**: `evict_triggered`, `evict_pushed`, `evict_completed`
4. **Backpressure**: `stall_resp`, `stall_miss`, `stall_evic`, `stall_allpend`, `stall_mshr`, `stall_wrconflict`
5. **Buffer lifecycle**: `buf_hit_read`, `buf_hit_write`, `buf_miss_invalidate`, `buf_wb_issued`, `buf_wb_done`
6. **FIFO occupancy**: `resp_fifo_level`, `retr_fifo_level`, `miss_fifo_level`, `evic_fifo_level` (for backpressure modeling)

With these, you can reconstruct the cycle count of any workload to match RTL within a small error margin (expected: <5% for typical workloads).
