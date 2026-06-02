# InSitu Cache Model vs. Existing GVSoC Cache Models

> Companion to `prompt/insitu_cache_gvsoc_plan.md` and the user doc at
> `core/models/cache/insitu/README.md`. This document answers: what existing
> GVSoC models did we study, what code/patterns did we reuse, and what is
> genuinely new in the InSitu model?

## 1. What was already in the repo

Three generations of a generic GVSoC cache live under `core/models/cache/`:

| File | Lines | Role |
|---|---:|---|
| `cache.py` + `cache_impl.cpp` | 85 + 617 | Legacy v1 model. Exposes a `Cache` Python class whose constructor takes `nb_sets_bits`, `nb_ways_bits`, `line_size_bits`, `refill_latency`, `refill_shift`, `nb_ports`, etc. Uses `set_component('cache.cache_impl')` to bind to a named vp_model. Multi-port input (one `IoSlave` per port). |
| `cache.py` + `cache_impl_v2.cpp` | 85 + 620 | v2. Nearly identical to v1 — minor differences in refill data ownership (allocates a temporary buffer per refill so the line's own `data` is updated only on completion) and `IO_REQ_DENIED` handling on refill. Both `v1` and `v2` are selected via the `cache_v2=True` flag on the Python constructor. |
| `cache_v3.py` + `cache_v3.cpp` | 178 + 596 | Current recommended generation. Ported to the modern `Config` + `add_sources`-based build (no `set_component`, no vp_model entry — compiled via hashed CMake target). Still single-ported. Uses `config_tree.Config` and `cfg_field` for knobs. LFSR-based pseudo-random replacement. |
| `hierarchical_cache.py` | 88 | Composite that wires multiple `Cache` instances + an `Interleaver` into an L0/L1 hierarchy. Python-only. |

All three cache generations implement the same architecture:

- **Single-port set-associative cache**, one line refill in flight, read/write to line data.
- **Replacement**: LFSR pseudo-random over the ways (`stepLru()` in cache_v3.cpp:534).
- **MSHR-ish behaviour**: if a refill is already in flight, new requests `req->save()` and go onto a single global queue `refill_pending_reqs`, returning `IO_REQ_PENDING`. On refill response, `fsm_handler` drains one request per cycle via `ClockEvent`.
- **Two master ports**: `i_INPUT` (slave, io) and `o_REFILL` (master, io); plus optional flush wires.
- **Latency model**: `refill_latency` added once; no per-bank or per-set busy tracking; no FIFO capacity modeling.

Adjacent infrastructure also consulted:

| File | What was useful |
|---|---|
| `pulp/pulp/cluster/l1_interleaver_impl.cpp` | Pattern for an N-to-M hashed crossbar (`bank_id = (addr >> interleaving_bits) & mask`), `IoMaster *out[nb_slaves]`, `req_forward`. |
| `core/models/memory/memory_v2.cpp` | Pattern for mixing fixed latency (`inc_latency`) with bandwidth-driven occupancy (`set_duration`) and a cross-request `next_packet_start` cyclestamp. |
| `core/models/interco/router/router.cpp` | Per-output `BandwidthLimiter` + busy-until pattern for arbitration; pass-through via `req_forward`. |

## 2. What was reused

The InSitu model inherits a fair amount of *structure* from `cache_v3`, but
contains almost no copy-pasted code. Specifically:

### 2.1 C++ patterns reused directly

Taken from `cache_v3.cpp` / the wider GVSoC conventions:

- Class shape: `class Cache : public vp::Component { Cache(vp::ComponentConf&); void reset(bool); ... };`
- Static handler signature `static vp::IoReqStatus req(vp::Block *__this, vp::IoReq *req)` and `set_req_meth(&ClassName::req)` wiring in the constructor.
- Master port setup: `set_resp_meth(&ClassName::refill_resp_handler); new_master_port("refill", &itf);`
- Configuration read: `get_js_config()->get_child_int("field")` / `get_child_bool("field")`.
- Trace plumbing: `this->traces.new_trace("trace", &this->trace, vp::DEBUG);`
- Async refill protocol: `req->save(); pending_queue.push_back(req); return IO_REQ_PENDING;` → on response `pending_req->restore(); ... ->get_resp_port()->resp(pending_req);`.
- Module entry point: `extern "C" vp::Component *gv_new(vp::ComponentConf&) { return new X(conf); }`.

These are essentially the GVSoC component API idiom — no novelty, and reusing
them is the expected way to build a model.

### 2.2 Python patterns reused directly

From `cache_v3.py` and `hierarchical_cache.py`:

- `class X(Component)` with `super().__init__(parent, name, config=config)` and `self.add_sources([...])`.
- Declarative config via `config_tree.Config` + `cfg_field(...)`.
- Port factory methods: `i_INPUT() -> SlaveItf(self, 'input', signature='io')`, `o_REFILL(itf) -> self.itf_bind('refill', itf, signature='io')`.
- Composite pass-through: `self.bind(self, 'in_X', inner, 'in_X')` — adopted from `hierarchical_cache.py`.

### 2.3 Algorithmic patterns adapted

| From | What we adapted | Where it lives in the InSitu model |
|---|---|---|
| `l1_interleaver_impl.cpp` | Address-hash to output port; per-output `IoMaster` array; `req_forward` forwarding. | `insitu_cache_interco.cpp` |
| `memory_v2.cpp` | `set_duration(beats)` to model a multi-beat refill / eviction occupancy on the downstream port. | `insitu_cache_controller.cpp::issue_refill`, `issue_eviction` |
| `router.cpp` | Per-output `output_busy_until` cyclestamp for single-accept-per-cycle arbitration. | `insitu_cache_interco.cpp::req_handler` |
| `cache_v3.cpp::refill_response` | On an async refill response, look up the pending entry, update the line's `tag`/`ready_cycle`, then drain the queue. | `insitu_cache_controller.cpp::refill_resp_handler` |

### 2.4 Nothing copy-pasted verbatim

Every source file under `core/models/cache/insitu/` was authored fresh for
this project. No file-level copy of `cache_v3.cpp` exists. The inherited parts
are patterns (class layout, port wiring, save/restore idiom, trace channel
setup) rather than algorithms.

## 3. What is different — the InSitu-specific work

The RTL we are modeling (see `prompt/insitu_cache_architecture.md`) is a
*different microarchitecture* from the generic `cache_v3` single-port cache.
The differences below are why the existing models could not just be
reconfigured for our purpose.

### 3.1 Architectural differences vs. `cache_v3`

| Property | `cache_v3` | InSitu |
|---|---|---|
| Associativity | Set-associative | Set-associative (matches) |
| Replacement | LFSR pseudo-random only | Hash-of-`(tag, set)` *or* LRU, selected by `use_hash_way_select` to match RTL's `UseHashWaySelect` parameter |
| MSHR / pending-line state | None per se — cache_v3 tracks one global pending refill with `refill_line` / `refill_tag`. A second miss blocks on the global queue. | Explicit per-line state machine: `INVALID` / `VALID` / `READ_PEND` / `WRITE_PEND`. Multiple sets can have pending refills concurrently. Reads to a line already in `READ_PEND` merge as MSHR subarray entries (matches RTL §7.6). |
| Outstanding refills | 1 (enforced by shared `refill_line`) | Up to `miss_fifo_depth` (configurable, default 4) |
| Pending-request bookkeeping | Scratch member vars (`refill_line`, `refill_tag`, `pending_line_offset`) + one global `Queue`. | Per-set `std::deque<MshrEntry>` with `{IoReq*, arrival_cycle}` entries. Avoids the single-in-flight limitation. |
| Bank / port busy modeling | Global `nextPacketStart` (bandwidth-style). | Per-set `set_busy_until_[num_sets]` cyclestamp. Captures same-set back-to-back serialization cleanly. |
| Eviction path | Silent overwrite. No write-back path exists. | Dedicated `o_EVICT` master + `evic_fifo` + optional `folded_evict_penalty_cycles` to model folded-SRAM multi-part reads (RTL §7.7). |
| Write-through path | None. cache_v3 always performs write-to-line with dirty bit; nothing goes to L2 until eviction. | Dedicated `o_WRITE_THROUGH` master to a coalescer (see 3.2). Matches RTL's hybrid write-back/write-through-coalesced semantics (§10). |
| FIFO capacity | Unbounded. | Four bounded FIFOs (`resp` / `retr` / `miss` / `evic`) with `IO_REQ_DENIED` back-pressure when full. Matches RTL §12.4. |
| Hit-path latency | `refill_latency` on misses; hits served immediately plus the delta to refill completion. | `hit_latency_cycles` (pipeline depth from RTL §12.1) + per-set busy + line-ready-cycle settling. |
| Scratch data buffers | Single `refill_req` whose `data` points into the line's own byte array (read-only refill). | Separate `refill_data_buf_` / `evict_data_buf_` / `wt_data_buf_`, pre-allocated 64 B. Needed because both reads AND writes now traverse the downstream port and the memory model memcpys against `req->get_data()`. |

### 3.2 New components with no equivalent in `core/models/cache/`

Three new components were authored from scratch because the RTL has no
analogue in the existing model set:

1. **`InsituCacheInterco`** (`insitu_cache_interco.{cpp,py}`) — hashed N-to-M
   crossbar between the N upstream TCDM request ports and the M cache
   controllers. Similar idea to `l1_interleaver_impl.cpp`, but the latter is
   a crossbar from cores to memory banks (not cache controllers), and
   arbitrates bank-granularity accesses (different granularity). The InSitu
   interco also models per-output single-accept-per-cycle serialization,
   which `l1_interleaver` does not.

2. **`InsituCacheCoalescer`** (`insitu_cache_coalescer.{cpp,py}`) — 3-state
   write-through merger (`IDLE` / `WRITE_COAL` / `FLUSH`) with a
   configurable watchdog and a read-snoop flush port. Implements RTL §10.
   There is no generic write-coalescer anywhere in the existing GVSoC model
   library.

3. **`InsituCacheTile`** (`insitu_cache_tile.py`) — composite wrapping N
   controllers + N coalescers + 1 interco + an `l2` fan-in composite master.
   Structurally analogous to `hierarchical_cache.py`, but:

   - `hierarchical_cache` composes caches in a *hierarchy* (L0 → L1 → refill)
     with an `Interleaver` between L0s and L1s.
   - `InsituCacheTile` composes peers in a *tile* (interco → N parallel
     controllers → coalescers all fanning into a single L2 port). No L0/L1
     hierarchy here.

### 3.3 New configuration surface

`core/models/cache/insitu/insitu_cache_config.py` defines four
`config_tree.Config` subclasses plus a top-level plain dataclass:

- `InsituCacheControllerConfig` (14 fields) — cache line bytes, ways, sets,
  hash-way toggle, five timing knobs, five FIFO depths.
- `InsituCacheCoalescerConfig` (2 fields).
- `InsituCacheIntercoConfig` (4 fields) — includes the RTL's `dynamic_offset`.
- `InsituCacheTileConfig` — plain dataclass that bundles the three +
  topology (num_cores, tcdm_ports_per_core, num_controllers).

A `make_cachepool_512_config()` helper returns the canonical RTL config as
published in `prompt/insitu_cache_architecture.md §1.3`.

`cache_v3` by comparison exposes only 7 fields (`size`, `line_size`, `ways`,
`enabled`, `refill_shift`, `refill_offset`, `refill_latency`). None of the
RTL-specific knobs (FIFO depths, folded-evict penalty, hash-way toggle,
MSHR drain rate) are reachable from cache_v3.

### 3.4 New integration glue

Two files in the `pulp/` (gvsoc-pulp) submodule were modified to integrate
the model into the Spatz cluster:

- `pulp/pulp/snitch/snitch_cluster/snitch_cluster.py` — `ClusterArch` gained
  `use_insitu_cache` / `insitu_cache_cfg` arguments. When enabled, an
  `InsituCacheTile` is placed between cores' `o_DATA` / `o_VLSU(lane)` and
  the cluster's existing TCDM/SPM.
- `pulp/pulp/chips/snitch/snitch.py` — `SnitchArchProperties` exposes
  `use_insitu_cache` as a target user property (`--target-property
  use_insitu_cache=True`). `SnitchArch.Chip.Soc` threads it through to every
  `ClusterArch`.

Plus three smaller auxiliary changes surfaced during validation (also
documented in `prompt/insitu_cache_validation_report.md` §4):

- `pulp/pulp/snitch/snitch_cluster/spatz/cluster_registers.cpp` — added
  watchpoint on the `CLUSTER_EOC_EXIT` MMIO register (offset 0x68) that the
  RTL testbench uses for `$finish`. Previously the GVSoC regmap silently
  dropped writes to this offset, so binaries that called `set_eoc()` would
  spin forever.
- `core/models/cpu/iss/src/htif.cpp::handle_syscall` — added stderr cycle
  report on HTIF exit so RTL↔GVSoC cycle-count comparison is tabulatable.
- `pulp/insitu_cache_tb.py` — a minimal standalone testbench target
  (single RV32 host → `InsituCacheTile` → memory) for running cache
  microbenchmarks without the full Spatz cluster.

## 4. Size comparison

Lines of code added for the InSitu model:

| File | Lines |
|---|---:|
| `insitu_cache_controller.cpp` | ~510 |
| `insitu_cache_controller.py` | ~100 |
| `insitu_cache_interco.cpp` | ~115 |
| `insitu_cache_interco.py` | ~60 |
| `insitu_cache_coalescer.cpp` | ~215 |
| `insitu_cache_coalescer.py` | ~55 |
| `insitu_cache_tile.py` | ~125 |
| `insitu_cache_config.py` | ~160 |
| `README.md` | ~720 |
| **Total (code + docs)** | **~2 060** |

For reference, the entire existing `cache_v3.{cpp,py}` is 178 + 596 = 774
lines, and `hierarchical_cache.py` is 88 lines. The InSitu model is roughly
twice the C++ / Python line count because it models roughly twice as many
concurrent concepts (per-line state machine, four FIFO types with
capacity, per-set bank busy, separate evict and WT paths, coalescer FSM,
hashed N-to-M interco) and ships user-facing documentation in the same
tree.

## 5. Why not generalize `cache_v3` instead?

Briefly considered and rejected. Reasons:

1. `cache_v3` is a *single-port* cache. The CachePool core complex issues 5
   TCDM ports per core × 4 cores = 20 upstream; retrofitting multi-port
   into cache_v3 would touch its `IoSlave` array, the req/resp routing,
   and the LFSR replacement state — a non-trivial rewrite, with regressions
   risk for every existing GVSoC target that already uses cache_v3.

2. `cache_v3` has no eviction path, no write-through path, no coalescer,
   no FIFO capacity, and no per-set state. Adding these would approximately
   double its size and change its timing semantics for other users.

3. `cache_v3` is loaded by `Hierarchical_cache`, `spatz` icache, and other
   targets. Any behavioural change ripples there.

4. Keeping the new model in a sibling subdirectory (`core/models/cache/
   insitu/`) isolates our RTL-specific modeling decisions from the
   generic-cache lineage. `cache_v3` users see no change; the InSitu model
   can iterate freely.

## 6. Summary

**Reused** (from `cache_v3`, `hierarchical_cache`, `l1_interleaver`,
`memory_v2`, `router.cpp`): the GVSoC component API idioms, the async
refill `save/restore` pattern, the address-hash crossbar pattern, the
`set_duration`-based bandwidth modeling pattern, and the composite
pass-through port pattern. No full function or file was copied — only
patterns.

**New** (InSitu-specific): per-line `READ_PEND` / `WRITE_PEND` state,
per-set MSHR queues, per-set bank-busy tracking, hash-or-LRU victim
selection, explicit eviction FIFO + folded-eviction penalty, write-through
coalescer with watchdog FSM, N-to-M hashed interco with per-output RR
arbitration, tile composite with L2 fan-in, FIFO capacity back-pressure,
separate scratch data buffers, and all the config classes / integration
glue / standalone testbench / user docs.

Net effect: the InSitu model is a *sibling* of `cache_v3`, not an
extension of it. It follows the same GVSoC conventions (so GVSoC users
can read it), but models a distinct microarchitecture (so CachePool
workloads get cycle-approximate numbers on GVSoC).
