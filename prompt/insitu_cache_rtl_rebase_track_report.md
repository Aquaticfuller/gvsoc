# InSitu Cache — Tracking the Rebased RTL (2026-05-22)

> Synchronizes the GVSoC perf model with the latest RTL at
> `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/working_dir/insitu-cache/`.

## 1. Summary

Two main outputs:

1. **New architecture spec**: `prompt/insitu_cache_architecture_v2.md`. Documents the
   restructured RTL — single wide cache + N→1 coalescer, partitionable/flushable
   wrapper, three coalescer styles, multi-read MSHR opt-in, SPM partitioning,
   per-SoC controller variants (CachePool ReqRsp vs. Flamingo AXI).
2. **Phase-A model updates** in `core/models/cache/insitu/`. Five new config knobs,
   four C++ behaviours gated on those knobs, default values flipped to match the
   new CachePool ctrl defaults.

Phase B (full topology refactor — replacing the per-tile 4-controller + interco
with a single wide cache + a true N→1 coalescer) is **not** in this round; it's
documented as the next step in `prompt/insitu_cache_architecture_v2.md` §11.

## 2. What changed in the latest RTL (vs. prior spec)

Full delta is in `prompt/insitu_cache_architecture_v2.md` §0. Highlights:

| Aspect | OLD | NEW |
|---|---|---|
| Per-tile cache count | 4 controllers in parallel | 1 single cache instance |
| Multi-port arbitration | hashed N→M interco | N→1 `par_coalescer_top` + bypass xbar |
| Default associativity (CachePool ctrl) | 4 | 4 |
| Default `DataPartSplit` | 4 (folded) | 1 (unfolded) |
| Default `UseHashWaySelect` | 1 (hash) | 0 (LRU) |
| `WriteThroughMode` | implicit (hybrid) | parameter, default 0 (write-back) |
| Coalescer | single `write_through_merger` (watchdog) | three styles: `par_coalescer`, `seq_coalescer`, `write_through_merger` |
| MSHR per pending line | one read | optional linked list (`ENABLE_MULTI_READ_PEND`) |
| Flush / invalidate | none | 2-bit `cache_sync_insn` (4 modes) |
| SPM mode | none | Hyper-SPM via `bank_depth_for_SPM_i` |
| Forwarding buffer | 1-entry | 1- or N-entry (parameterised) |
| Per-SoC variant | one | two (CachePool ReqRsp, Flamingo AXI) |

## 3. Phase-A model updates

### 3.1 `insitu_cache_config.py`

New fields on `InsituCacheControllerConfig`:

- `write_through_mode: bool = False` — when `True`, write hits emit a write-through to L2 via the coalescer; when `False` (latest RTL default), pure write-back.
- `enable_multi_read_pend: bool = False` — when `True`, read-on-READ_PEND merges don't consume the `retr_fifo` budget (matches the RTL's linked-list approach to merging multiple pending reads to the same line).
- `enable_spm: bool = False` + `bank_depth_for_spm: int = 0` — when enabled, the cache's effective number of sets is reduced by `bank_depth_for_spm`, mimicking the partitionable wrapper's address remapping.
- `enable_flush: bool = False` — reserved API surface. Phase A does not implement the flush sequence.

Flipped defaults (to match the latest `cachepool_cache_ctrl.sv` parameters):

- `use_hash_way_select`: `True` → `False` (LRU is the new default)
- `refill_bank_write_cycles`: `2` → `1` (unfolded `DataPartSplit=1`)
- `folded_evict_penalty_cycles`: `3` → `0` (unfolded)

`make_cachepool_512_config()` now produces the new (LRU + unfolded + write-back)
configuration. A new `make_cachepool_512_legacy_config()` factory returns the
pre-2026-05-22 (folded + hash + write-back+WT-coalesced) configuration for
regression purposes.

### 3.2 `insitu_cache_controller.cpp` behaviour wiring

- Reads the five new properties via `get_js_config()->get_child_*` in the
  constructor.
- Computes `effective_num_sets_ = num_sets_ - bank_depth_for_spm_` when SPM
  is enabled.
- `addr_set()` is now a wrapper that, when SPM is enabled, folds the raw set
  into the cacheable region `[bank_depth_for_spm_, num_sets_)` — matching how
  the RTL's partitionable wrapper translates upstream addresses.
- Write-through emission (both on the synchronous write-hit path in
  `handle_request` and on the MSHR-drain path in `fsm_drain_mshr`) is gated
  on `write_through_mode_`. In the new default (`False`), writes only mark the
  line dirty.
- The `READ_PEND` merge path skips `retr_fifo_level_` accounting when
  `enable_multi_read_pend_` is true and the incoming op is a read, capturing
  the "linked-list of pending reads costs no global FIFO slot" semantics.

### 3.3 `insitu_cache_controller.py`

Added the five new fields to `add_properties()` so they're visible to the C++
side via `get_js_config()`.

### 3.4 `core/models/cache/insitu/README.md`

Header updated to point at the v2 architecture doc as the current source of
truth, with a brief Phase-A status block summarising the new defaults.

## 4. What was verified

- `make all TARGETS=insitu_cache_microbench` succeeds with the updated defaults.
- The microbench runs end-to-end and prints `[CALIB_REPORT]` lines. Cycle
  counts shifted slightly in the expected direction (e.g. `cold_stream_r4`:
  175 → 171, reflecting the reduced refill bank-write cycles).
- `make all TARGETS="spatz:use_insitu_cache=True insitu_cache_tb"` still
  builds cleanly — no regression to existing targets.
- The `spatz` target with `use_insitu_cache=False` (default) is unchanged.

## 5. What was *not* done (Phase B scope)

Documented in `prompt/insitu_cache_architecture_v2.md` §11:

1. **Topology refactor**: keep the current 4-controller GVSoC tile *or*
   refactor into a single wide cache + a real N→1 coalescer mirroring
   `par_coalescer_top`. Currently the GVSoC tile is 4 narrow controllers; the
   RTL is 1 wide cache. The current model still validates as cycle-approximate
   for unit-level testing, but a Phase-B refactor is needed before claiming
   "RTL-faithful topology".
2. **Real flush sequence**: implement the FSM that walks the cache bank,
   emits evictions, updates valid bits, gates new requests during flush.
3. **Bypass-xbar scalar port**: in the new RTL the Snitch scalar port
   bypasses the coalescer. The current tile doesn't model this asymmetry.
4. **Per-SoC controller variants**: distinguish the CachePool (ReqRsp +
   custom burst protocol) from the Flamingo (AXI4) downstream behaviour
   for accurate refill / writeback timing under each.
5. **Multi-entry forwarding buffer**: the new `sram_forwarding_buffer_multi`
   is not modelled.

## 6. How to repeat this update next time

`CLAUDE.md` now has a §"Tracking new RTL revisions" section with the 7-step
procedure. Memory `~/.claude/projects/.../memory/rtl_readonly.md` records
the latest RTL location. Quick recap:

1. Re-read the RTL package + top + tcdm-wrappers + per-SoC ctrl + coalescer.
2. Don't modify the RTL tree.
3. Update `prompt/insitu_cache_architecture_v2.md`.
4. Update `core/models/cache/insitu/insitu_cache_config.py`.
5. Wire the C++ side as needed.
6. Regression smoke: rebuild `insitu_cache_microbench` + `spatz:use_insitu_cache=True`
   + `insitu_cache_tb`; run the microbench, confirm `[CALIB_REPORT]` lines move
   in expected directions.
7. Document the round in a `prompt/...track_report.md` like this one.
