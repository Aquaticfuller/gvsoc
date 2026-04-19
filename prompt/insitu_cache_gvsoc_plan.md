# InSitu Cache — GVSoC Performance Model Implementation Plan

> Companion to `insitu_cache_architecture.md`. That document describes the RTL we are modeling;
> this document describes **how** we will build a GVSoC performance model of it.
>
> Target branch: `main` of this GVSoC checkout (currently at `d107dd0`).
> RTL reference: `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData`, branch `dev/cache-refactoring-multi-tile`
> (cache subrepo on `zexin/cachepool_dev_refactoring`).

---

## 0. Executive Summary

We are adding a new L1 data-cache performance model to GVSoC so we can run CachePool workloads
against a Snitch+Spatz core complex in the existing GVSoC simulator. The end state is a
cycle-approximate (not cycle-exact) model that reproduces the RTL's dominant latency and
throughput behavior: hit latency, miss service time, write-coalescer batching, bank/way
conflicts, FIFO backpressure, MSHR stalling, and the forwarding-buffer absorption effect. The
expected accuracy is **<5% cycle error on typical streaming + random-access workloads**, which
matches the target margin called out in `insitu_cache_architecture.md §App. A`.

The work is partitioned into **seven phases** that build bottom-up from a single cache controller
to a fully integrated CachePool target. Each phase produces a runnable, testable artifact, so the
project stays continuously validatable rather than requiring a big-bang bring-up at the end.

---

## 1. Modeling Philosophy

### 1.1 What we WILL model

| Effect | Why it matters | How we model it |
|---|---|---|
| Request pipeline depth | ~7-cycle hit latency dominates stream perf | Fixed per-stage latency with explicit `inc_latency()` at stage crossings |
| Hit/miss classification | First-order miss rate determines memory BW | Tag-array lookup with hash-way or LRU selection |
| MSHR coalescing | Determines concurrent miss count | Per-line pending-read list, bounded by `RetrFifoDepth` |
| Write-coalescer window | Reduces L2 write traffic for streaming stores | 4-cycle watchdog state machine per controller |
| FIFO backpressure | Creates stall cycles observable in traces | Tracked occupancy; requests deferred when full |
| Bank/way conflicts on concurrent accesses from multiple TCDM ports | Creates arbitration stalls when cores collide | Arbiter + per-controller busy-until cyclestamp |
| Eviction & writeback | Adds latency on dirty replacement | Explicit evict FIFO + AXI write |
| Refill (128b beats, 4 per line) | L2 service time dominates miss cost | Per-beat latency from downstream |

### 1.2 What we will NOT model (unless a phase-7 refinement is requested)

| Effect | Why we skip it |
|---|---|
| Folded SRAM column skewing (`PartSplit=4`) | Has no observable latency impact for hits and only +2 cycles for folded evictions — modeled as a fixed eviction penalty |
| Pseudo-dual-port WR_CONFLICT per word | Captured aggregate in "bank busy" accounting |
| Per-access-controller FSM (`ACCESS_THROUGH` / `ACCESS_STALL`) | Aggregated into controller-level ready signal |
| Forwarding-buffer internal 3-way hit classification (`wr_buf_hit` / `wr_concurrent_hit` / `wr_full_hit`) | Modeled as a single "buffer hit probability" + writeback cost |
| LRU RF vs meta SRAM write distinction | No perf visibility at the port level |
| Hash-way exact polynomial | Any deterministic hash on `{tag, set}` is sufficient; no workload depends on the exact bits |
| Dynamic address remapping at runtime (`l1d_xbar_config`) | Model as config-time property (if a workload changes `dynamic_offset` mid-run we revisit) |

Rationale: Every behavior in the "skip" list is either (a) an internal optimization that reduces
SRAM energy without changing observable port-level timing, or (b) a structural choice whose
aggregate effect is already captured by a coarser knob. We log these as "fidelity knobs" that can
be promoted to first-class modeled effects if validation reveals a gap.

### 1.3 Guiding principles

1. **Event-driven, not pipeline-simulation.** We don't instantiate every pipeline stage register
   as a C++ variable. We use `IoReq` latency annotation + a small set of busy-until cyclestamps
   per shared resource (bank, MSHR, coalescer, FIFO). This matches the style of `cache_v3.cpp`
   and `memory_v2.cpp` already in the repo.
2. **Request objects carry state.** Use `IoReq::save()/restore()` and the scratch args area
   (`IoReq::get_args()`) to attach per-request bookkeeping (hit-vs-miss tag, pending MSHR slot,
   arrival cycle) rather than maintaining shadow tables.
3. **Config from the RTL `.hjson`.** Every parameter in the canonical `cachepool_512` config
   (see `insitu_cache_architecture.md §1.3` and `§16`) must be a `cfg_field` on our
   `InsituCacheConfig`. Nothing is hardcoded.
4. **Counters match RTL stat signals.** The RTL emits `stat_rd_hit`, `stat_wr_merge`, etc. at
   end-of-sim. We mirror these via `vp::Trace` signals and a final-report printer, so running
   the same workload on RTL and GVSoC produces directly comparable numbers.

---

## 2. Surface Area: Where this Model Plugs In

### 2.1 Current data path (without cache) in the spatz target

From `pulp/pulp/snitch/snitch_cluster/snitch_cluster.py:272-283`:

```
cores[core_id] ──o_DATA──► cores_ico[core_id] (per-core router, bw=8B)
                                  │
                                  └─o_MAP──► tcdm.i_INPUT(port)   [scalar]
cores[core_id] ──o_VLSU(0..3)─────────────► tcdm.i_INPUT(port++)  [4 vector lanes]

                           tcdm (SnitchClusterTcdm)
                           ├── L1_interleaver (nb_masters=nb_core*(1+4), nb_slaves=32)
                           └── 32 Memory banks (bank_width=8B, 1KB each)
```

For the canonical `cachepool_512` config (1 tile, 4 cores, 4-way, 256KB L1D, 512b line) we have
**5 TCDM ports × 4 cores = 20 request streams** per tile entering our cache layer.

### 2.2 Target data path (with insitu cache)

```
cores[core_id] ──o_DATA──► cores_ico[core_id] ──────────┐
cores[core_id] ──o_VLSU(0..3)─────────────────────────┐ │
                                                      ▼ ▼
                          ┌────────────────────────────────────┐
                          │  InsituCacheTile                   │  (NEW component)
                          │  ┌──────────────────────────────┐  │
                          │  │ TcdmCacheInterco (4:4)       │  │  Port↔Ctrl address hash
                          │  │  (hash on bits[3:2] → ctrl)  │  │
                          │  └──┬────┬────┬────┬────────────┘  │
                          │     │    │    │    │               │
                          │  ┌──▼─┐┌─▼──┐┌▼───┐┌▼──┐           │
                          │  │C0  ││C1  ││C2  ││C3 │  cache    │
                          │  │FSM ││FSM ││FSM ││FSM│  ctrls    │
                          │  └──┬─┘└─┬──┘└─┬──┘└─┬─┘           │
                          │     │    │    │    │               │
                          │  ┌──▼────▼────▼────▼─────────────┐ │
                          │  │ Write-through merger + miss/  │ │
                          │  │ evict FIFOs, AXI adapter       │ │
                          │  └──┬────────────────────────────┘ │
                          └─────┼──────────────────────────────┘
                                │ (refill + miss + evict)
                                ▼
                          wide_axi ──► memory (L2/DRAM)
```

Two integration stances exist; we pick the second:

- **(A) Replace the TCDM.** Drop the `SnitchClusterTcdm` instance and make `InsituCacheTile` the
  sole memory target on the cluster's local address range.
- **(B) Put cache upstream of TCDM.** Keep the existing banked TCDM as our "L2-like" refill
  target; cache sits between cores and TCDM.

Stance (B) matches the RTL (L1D refills from AXI which in turn reads SPM/L2/DRAM) and lets us
reuse the existing bank model as a stand-in for L2. Stance (A) would require rewriting cluster
address decoding. **Plan: stance (B).** The cache's `o_REFILL`/`o_EVICT`/`o_WRITE_THROUGH`
master ports go into `wide_axi` (or into a dedicated L2 instance) exactly as the RTL does.

### 2.3 Files we will NOT modify initially

- `core/models/cache/cache_v3.{cpp,py}` — existing, unrelated (icache and PULP data caches). We
  create new files alongside, not a generalization.
- `engine/` — no engine-level changes needed; the `IoReq` + slave/master port API is sufficient.
- `pulp/pulp/snitch/snitch_cluster/snitch_cluster.py` — we **will** edit this in phase 5, but
  behind a config flag so the existing `spatz` / `snitch` / `snitch:core_type=fast` targets keep
  working unchanged.

---

## 3. File Layout

All new files. We put the cache itself under `core/models/cache/` (where `cache_v3` lives) since
it is a reusable model, and the tile wrapper under `pulp/pulp/cache/` (which doesn't yet exist
— we'll create it) because it uses PULP-specific configuration.

```
core/models/cache/
├── insitu/                                 ← NEW subdir (keeps cache_v3 untouched)
│   ├── insitu_cache_controller.cpp         ← single-controller FSM + SRAM model
│   ├── insitu_cache_controller.py
│   ├── insitu_cache_coalescer.cpp          ← write-through merger (reusable alone)
│   ├── insitu_cache_coalescer.py
│   ├── insitu_cache_interco.cpp            ← TCDM↔controller address hash + arbiter
│   ├── insitu_cache_interco.py
│   ├── insitu_cache_tile.py                ← composes controllers + interco + coalescer
│   ├── insitu_cache_config.py              ← shared Config classes
│   └── CMakeLists.txt                      ← adds vp_model entries
└── CMakeLists.txt                           ← add_subdirectory(insitu)

pulp/pulp/snitch/snitch_cluster/
└── snitch_cluster.py                       ← PHASE 5: add `use_insitu_cache` arch flag
                                              and conditional wiring

prompt/
├── insitu_cache_architecture.md            ← existing (RTL spec)
└── insitu_cache_gvsoc_plan.md              ← this file
```

We deliberately avoid putting the controller under `pulp/` because it is a generic set-associative
write-back / write-through-coalesced cache with a parameterized upstream/downstream interface;
other targets could reuse it. The tile + the integration glue live under `pulp/` because they
are specific to the CachePool-flavored Snitch+Spatz cluster.

---

## 4. Detailed Phase-by-Phase Plan

### Phase 0 — Scaffold & decisions (day 0-1)

**Goal:** Folder structure, empty components, "hello world" wiring so phase 1 has somewhere to
live.

1. Create `core/models/cache/insitu/` with a placeholder `CMakeLists.txt` (`vp_model(NAME
   cache.insitu.insitu_cache_controller ...)` stubs pointing at empty `.cpp` files).
2. Add `add_subdirectory(insitu)` to `core/models/cache/CMakeLists.txt`.
3. Create `insitu_cache_config.py` with a draft `InsituCacheConfig` dataclass listing every knob
   from `insitu_cache_architecture.md §16`:
   ```python
   class InsituCacheConfig(Config):
       # Geometry
       cache_line_bits: int  = cfg_field(default=512)
       refill_beat_bits: int = cfg_field(default=128)
       num_ways: int         = cfg_field(default=4)
       num_sets: int         = cfg_field(default=128)      # CacheBankDepth
       num_controllers: int  = cfg_field(default=4)        # per tile
       # Port sizing
       tcdm_word_bits: int   = cfg_field(default=32)
       tcdm_ports_per_core: int = cfg_field(default=5)     # 1 scalar + 4 spatz lanes
       # Interleaving
       dynamic_offset: int   = cfg_field(default=2)
       use_hash_way_select: bool = cfg_field(default=True)
       # Pipeline (from §12)
       hit_latency_cycles: int   = cfg_field(default=4)    # cache-side cycles 2..5 in §12.1
       interco_latency_cycles: int = cfg_field(default=1)
       refill_bank_write_cycles: int = cfg_field(default=2)
       folded_evict_penalty_cycles: int = cfg_field(default=3)
       # FIFO depths (§3.3)
       resp_fifo_depth: int   = cfg_field(default=4)
       retr_fifo_depth: int   = cfg_field(default=16)
       miss_fifo_depth: int   = cfg_field(default=4)
       evic_fifo_depth: int   = cfg_field(default=4)
       wt_fifo_depth: int     = cfg_field(default=4)
       # Coalescer
       coalescer_watchdog_cycles: int = cfg_field(default=4)
       # Forwarding buffer (meta-only in RTL; off by default in model)
       enable_meta_fwd_buffer: bool = cfg_field(default=False)
   ```
4. Decide: build the model **with** or **without** the `has_tree_config()` config-tree path.
   **Decision:** start with `get_js_config()` JSON only (like `cache_v3.cpp`); the modern
   config-tree path is optional and can be added in phase 7 if needed.

**Exit criteria:** `make all TARGETS=spatz` still builds; our new subdir compiles (empty) without
errors.

---

### Phase 1 — Single cache controller (days 2-5)

**Goal:** A standalone `InsituCacheController` component that can be wired in place of a memory
and responds correctly to read/write `IoReq` traffic with realistic hit/miss latency.

**Component surface:**
```
InsituCacheController
  slave:  i_INPUT()           — 32b TCDM request (upstream from interco or core)
  master: o_REFILL(itf)       — 512b line read from L2 on miss
  master: o_EVICT(itf)        — 512b dirty line writeback
  master: o_WRITE_THROUGH(itf) — coalesced writes out (wired directly in phase 1; phase 3
                                refactors this through the coalescer)
  slave:  i_FLUSH()           — optional, like cache_v3
  master: o_FLUSH_ACK(itf)
```

**State:**
- Tag array: `tag[num_sets][num_ways]` with `valid`/`dirty` bits. Optionally `pending_state`
  ∈ {`VALID`, `READ_PEND`, `WRITE_PEND`} to model MSHR-like hit-on-pending.
- `lru[num_sets]` for LRU victim selection (unused when `use_hash_way_select=True`).
- MSHR subarray list per pending set (vector of saved `IoReq*` waiting on a refill).
- Busy-until timestamps: `bank_busy_until[num_ways]`, `ctrl_busy_until`, `refill_inflight`.
- FIFO level counters: `miss_fifo_level`, `evic_fifo_level`, `resp_fifo_level`,
  `retr_fifo_level` (treated as occupancy numbers; full → backpressure).

**Request lifecycle (read hit):**
1. `req_handler(req)` computes set/tag from `req->get_addr()`.
2. Lookup tag array. If hit:
   - `req->inc_latency(hit_latency_cycles)` — represents pipeline stages 2→5 from `§12.1`.
   - If the line is READ_PEND: don't serve now, enqueue via `req->save(); mshr[set].push_back
     (req); return IO_REQ_PENDING`. On refill completion we pop and reply.
   - Otherwise update LRU RF (if `!use_hash_way_select`), update `bank_busy_until[way]`, return
     `IO_REQ_OK`.
3. If miss:
   - Pick victim (hash or LRU). If victim dirty → push to evict FIFO (`evic_fifo_level++`; bump
     `inc_latency(folded_evict_penalty_cycles)` if folded eviction).
   - Push miss to `miss_fifo`; `req->save(); mshr[set].push_back(req); pending_state[set]=READ_PEND;
     return IO_REQ_PENDING`.
   - Issue `refill_itf.req(refill_req)` with address = line base; when it completes, walk
     the MSHR list and respond to each saved `req`.

**Write lifecycle:**
- **Write hit on VALID:** set dirty bit; `inc_latency(hit_latency_cycles)`; return `IO_REQ_OK`
  (fire-and-forget from the core's POV — matches RTL `§12.3`). Internally increment
  `wt_fifo_level` via the (phase-3) coalescer. In phase 1 we bypass the coalescer and just
  forward via `o_WRITE_THROUGH`.
- **Write miss:** mark WRITE_PEND, push miss, stage the write data in a pending-write slot; on
  refill completion merge dirty bytes (mask-aware) before responding.

**Backpressure implementation:**
- Before accepting a new request: check that all FIFOs we *might* push into have `level < depth`.
- If any is full, return `IO_REQ_DENIED` (causes upstream interco to retry) **or** enqueue into
  an input queue and return PENDING. We prefer the PENDING path for accuracy — it mirrors the
  RTL's `upstream_req_ready_o = 0` behavior. Concretely: maintain one `vp::Queue input_q` per
  input port with a bounded capacity; when a FIFO drains, pop and re-issue.

**What to measure in unit tests:**
- Pure-hit stream to the same set: latency per request = `hit_latency_cycles`, throughput = 1
  req/cycle.
- Alternating hit/miss: miss latency = `hit_latency + refill_latency + 4·beat_latency + 2`
  (within ±1 cycle of `§12.2`).
- Write-then-read-same-line: no false miss (WAR hazard respected). This validates the pending-
  state logic.
- Evict-then-refill: dirty line is evicted before the refill reply commits.

**Exit criteria:**
1. New unit test under `core/tests/insitu_cache/` sends a scripted request sequence into a
   single controller (with a simple memory attached on the refill port) and asserts cycle counts
   within ±1 of hand-calculated values.
2. Hit-rate counter matches the scripted pattern exactly.
3. The controller's `vp::Trace` channel prints a readable per-request log compatible with
   `gvsoc --trace=cache.insitu/.*`.

---

### Phase 2 — Cache interconnect (days 6-7)

**Goal:** `InsituCacheInterco` component that routes N upstream TCDM ports to M downstream cache
controllers by the address-hash scheme from `insitu_cache_architecture.md §2.3`.

**Pattern to follow:** `pulp/pulp/cluster/l1_interleaver_impl.cpp`. That file already shows
exactly how to do bank-id-from-address + per-output `IoMaster` forwarding. Our interco differs
only in:
- Arbitration when multiple inputs target the same controller in the same cycle (RR like the
  RTL; use `stream_arbiter` logic or a simple round-robin counter per output).
- Adding 1 cycle of latency (`§5` says 1 cycle forward + 1 cycle response = 2 cycles round-trip).

**State:** per-output `last_grant` counter for RR; per-output `busy_until_cycle` for 1-per-cycle
arbitration throttling. No queuing in v1 (synchronous); phase 7 can add async arbitration if
validation shows we need it.

**Exit criteria:** Unit test with 4 inputs all hashing to the same output (worst case); verify
serialization adds the correct number of stall cycles.

---

### Phase 3 — Coalescer (write-through merger) (days 8-9)

**Goal:** Standalone `InsituCacheCoalescer` component that sits on the cache controller's
write-through output and implements the FSM from `insitu_cache_architecture.md §10`.

**State:**
- One coalescing line buffer (`coal_line_data[64B]`, `coal_mask[64b]`, `coal_tag`).
- `state ∈ {IDLE, WRITE_COAL, FLUSH}`.
- `watchdog_cnt`.

**Behavior per incoming write:**
- If `state==IDLE`: enter `WRITE_COAL`; stash tag/data/mask; start watchdog.
- If `state==WRITE_COAL` and tag matches: merge bytes (new bytes win), OR masks, reset watchdog.
- If `state==WRITE_COAL` and tag differs: emit current line via `o_OUT`, then stash new.
- If `watchdog_cnt==0`: emit via `o_OUT`, go `IDLE`.
- If an external `i_READ_SNOOP` comes in with a matching tag: flush immediately.

Implementation note: wire the coalescer between cache controller's `o_WRITE_THROUGH` and the
downstream AXI, and expose a `i_READ_SNOOP` slave port that the cache connects to so reads can
force a flush (matches `§10` "Read conflict" trigger).

**Exit criteria:** 4 consecutive byte-writes to the same line → 1 AXI burst out (8× reduction);
5 writes across watchdog boundary → 2 bursts.

---

### Phase 4 — Tile wrapper (days 10-12)

**Goal:** `InsituCacheTile` Python component that composes {interco, N controllers, N
coalescers, shared miss/evict router} and exposes a clean interface.

**Python component surface:**
```python
class InsituCacheTile(gvsoc.systree.Component):
    def __init__(self, parent, name, config: InsituCacheConfig, nb_tcdm_ports: int): ...

    def i_INPUT(self, port: int) -> SlaveItf: ...           # TCDM port
    def i_DMA_INPUT(self) -> SlaveItf: ...                  # bypass path (optional)
    def o_L2(self, itf: SlaveItf): ...                      # miss + evict + WT combined
    def i_FLUSH(self) -> SlaveItf: ...
    def o_FLUSH_ACK(self, itf: SlaveItf): ...
```

Internally:
- Instantiate `N = config.num_controllers` controllers.
- Instantiate one `InsituCacheInterco(nb_masters=nb_tcdm_ports, nb_slaves=N,
  interleaving_bits=config.dynamic_offset)`.
- Instantiate one `InsituCacheCoalescer` per controller on its WT output.
- Instantiate a small `router.Router` that fans-in the four controllers' miss/evict/WT streams
  onto the single `o_L2` master (it's AXI-addressable by `line_addr`, so a router is the natural
  fit).
- Expose per-controller stat counters via `vp::Trace` signals namespaced
  `insitu_cache/tile/ctrl<i>/stat_*`.

**Exit criteria:**
- Stand up a minimal standalone target (just a single `IoMaster` stub generating random TCDM
  traffic) against one `InsituCacheTile` connected to a `memory.Memory` as L2, and verify:
  1. Aggregate hit rate converges to the analytical expectation for a random-access workload.
  2. With a fully streaming pattern, WT coalescing reduces L2 write traffic by ~8× (64B/8B).
  3. Per-tile cycle count for a fixed workload matches a hand calc within ±10% (we tighten to
     ±5% in phase 6 once integrated).

---

### Phase 5 — Integration into Snitch+Spatz cluster (days 13-15)

**Goal:** Replace/augment `SnitchClusterTcdm` so the `spatz` target can run a workload with the
insitu cache in the path.

**Strategy:** Add a new `ClusterArch` flag `use_insitu_cache: bool = False`, and a new
`InsituCachedClusterTcdm` class that wraps `InsituCacheTile` + the existing `SnitchClusterTcdm`
(the latter acting as L2/SPM). `SnitchCluster.__init__` dispatches on the flag. No change to
default behavior when the flag is off.

**Concrete wiring** (pseudo-diff against `snitch_cluster.py:272-283`):

```python
if arch.use_insitu_cache:
    spm = SnitchClusterTcdm(self, 'spm', arch.tcdm)   # reuse as L2
    cache_tile = InsituCacheTile(self, 'insitu_cache', config=arch.cache_cfg,
                                 nb_tcdm_ports=arch.tcdm.nb_masters)
    # Cache sees cores' 5 TCDM ports per core; L2 sees one fan-in from cache
    tcdm_port = 0
    for core_id in range(arch.nb_core):
        cores[core_id].o_DATA(cores_ico[core_id].i_INPUT())
        cores_ico[core_id].o_MAP(cache_tile.i_INPUT(tcdm_port), base=arch.tcdm.area.base,
                                 size=arch.tcdm.area.size, rm_base=True)
        tcdm_port += 1
        if arch.use_spatz:
            for lane in range(arch.spatz_nb_lanes):
                cores[core_id].o_VLSU(lane, cache_tile.i_INPUT(tcdm_port))
                tcdm_port += 1
        cores_ico[core_id].o_MAP(narrow_axi.i_INPUT())
        cores[core_id].o_FETCH(icache.i_INPUT(core_id))
    cache_tile.o_L2(spm.i_INPUT(0))                   # or a dedicated low-port bank fan-in
    # DMA still bypasses cache (matches RTL — DMA goes to TCDM directly)
    wide_axi.o_MAP(spm.i_DMA_INPUT(), base=arch.tcdm.area.base, size=arch.tcdm.area.size,
                   rm_base=True)
    idma.o_TCDM(spm.i_DMA_INPUT())
else:
    # existing code path, untouched
    tcdm = SnitchClusterTcdm(self, 'tcdm', arch.tcdm)
    ...
```

**⚠ Pitfall: L2 port contention.** `SnitchClusterTcdm` exposes `i_INPUT(port)` for up to
`nb_masters` distinct ports sized for the original core×lane count. If the cache fan-in goes to
a single `i_INPUT(0)`, we'll artificially serialize miss + eviction + WT streams. Mitigation:
give the cache tile four distinct output fan-outs (one per controller) into four different
`i_INPUT(port)` slots, and reduce `arch.tcdm.nb_masters` accordingly since cores no longer talk
to it directly. Or: add a dedicated multi-port master on the SPM side. Decide in phase 5
during first integration.

**⚠ Pitfall: address alignment.** TCDM inputs currently take 8B-granular requests (`bank_width =
8`). The cache serves 4B (`NarrowDataWidth = 32b`) requests from cores, and emits 64B line
fills. We need to verify the request splitting / reassembly in the cache model matches what
the memory bank expects. Likely the simplest fix is for the cache to issue line fills as a
single `IoReq` with `set_size(64)` and let the downstream router/interleaver split it; memory
banks accept any size as long as it's within bank width (the RTL writes 128b per beat × 4 beats,
so we can either model 4 sequential beats or 1 wide request — go with 1 wide request and
`set_duration(4)` to capture the 4-beat occupancy).

**Exit criteria:**
1. `make all TARGETS=spatz` builds. Existing `gvsoc --target=spatz --binary <any
   spatz-binary> run` still works (insitu disabled by default).
2. A new gated target `spatz:use_insitu_cache=True` (or a new `spatz_insitu` target file) boots
   the Spatz hello-world binary to completion.
3. No regressions on the existing spatz testset.

---

### Phase 6 — Validation against RTL (days 16-20)

**Goal:** Cross-check GVSoC cycle counts and counter values against RTL for a curated workload
set.

**Workloads:**
| Workload | Purpose | Source |
|---|---|---|
| `cache-line-rw-smoke` | Tag-lookup + LRU correctness | `software/tests/cache-line-rw-smoke/` |
| Random reads (fixed miss rate) | Calibrate refill latency knob | Synthetic |
| Streaming writes (one pass) | Calibrate coalescer + WT bandwidth | Synthetic |
| GEMM kernel (blocked) | Integrated workload with realistic mix | `software/tests/gemm/` |
| Vector AXPY | Spatz-heavy traffic, 4-lane parallelism | Spatz test suite |

**Comparison methodology:**
1. For each workload, run RTL (Questa/Verilator) and record:
   - End-to-end cycle count (from kernel start to end marker).
   - RTL `$display` stat dump: `stat_rd_hit`, `stat_rd_miss`, `stat_wr_merge`, `stat_wb`,
     per-FIFO peak levels if instrumented.
2. Run the same binary on GVSoC with the insitu cache enabled.
3. Compare line-by-line. Target: **cycle-count error <5%, hit-rate error <1%** on the
   curated workloads.

**When off-target:**
- Hit rate off: cache geometry mismatch, tag/index extraction bug, hash polynomial.
- Cycle count high: FIFO depths too small, latency knobs too large, missing parallelism.
- Cycle count low: missing backpressure source, hit latency too small, not modeling bank
  serialization.

**Calibration knobs, in priority order:**
1. `hit_latency_cycles`, `interco_latency_cycles`, `refill_bank_write_cycles`
2. `retr_fifo_depth`, `miss_fifo_depth`
3. `coalescer_watchdog_cycles`
4. `folded_evict_penalty_cycles`

**Exit criteria:** For each workload, cycle-count error ≤5% and per-counter error ≤1%. Any
workload failing this bar triggers a fidelity-knob promotion review (phase 7).

---

### Phase 7 — Optional fidelity refinements (as needed)

Only if phase 6 identifies a specific miss. Candidates, in decreasing likelihood:
1. **Per-way bank-busy tracking** (currently aggregate `ctrl_busy_until`) — if workloads with
   per-way contention show >5% cycle error.
2. **Forwarding buffer modeling** — if meta-bank-heavy workloads (high LRU churn) show the
   cache keeping up where the model stalls.
3. **Async preread arbiter** — if refill vs. request priority ordering changes outcomes (RTL
   gives refill priority; our phase-1 model matches, but in corner cases the order could
   differ).
4. **Hash polynomial matched to RTL** — if a workload has set-index aliasing that the model
   doesn't reproduce.
5. **PartSplit folded-SRAM modeling** — unlikely to be needed, but if eviction-heavy workloads
   show 3-4% error this is the cause.

Each is a bounded add-on: none requires restructuring phase 1-5 code.

---

## 5. Configuration & Parameterization

Single source of truth: `InsituCacheConfig` (phase 0). The `ClusterArch` for spatz gets a
companion `cache_cfg: InsituCacheConfig` field. Defaults exactly match
`insitu_cache_architecture.md §16`:

```python
cache_cfg = InsituCacheConfig(
    cache_line_bits=512, refill_beat_bits=128,
    num_ways=4, num_sets=128, num_controllers=4,
    tcdm_word_bits=32, tcdm_ports_per_core=5,
    dynamic_offset=2, use_hash_way_select=True,
    hit_latency_cycles=4, interco_latency_cycles=1,
    refill_bank_write_cycles=2, folded_evict_penalty_cycles=3,
    resp_fifo_depth=4, retr_fifo_depth=16, miss_fifo_depth=4,
    evic_fifo_depth=4, wt_fifo_depth=4,
    coalescer_watchdog_cycles=4,
    enable_meta_fwd_buffer=False,
)
```

Surface these in two ways:
1. CLI flag per knob (via `target.declare_user_property(...)` in the spatz target file), so
   sweeps can be scripted without editing Python.
2. A named preset dictionary (`cachepool_512`, etc.) keyed from a CLI arg.

---

## 6. Testing Strategy

Three tiers, all driven by `gvtest` (native mechanism in this repo — see `gvtest/SPECIFICATIONS.md`):

1. **Unit tests** (`core/tests/insitu_cache/testset.cfg`): synthetic `IoReq` generators
   exercising one controller / the interco / the coalescer in isolation. Assertion: cycle counts
   match hand-calculated reference within ±1.
2. **Component tests** (`core/tests/insitu_cache/tile_testset.cfg`): full tile wrapper with a
   memory on the back. Sweep line-size / ways / controller-count combinations. Assertion: stat
   counters match closed-form predictions.
3. **Integration tests** (new `tests/spatz_insitu/testset.cfg`): the Spatz `hello` binary plus
   the curated benchmark suite from phase 6. Assertion: cycle count matches RTL reference.

Regression: the existing `spatz` testset must continue to pass unchanged (gate on `use_insitu_
cache=False`).

---

## 7. Telemetry & Debuggability

Mirror the RTL's end-of-sim stats exactly so we can `diff` against RTL runs.

Per controller, emit (at end-of-sim, in a `vp::Component::stop` or similar final hook):
```
insitu_cache/tile/ctrl<i>: rd_hit=<n>  rd_miss=<n>  rd_total=<n>
                            wr_merge=<n> wr_inval=<n> wr_total=<n>
                            sram_rd=<n>  wb=<n>
                            stall_resp=<n> stall_miss=<n> stall_evic=<n>
                            stall_allpend=<n> stall_mshr=<n> stall_wrconflict=<n>
```

Per request, enable a fine-grained trace (`--trace=insitu_cache/.*`) that logs:
`addr, set, tag, way, outcome∈{hit,miss-new,miss-merge}, resolve_cycle, latency`.

For the GUI: register `vp::Signal<uint64_t>` for `req_addr`, `refill_addr`, `miss_level`,
`evic_level`, `mshr_level` per controller. This gives us the same waveform surface we'd get in
RTL.

---

## 8. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| GVSoC `IoReq` can't carry 64B payload cleanly for refills | Low | Use `set_data(nullptr)` for metadata-only latency tracking; the 64B data is private to the cache state. The refill `IoReq` to L2 uses a buffer we own. This matches `cache_v3.cpp:323-328`. |
| Interco round-robin granularity differs from RTL causing fairness drift | Medium | Instrument per-port cycle-share counters; if imbalance exceeds threshold, replace with the exact `stream_arbiter` logic port. |
| SPM as L2 stand-in has unrealistic bandwidth (banked 32×8B = 256B/cycle) | Medium | Model an L2 bottleneck by placing a bandwidth-limited router between cache's `o_L2` and SPM. `router.Router(bandwidth=16)` gives a realistic single-port AXI. |
| Python/config-tree gvrun path (`USE_GVRUN=1`) diverges from classic path | Medium | Implement classic path only in phases 1-5; treat gvrun as a phase-7 port. Keep the `InsituCacheConfig` compatible with both by using plain `Config`/`cfg_field`. |
| RTL reference numbers drift during `zexin/cachepool_dev_refactoring` work | Medium | Pin a specific RTL commit for each validation round; track in a `validation/rtl_baseline.md`. |
| Upstream DMA still targets SPM — does it go through cache? | Verified no (§2.2) | DMA bypasses the cache in the RTL (`i_DMA_INPUT`). Our wiring (phase 5) preserves this. |

---

## 9. Non-Goals (Scope Exclusions)

- **Coherence across tiles.** The canonical config is 1 tile. Multi-tile coherence is a future
  project.
- **Instruction-cache integration.** The existing `hierarchical_cache.py` icache stays untouched.
- **Power modeling.** Not in scope.
- **RTL-equivalence for the forwarding-buffer internal state machine.** We model buffer
  hit/writeback as lumped effects.
- **Full cycle-exactness.** Target is ~5%, not 0%.

---

## 10. Deliverables Checklist

Phase 0:
- [ ] `core/models/cache/insitu/{CMakeLists.txt, insitu_cache_config.py}` exists, builds empty.
- [ ] `add_subdirectory(insitu)` added to `core/models/cache/CMakeLists.txt`.

Phase 1:
- [ ] `insitu_cache_controller.{cpp,py}` implements single-controller model.
- [ ] `core/tests/insitu_cache/ctrl_*.cfg` unit tests pass.

Phase 2:
- [ ] `insitu_cache_interco.{cpp,py}` implements hashed interco.
- [ ] Interco unit tests pass.

Phase 3:
- [ ] `insitu_cache_coalescer.{cpp,py}` implements write-through merger.
- [ ] Coalescer unit tests pass (N merges → 1 burst).

Phase 4:
- [ ] `insitu_cache_tile.py` composes controllers + interco + coalescer.
- [ ] Tile-level synthetic tests pass.

Phase 5:
- [ ] `ClusterArch.use_insitu_cache` flag added.
- [ ] Spatz `hello` binary runs with and without the cache enabled.
- [ ] No existing-test regressions.

Phase 6:
- [ ] Validation report (`validation/insitu_cache_vs_rtl.md`) with per-workload cycle+counter
      comparison.
- [ ] Fidelity knobs calibrated; defaults updated in `InsituCacheConfig`.

Phase 7 (conditional):
- [ ] Any fidelity refinement justified by phase-6 data.

---

## 11. Reference Index (quick-lookup)

For easy navigation during implementation, here are the specific GVSoC files to use as
templates/imports, tagged by the role they play for our model.

| Role | GVSoC file | Notes |
|---|---|---|
| Example set-associative cache (closest existing model) | `core/models/cache/cache_v3.{cpp,py}` | LFSR replacement, synchronous refill with save/restore, GUI signals |
| Example composite cache | `core/models/cache/hierarchical_cache.py` | L0+L1 composition pattern — use as a template for `InsituCacheTile` |
| Example bank-address-hash component | `pulp/pulp/cluster/l1_interleaver_impl.cpp` | `get_addr()` → bank_id → `req_forward` — directly analogous to our interco |
| Example target-layer wiring | `pulp/pulp/snitch/snitch_cluster/snitch_cluster.py:272-283` | Where we tee in the cache |
| Example multi-lane TCDM origin | `pulp/pulp/snitch/snitch_core.py:324-339` (`o_VLSU`) | Confirms 4-lane Spatz → 4 TCDM masters per core |
| Core Component API | `engine/python/gvsoc/systree.py` (Component, SlaveItf, itf_bind) | `add_sources`, `add_properties`, `itf_bind`, `bind` |
| IoReq API | `engine/engine/include/vp/itf/io.hpp` | `get_addr/get_size/get_is_write/inc_latency/set_duration/save/restore/get_args` |
| Queue helper | `engine/engine/include/vp/queue.hpp` | Used by `cache_v3.cpp:110` for pending refill queue |
| Signal/Trace | `engine/engine/include/vp/signal.hpp`, `vp/trace.hpp` | For the per-controller telemetry |
| Memory latency+bandwidth reference | `core/models/memory/memory_v2.cpp:288-358` | `next_packet_start` bandwidth trick — reuse in coalescer→L2 path |

---

## 12. Next Immediate Action

Before writing any code, confirm the two key open questions with the user:

1. **Integration stance.** Phase-5 plan is **stance (B)** (cache upstream of existing SPM-as-L2).
   Acceptable, or does the workload require stance (A) (SPM replaced entirely)?
2. **Validation RTL commit.** Phase-6 needs a pinned RTL reference. Which commit on
   `zexin/cachepool_dev_refactoring` + which commit on `dev/cache-refactoring-multi-tile`
   should the initial validation round compare against?

Once those two are fixed, start Phase 0 (half-day task) and move into Phase 1 without further
coordination.
