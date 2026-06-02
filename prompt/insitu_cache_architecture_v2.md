# InSitu Cache — Architecture (v2, 2026-05-22; revised 2026-06-01)

> **⚠ 2026-06-01 revision — default config flipped.** Since this doc was first
> written (2026-05-22), the RTL made the L1 data-bank micro-architecture
> **config-selectable** (`3af9362 [CFG] make L1 folded/hash-way/fwd-buffer
> config-selectable`) and **promoted the forwarding buffer to a top-level
> parameter** (`fbabd6a`). The shipping `cachepool_512` default is now the
> **production** cache (**folded + hash-way + forwarding-buffer ON**), *not* the
> unfolded/LRU config this doc originally described as the default. The
> unfolded+LRU+no-fwd config is now the explicit opt-in "conventional" cache.
> See the new **§0.1** below; the §0 table rows for `DataPartSplit` /
> `UseHashWaySelect` / forwarding-buffer have been corrected accordingly.
>
> **Update note.** The prior architecture doc (`insitu_cache_architecture.md`)
> still describes the original implementation on the `cachepool_dev_refactoring`
> branch — the one that the current GVSoC perf model in
> `core/models/cache/insitu/` was designed against. This v2 doc describes a
> **substantially restructured** RTL that lives on the new working tree at
> `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/working_dir/insitu-cache/`.
> When the two docs disagree on topology / parameter defaults / port semantics,
> **this v2 doc is the source of truth for the latest RTL**.
>
> Audience: engineers updating the GVSoC perf model to track the latest RTL.
>
> Read-only reference path:
> `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/working_dir/insitu-cache/`

## 0. Top-Level Architecture Change vs. the Prior Doc

| Aspect | OLD (`insitu_cache_architecture.md`) | NEW (this doc) |
|---|---|---|
| Per-tile cache count | **4 controllers** | **1 single cache instance** (per `cachepool_cache_ctrl`) |
| Multi-port arbitration | `tcdm_cache_interco` (hashed N→M routing) | `par_coalescer_top` (N narrow → 1 wide, address-coalescing) + bypass xbar for scalar port |
| Upstream data width | 32 bits (TCDM word) on each controller's input | 64 bits per port at the coalescer; **512 bits at the cache** (full line) |
| Default associativity | 4 ways | 4 ways (CachePool ctrl) or 16 ways (cache_top default) |
| Default `DataPartSplit` | 4 (folded) | **config-selectable; `cachepool_512` default = 4 (folded)** via `l1d_use_folded=1` (was documented as unfolded on 2026-05-22 — corrected, see §0.1) |
| Forwarding buffer | n/a | **`UseForwardingBuffer` top-level param, `cachepool_512` default = ON**; 1-entry write-back row cache; **requires `UseHashWaySelect=1`** (see §0.1, §3) |
| Default `NumPseudoDualBanks` | 2 | 2 (CachePool ctrl `BankFactor`) or 8 (cache_top default) |
| Coalescer | Single `write_through_merger` (watchdog FSM) | Three styles: `par_coalescer_top` / `seq_coalescer_top` / `write_through_merger` (legacy) |
| Write policy | Write-back for hits + write-through-coalesced for stores | **Pure write-back** by default (`WriteThroughMode=0`); write-through is optional |
| Flush/invalidate | Not in OLD doc | **2-bit `cache_sync_insn`** with 4 modes |
| SPM mode | Not in OLD doc | **Hyper-SPM partitioning** via `bank_depth_for_SPM_i` |
| MSHR | One pending line per set | Same, plus **optional `ENABLE_MULTI_READ_PEND`** — linked list of pending reads per line |
| Per-SoC variant | Single controller for CachePool | **Two flavours**: `cachepool_cache_ctrl.sv` (ReqRsp downstream, custom refill burst protocol) and `flamingo_spatz_cache_ctrl.sv` (AXI4 downstream) |
| Replacement | `UseHashWaySelect=1` (hash) | `UseHashWaySelect` config-selectable; **`cachepool_512` default = `1` (hash)** via `l1d_use_hash_way=1` (the `cachepool_cache_ctrl` *module* default is still `0`/LRU, but the shipping `.mk` overrides it — corrected, see §0.1) |

**Net implication for the GVSoC perf model.** The current model
(`core/models/cache/insitu/`) implements the OLD architecture (per-tile
N→M interco + N controllers + a separate coalescer). The NEW RTL has
collapsed the per-controller parallelism into a single wide-line cache fed
by a coalescer. **A full topology refactor is out of scope for this update;**
this doc describes the new architecture and the §11 below proposes a
phased model migration.

## 0.1 Config-selectable data-bank micro-architecture (2026-06-01)

As of `3af9362 [CFG] make L1 folded/hash-way/fwd-buffer config-selectable`
(+ insitu-cache `fbabd6a`), the L1 data-bank micro-architecture is chosen by
four `cachepool_*.mk` knobs, emitted as `VLOG_DEFS` and threaded
cluster → group → tile → `cachepool_cache_ctrl` → `insitu_cache_tcdm_wrapper`:

| `.mk` knob | macro | meaning | `cachepool_512` default |
|---|---|---|---|
| `l1d_use_folded` | `L1D_USE_FOLDED` | folded/skewed data banks (`UseFoldedDataBanks`, sets `DataPartSplit`) | **1** |
| `l1d_fold_way_group` | `L1D_FOLD_WAY_GROUP` | fold group; `0` ⇒ auto `min(4, ways)` = 4 | **0 → 4** |
| `l1d_use_hash_way` | `L1D_USE_HASH_WAY` | hash-based way-select vs. LRU (`UseHashWaySelect`) | **1** |
| `l1d_use_fwd_buf` | `L1D_USE_FWD_BUF` | SRAM forwarding buffer (`UseForwardingBuffer`) | **1** |

**Two supported configurations** (the legal combos enforced by the
`insitu_cache_tcdm_wrapper` elaboration `$fatal` guards):

- **Production** = folded(1) + hash-way(1) + fwd-buffer(1). **This is the
  `cachepool_512` default.** It is the config the standalone calibration
  testbench (`reports/cache_calib/`) elaborates with (banner: `PartSplit=4,
  Folded=1, Hash=1`), so the GVSoC perf model's *default* factory and the
  calibration config should track this.
- **Conventional** = unfolded/PartSplit=1(0) + LRU(0) + fwd-buffer-off(0). The
  opt-in plain set-associative cache.

**Constraint (`fbabd6a`, `608f54c`).** `UseHashWaySelect=0` (LRU) is legal **only**
for the unfolded cache with the forwarding buffer **off**. Two independent reasons
force hash-way otherwise: (a) the forwarding buffer corrupts dirty data on
eviction in multi-way builds without hash-way; (b) skewed-fold banks
(`PartSplit>1`) make the tile fold-arbiter unable to disambiguate ways under
all-ways-active reads. So `fold OR fwd-buffer ⇒ hash-way=1`.

**Forwarding buffer (`UseForwardingBuffer`, default ON).** A **1-entry
write-back row cache** (`src/utilities/sram_forwarding_buffer.sv`; an N-entry
`sram_forwarding_buffer_multi.sv` also exists) sitting between an access
controller and its SRAM banks. It caches one SRAM row in registers:
matching reads return buffer data **combinationally** (SRAM read suppressed);
matching writes merge into the buffer (SRAM write suppressed); dirty buffer is
written back on address change. Part-aware when `PartSplit>1` (per-part validity
bitmap, additive populate). Tunable RAW-forwarding (`EnableRawForwarding`) and
in-flight write-merge (`EnableInflightWriteMerge`). **Perf effect:** removes the
1-cycle SRAM-read latency for repeated same-row accesses and resolves same-cycle
RAW hazards — i.e. it tightens the steady-state hit pipeline. In the
cycle-approximate GVSoC model this is currently folded into the calibrated
`hit_latency_cycles` (the RTL 10-cyc isolated / 7-cyc streaming hit numbers were
measured with it on); an explicit same-row forward model is a Phase-B refinement.

**Other config changes (2026-06-01).** `cachepool_512` default size dropped to
**1 tile / 4 cores** (was 4 tiles / 16 cores).

## 0.2 RTL fixes since 2026-05-22 (correctness/verif; low perf impact)

For completeness (none change the perf-model topology; a couple touch MSHR/drain
modeling fidelity):

- `bab86f3 insitu_cache_core: reserve one MSHR slot when InfoStoreWidth divides
  CacheLineWidth` — effective per-line MSHR sub-entry capacity is one fewer in
  that case (`MaxNumSubarray-1`). Minor; affects when secondary-miss merging
  saturates.
- `4f41fd4 insitu_cache_core: fix MSHR drain-count overflow` — drain bookkeeping
  bug fix.
- `2710920 tcdm_wrapper: hoist write out of pseudo-dual-port status case to break
  grant-feedback comb loop` — elaboration/timing fix (folded grant path).
- `8815d14 cache_core/tcdm_wrapper: expose drain state via ports` — observability
  (drops hierarchical refs); no behavioural change.
- `01763a4` / `efb42f2` / `eb4ae5c` / `2178e47` / `1365331` (sync-flush-fixes
  branch) — the cache-sync/flush FSM: drain the pipeline before sync writes,
  block new upstream reqs while the sync FSM is active, gate bank reads during
  sync meta-writes, fix `has_dirty` oscillation. Relevant **when** the GVSoC
  model implements the flush sequence (still the reserved `enable_flush` knob —
  not yet behaviourally modelled).

## 1. New Top-Level Topology

```
                    N cores' TCDM ports (typically 5 per core: 1 scalar + 4 Spatz lanes)
                                 │
              ─────────────────────────────────────────
              │                                       │
       Snitch scalar port                  Spatz vector lanes (N-1 ports)
              │                                       │
              │                                       ▼
              │                              par_coalescer_top
              │                              (N-1 narrow → 1 wide)
              │                                       │
              │                                       ▼
              │                              coalesced wide req (≤512b)
              │                                       │
              └────────► bypass_xbar  ◄──────────────┘
                                 │
                            wide req
                                 │
                                 ▼
                  insitu_cache_tcdm_wrapper
                    (optionally _partitionable_flushable)
                                 │
                            line-wide req
                                 │
                                 ▼
                       insitu_cache_top
                           (1 instance per cluster)
                                 │
                                 ▼
                    refill request bursts (128b/beat × 4 beats)
                                 │
                                 ▼
                  ReqRsp (CachePool) / AXI4 (Flamingo)
                                 │
                                 ▼
                              L2 / DRAM
```

**Key differences from the old:**

- **One cache per cluster, not four**. The `cachepool_cache_ctrl` instantiates a single `insitu_cache_tcdm_wrapper` (CachePool, `cachepool_cache_ctrl.sv:489-557`).
- **Coalescer is upstream of the cache**, not on its write-through output. The coalescer's job is now to pack N narrow concurrent requests addressed to the same cache line into one wide request that the cache then handles.
- **The Snitch scalar port bypasses the coalescer** via `bypass_xbar`. The cache sees scalar + coalesced-vector traffic interleaved.
- **The cache operates on cache-line-wide data**. Internal data path is 512 bits. Narrow per-port responses are recovered by the coalescer using `hitmap`/`ofsts` metadata it tracked in its `downstream_info_t`.

## 2. Canonical Configuration (CachePool, latest)

From `cachepool_cache_ctrl.sv:15-91`:

| Parameter | Value | Source |
|---|---|---|
| `NumPorts` | 10 (configurable) | parameter, `cachepool_cache_ctrl.sv:20` |
| `CoalExtFactor` | 1 (default) | parameter, `:22` |
| `AddrWidth` | 32 | parameter, `:26` |
| `WordWidth` | **64 bits** (was 32 in old doc) | parameter, `:28` |
| `TagWidth` | 64 | parameter, `:32` |
| `NumCacheEntry` | 512 | parameter, `:38` |
| `CacheLineWidth` | 512 (64 B) | parameter, `:40` |
| `SetAssociativity` | 4 | parameter, `:42` |
| `DataPartSplit` | **1 (unfolded)** | parameter, `:44` |
| `UseHashWaySelect` | **0 (LRU)** | parameter, `:46` |
| `BankFactor` (= `NumPseudoDualBanks`) | 2 | parameter, `:48` |
| `RefillDataWidth` | 128 | parameter, `:54` |
| `CacheWaysEntry` = `NumCacheEntry/SetAssociativity` | 128 | localparam, `:70` |
| `NumDataBankPerWay` = `BankFactor * (CacheLineWidth/WordWidth)` | 16 | localparam, `:72` |
| `NumTagBankPerWay` = `BankFactor` | 2 | localparam, `:74` |
| `BurstLength` = `CacheLineWidth/RefillDataWidth` | 4 | localparam, `:68` |

Cache size per cluster: `NumCacheEntry × (CacheLineWidth/8)` = 512 × 64 B = **32 KB per cluster** (down from "256 KB per tile × 4 ways × 4 ctrl" implied by the old doc). The reduction reflects the move from 4 cache instances to 1.

## 3. New Sub-Modules (vs. the Old Doc)

### 3.1 `par_coalescer_top` (parallel coalescer)

Path: `src/coalesce_unit/par_coalescer/par_coalescer_top.sv`

Replaces the OLD `tcdm_cache_interco` (which did hashed routing to N controllers). The new coalescer:

- N upstream narrow ports (typically 64 b each in CachePool).
- 1 downstream wide port (full cache line, 512 b).
- Combines multiple in-flight narrow requests that fall in the **same downstream cache line** into ONE downstream wide request, packing per-port data into the line at byte offsets dictated by each port's address LSBs.
- Tracks a `hitmap` (which ports contributed) and `ofsts` (where each contribution went) inside the `downstream_info_t` payload, so the response can be split back per port.
- `ExtFactor`: extends each port's "window" — each port can have up to `ExtFactor` independent in-flight requests being coalesced.
- Sub-variants:
  - `par_coalescer_equal_window.sv` — all ports share the same coalescing window (start-aligned).
  - `par_coalescer_extend_window.sv` — window extends dynamically with newly-arriving requests (end-aligned).
  - `req_coalescer_v2.sv` — request-side merging.
  - `rsp_spliter_v2.sv` — response-side splitting (uses the `hitmap`/`ofsts` recovered from the response).
  - `non_coalescer.sv` — pass-through (no coalescing). Used when bandwidth permits direct forwarding.

### 3.2 `seq_coalescer_top` (sequential coalescer)

Path: `src/coalesce_unit/seq_coalescer/seq_coalescer_top.sv`

Alternative coalescing strategy: sequential mergers (`seq_coalescer_req_merger.sv` and `seq_coalescer_multi_req_merger.sv`). Pipelined N→1 packing with `NumMerger` sub-mergers. Throughput is `1 wide per NumMerger cycles`; latency per merge is `~2–3 cycles`. Lower bandwidth than par but smaller area.

### 3.3 `write_through_merger.sv` (legacy)

Path: `src/coalesce_unit/wirte_merger/write_through_merger.sv` (note the typo "wirte" in the directory name).

The OLD design's watchdog-based coalescer. Retained for the write-through path when `WriteThroughMode=1`. Now demoted to legacy: vector traffic uses `par_coalescer_top` instead.

### 3.4 `insitu_cache_decoder.sv` and `insitu_cache_encoder.sv` (new)

Paths: `src/insitu_cache/insitu_cache_{decoder,encoder}.sv`

The OLD design had hit/miss/conflict detection and LRU/mask update logic inline in the core FSM. The NEW design factors them into two dedicated modules:

- **Decoder** (`insitu_cache_decoder.sv:120-288`): given a request task, computes way / tag / set; performs hit/miss/conflict detection combinationally; outputs `dec_is_hit`, `dec_is_hit_pend_o`, `dec_is_hit_conflit_o`, `dec_is_all_pend_o`. If `UseHashWaySelect=1`, the way is computed as a deterministic hash `addr_tag ^ addr_set`; otherwise full LRU victim search.
- **Encoder** (`insitu_cache_encoder.sv:170-236`): LRU updates, byte-mask merging, status transitions (`INVALID` ↔ `VALID` ↔ `READ_PEND` ↔ `WRITE_PEND`). When `ENABLE_MULTI_READ_PEND` is defined, the encoder maintains a linked list of pending reads per line via `miss_meta_t.link_enable` and `link_ptr`.

These modules do **not** change the cache's externally-visible cycle-level timing (the work was already happening in the OLD core FSM); they simplify the implementation.

### 3.5 `insitu_cache_tcdm_wrapper_partitionable_flushable.sv` (NEW variant)

Path: `src/insitu_cache/insitu_cache_tcdm_wrapper_partitionable_flushable.sv`

A thin wrapper around the regular `insitu_cache_tcdm_wrapper` that adds two software-controlled features (see §5 and §6 below):

- **Hyper-SPM partitioning** via `bank_depth_for_SPM_i`.
- **Flush / invalidate** via the 2-bit `cache_sync_insn_i`.

The Flamingo cache controller (`flamingo_spatz_cache_ctrl.sv`) uses this wrapper. The CachePool controller uses the plain `insitu_cache_tcdm_wrapper` (no partition / flush features wired today, but `cache_sync_*` ports are present).

### 3.6 New utilities

Under `src/utilities/`:

- `cache_to_axi.sv` — adapts the cache's downstream miss/evict to AXI4 AR/AW/W channels (used by `flamingo_spatz_cache_ctrl`).
- `decouple_channels_adapter.sv` — breaks combinational feedback loops between req and rsp channels.
- `decouple_queue_sync.sv` — sync FIFO for clock-domain crossing on the L2 path.
- `dual_port_bank.sv`, `dual_port_rf.sv`, `folded_data_bank.sv` — refactored SRAM primitives.
- `id_buffer.sv` — tracks IDs for pending transactions (used in multi-port refill paths).
- `pseudo_dual_port_fifo.sv`, `pseudo_dual_port_way.sv` — improved pseudo-dual-port helpers.
- `sram_forwarding_buffer_multi.sv` — N-entry forwarding buffer (was 1-entry in the OLD design); LRU-managed, supports speculative writeback and same-address reuse.

## 4. Per-SoC Cache Controllers

Two variants under separate directories:

### 4.1 `cachepool_cache_ctrl.sv` (CachePool / Snitch)

- `NumPorts = 10` (10 narrow TCDM ports — typically 2 cores × 5 ports each, or one core's full TCDM bus).
- Last port (`NumPorts-1`) is the Snitch scalar, which **bypasses the coalescer** via `bypass_xbar`. The other `NumPorts-1` ports (Spatz vector lanes) go through `par_coalescer_top`.
- Downstream: custom ReqRsp protocol with explicit burst metadata (`refill_req_t`, `burst_req_t`, `refill_rsp_t`).
- Default `SetAssociativity = 4`, `UseHashWaySelect = 0` (LRU), `DataPartSplit = 1`.

### 4.2 `flamingo_spatz_cache_ctrl.sv` (Flamingo / Spatz)

- Same `NumPorts = 10`.
- Downstream: **AXI4** via `cache_to_axi.sv` (`flamingo_spatz_cache_ctrl.sv:315-325`).
- Uses `insitu_cache_tcdm_wrapper_partitionable_flushable` (SPM + flush enabled).
- Otherwise structurally identical to the CachePool variant.

## 5. Hyper-SPM Partitioning

Path: `insitu_cache_tcdm_wrapper_partitionable_flushable.sv:188-218`.

**Mechanism.** A software-set parameter `bank_depth_for_SPM_i`
(`tcdm_bank_addr_t` = `log2(CacheBankDepth) − log2(NumPseudoDualBanks)` bits)
specifies how many bank rows to reserve as software-managed scratchpad. The wrapper splits the cache's set space into two regions:

```text
cache_partition_set_for_SPM   = NumPseudoDualBanks * bank_depth_for_SPM_i
cache_base_for_SPM            = cache_partition_set_for_SPM
cache_partition_set_for_cache = CacheBankDepth - cache_partition_set_for_SPM
```

**Address translation (upstream → cache).** Incoming addresses are remapped so the cache only ever sees the upper sets `[cache_base_for_SPM, CacheBankDepth)`:

```verilog
upstream_tag = (upstream_addr >> log2(line_bytes)) / cache_partition_set_for_cache
upstream_set = (upstream_addr >> log2(line_bytes)) % cache_partition_set_for_cache
                                          + cache_partition_set_for_SPM
```

**Address restoration (cache → downstream).** Refill addresses going to L2 are inverted:

```verilog
downstream_restored_addr = (downstream_tag * cache_partition_set_for_cache)
                          + (downstream_set - cache_partition_set_for_SPM)
```

**SPM-region access** does **not** go through this wrapper. Software directly addresses the SRAM banks via a parallel path (managed by the SoC integration layer, not the cache itself). The SPM region appears as a separate address window with no cache semantics.

**Effective cache capacity.** `CacheBankDepth × NumPseudoDualBanks × SetAssociativity × (CacheLineWidth/NumPseudoDualBanks)` minus the SPM-reserved fraction. With `bank_depth_for_SPM_i = N`, the cache's effective capacity is reduced by `N × NumPseudoDualBanks × SetAssociativity × line_width`.

**Perf-model implication.** SPM partitioning isn't a runtime "mode switch" — it's an address-translation that constantly shrinks the effective cache. The miss rate model should account for the reduced effective associative capacity. SPM-region accesses bypass the cache entirely (zero cache-side latency, but they still hit the bank SRAM).

## 6. Flush / Invalidate Sequence

Path: `insitu_cache_tcdm_wrapper_partitionable_flushable.sv:117-119` and the underlying wrapper's FSM.

**Software interface.** A 2-bit `cache_sync_insn_i` selects the operation:

| `cache_sync_insn_i` | Mode | Action |
|---|---|---|
| `2'b00` | flush + invalidate | for each line: if dirty → writeback; clear `VALID` |
| `2'b01` | flush only | for each dirty line → writeback; keep `VALID` |
| `2'b10` | invalidate only | clear `VALID` (no writeback — discards dirty data) |
| `2'b11` | bank init | reset all tag SRAM bits / clear all valid (cold-start) |

`cache_sync_valid_i` rising → operation starts; the wrapper deasserts `cache_sync_ready_o` until the operation completes.

**Mechanism.** The FSM walks the cache bank from set 0 to `CacheBankDepth − 1`, reading each line's metadata and either:
- emitting an evict-FIFO push (if dirty + write-back required),
- updating tags/valid in-place (for invalidate-only or init),
- skipping (for flush-only on clean lines).

Pending lines (`READ_PEND` / `WRITE_PEND`) are handled specially: the encoder's `has_pend_line_o` flag is consumed by the flush sequencer, which waits for in-flight refills to drain (or aborts them, depending on mode).

**Latency.** Worst case = `CacheBankDepth × 2` (read meta + writeback) plus eviction-FIFO drain time. For `CacheBankDepth = 128`: ≈ 256 cycles + drain ≈ **few-hundred cycle whole-cache flush**.

**Perf-model implication.** Adds a new "cache busy with flush" state. While flushing, new upstream requests are stalled (`upstream_req_ready_o = 0`). Refills triggered by writebacks add traffic to L2.

## 7. Multi-Read MSHR (optional)

Compile-time macro `ENABLE_MULTI_READ_PEND` (referenced in `insitu_cache_encoder.sv`, `_decoder.sv`, `_core.sv`).

**OLD behaviour.** A second read to a line that is already `READ_PEND` / `WRITE_PEND` stalls with `MSHR_FULL_STALL` until the in-flight refill lands.

**NEW behaviour (when enabled).** The encoder maintains a linked list of pending reads on the same line via the `miss_meta_t` fields `is_full`, `is_prime`, `link_enable`, `link_ptr`. Decoder outputs `dec_read_hit_pend_prime_way_o` and `dec_read_hit_pend_linkable_way_o` to find suitable links. Subsequent reads to the same pending line join the link list instead of stalling. On refill arrival, all linked pending reads are serviced from the same line in sequence.

**Capacity.** The list can hold up to `SetAssociativity` linked entries per way; once the way's MSHR subarrays are full (`is_full=1`), further reads still stall.

**Perf-model implication.** Reduces stall pressure on workloads with high pending-read concurrency to the same line. Estimated win: ~2–3% on streaming-read kernels with multi-port concurrency.

## 8. Updated Pipeline Latencies (Unfolded Defaults)

For `DataPartSplit = 1` (the new default), the per-transaction timings shift vs. the OLD `PartSplit=4` numbers:

| Scenario | OLD (`PartSplit=4`) | NEW (`PartSplit=1`) | Δ |
|---|---:|---:|---:|
| Read hit (steady state) | 7 cyc total round-trip | ~6 cyc round-trip | −1 |
| Read miss, clean victim | 7 + L2 + 6 | 7 + L2 + 4 | −2 (faster refill bank-write) |
| Eviction (folded vs. unfolded) | +3-4 cyc folded full-read | 0 cyc (single read serves whole line) | −3-4 |
| Write hit (write-back mode) | ~4 cyc fire-and-forget | ~4 cyc fire-and-forget | 0 |
| Write hit (write-through coalesced) | ~4 cyc + WT cost | ~4 cyc (coalescer absorbs) | 0 |
| Write miss + coalescer ↔ refill | up to 8 cyc | up to 4 cyc (par_coalescer parallel windows) | −4 (significant) |
| Flush (per line, dirty) | n/a | 2 cyc (1 read meta + 1 evict push) | new |
| Flush (per line, clean) | n/a | 1 cyc | new |
| Flush (per line, invalidate-only) | n/a | 1 cyc | new |

The `par_coalescer` style mostly affects write-miss latency by parallelising the merge across multiple in-flight cache lines.

## 9. Core FSM (Unchanged State Set)

The FSM states in `insitu_cache_core.sv:408-415` are identical to the OLD doc:

```systemverilog
typedef enum logic [3:0] {
    REQ_PROC = '0,
    RESP_STALL,
    MISS_STALL,
    EVIC_STALL,
    ALL_PEND_STALL,
    MSHR_FULL_STALL,
    WR_CONFLICT_STALL
} cache_fsm_status_t;
```

Internal data structures evolved (`miss_stall_t`, `deferred_bank_write_t`), but the state set and the request → preread → bank-read → response pipeline depth are unchanged from the OLD doc.

## 10. Forwarding Buffer (Multi-Entry Variant)

Path: `src/utilities/sram_forwarding_buffer_multi.sv`.

OLD design had a 1-entry forwarding buffer per access controller (per way, per data/meta bank). NEW design parameterises this as `NumEntries` (default `2`):

- Buffer holds up to `NumEntries` cached SRAM rows.
- Allocation priority: same-address reuse > invalid entry > LRU-clean > LRU.
- New outputs:
  - `buf_has_free_clean_o`: at least one entry is clean/invalid (enables speculative writeback).
  - `buf_near_full_o`: `NumEntries − 1` dirty entries (throttle new allocations).
- Pseudo-LRU (touching one entry makes the other LRU).
- Tracks part index and "all parts cached" flag for folded mode.

**Perf-model implication.** Multi-entry buffer absorbs ~30–40% of repeated-row SRAM reads in streaming workloads. Currently disabled in default CachePool ctrl (uses single-entry); enabled in some Flamingo configs.

## 11. Proposed GVSoC Perf-Model Migration

The current model in `core/models/cache/insitu/` implements the OLD architecture (4 parallel controllers + interco). Migrating to the NEW architecture is a substantial refactor, broken into phases:

### Phase A (low-risk, this update)

Targeted parameter-level updates without restructuring the topology:

1. **Default `DataPartSplit = 1` (unfolded)**: drop `folded_evict_penalty_cycles` to `0` by default; set `refill_bank_write_cycles` to 1 (was 2). Update the timing table in `core/models/cache/insitu/README.md` §4.
2. **`UseHashWaySelect` default flip**: default to `False` (LRU) in `InsituCacheControllerConfig` to match the new CachePool ctrl default.
3. **Add `WriteThroughMode` config field**: a boolean. When `False` (default), the controller treats writes as write-back (no coalescer involvement on every write hit). When `True`, exposes the existing write-through-coalescer behaviour.
4. **Add `EnableMultiReadPend` config field**: when `True`, change the MSHR-merge path to allow multiple pending reads per set without stalling (no full-stall on `READ_PEND` hit).
5. **Add `EnableSPM` + `BankDepthForSPM` config fields**: shrink the effective cache by `BankDepthForSPM × NumPseudoDualBanks × SetAssociativity × line_bytes` for miss-rate purposes; otherwise the model keeps the same address handling.
6. **Add `EnableFlush` config field**: stub for now; reserves the API surface. Phase B implements the actual flush sequence.

These changes are config-additive; they don't break existing test targets.

### Phase B (medium-risk, future)

Topology refactor:

1. **Add a new `InsituCacheParCoalescer` component** that does `N narrow → 1 wide` packing with `hitmap`/`ofsts` tracking. Sits where `InsituCacheInterco` currently sits.
2. **Add a `bypass_xbar` mode in `InsituCacheTile`** for the scalar port.
3. **Reduce `num_controllers` to 1** (single wide cache).
4. **Implement the flush sequence** in the controller (extra FSM state, walk the bank, emit evictions).

Phase B essentially re-builds the tile around the new architecture. Recommended once the parameter-level changes in Phase A have been validated.

## 12. Reference Path Table (updated)

| Component | Path under `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/working_dir/insitu-cache/` |
|---|---|
| Cache package | `src/insitu_cache/insitu_cache_pkg.sv` |
| Cache top | `src/insitu_cache/insitu_cache_top.sv` |
| Cache core | `src/insitu_cache/insitu_cache_core.sv` |
| TCDM wrapper (plain) | `src/insitu_cache/insitu_cache_tcdm_wrapper.sv` |
| TCDM wrapper (partition+flush) | `src/insitu_cache/insitu_cache_tcdm_wrapper_partitionable_flushable.sv` |
| Decoder | `src/insitu_cache/insitu_cache_decoder.sv` |
| Encoder | `src/insitu_cache/insitu_cache_encoder.sv` |
| Par coalescer top | `src/coalesce_unit/par_coalescer/par_coalescer_top.sv` |
| Par coalescer (equal window) | `src/coalesce_unit/par_coalescer/par_coalescer_equal_window.sv` |
| Par coalescer (extend window) | `src/coalesce_unit/par_coalescer/par_coalescer_extend_window.sv` |
| Req coalescer v2 | `src/coalesce_unit/par_coalescer/req_coalescer_v2.sv` |
| Rsp splitter v2 | `src/coalesce_unit/par_coalescer/rsp_spliter_v2.sv` |
| Non-coalescer (passthrough) | `src/coalesce_unit/par_coalescer/non_coalescer.sv` |
| Seq coalescer top | `src/coalesce_unit/seq_coalescer/seq_coalescer_top.sv` |
| Seq coalescer single merger | `src/coalesce_unit/seq_coalescer/seq_coalescer_req_merger.sv` |
| Seq coalescer multi merger | `src/coalesce_unit/seq_coalescer/seq_coalescer_multi_req_merger.sv` |
| Write-through merger (legacy) | `src/coalesce_unit/wirte_merger/write_through_merger.sv` |
| Per-SoC ctrl (CachePool) | `src/cachepool/cachepool_cache_ctrl.sv` |
| Per-SoC ctrl (Flamingo Spatz) | `src/flamingo/flamingo_spatz_cache_ctrl.sv` |
| Forwarding buffer (1-entry) | `src/utilities/sram_forwarding_buffer.sv` |
| Forwarding buffer (N-entry) | `src/utilities/sram_forwarding_buffer_multi.sv` |
| Folded data bank | `src/utilities/folded_data_bank.sv` |
| Cache→AXI | `src/utilities/cache_to_axi.sv` |
| README (RTL repo) | `README.md` |

## 13. Things This Doc Doesn't Yet Cover (TODO when needed)

- **Exact `par_coalescer` cycle counts** for the various sub-variants (equal-window, extend-window).
- **AXI4 cache-to-axi** burst sequencing latencies on the Flamingo controller (needed when the GVSoC tile binds to a DRAM model rather than an SPM).
- **Detailed signal lists** for the new utilities (`decouple_channels_adapter`, `id_buffer`, etc.).
- **Verification testbench** (`test/tb_insitu_cache.sv`) — not analysed here; could provide RTL-side reference cycle counts.
- **`spatz_top.sv` / cluster top integration** in the rebased ManyRVData tree (i.e., how the new ctrl is hooked into the cores) — needs a separate pass on `ManyRVData_rebase/hardware/src/*.sv`.
