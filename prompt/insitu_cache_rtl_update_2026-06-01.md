# InSitu Cache — RTL update tracking round (2026-06-01)

> Follows the procedure in `CLAUDE.md` §"Tracking new RTL revisions". Syncs the
> GVSoC perf model with the RTL at
> `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/working_dir/insitu-cache/`
> (submodule branch `zexin/sync-flush-fixes`) and the integrating repo branch
> `rebase/cache-refactoring-onto-main`. Previous round:
> `insitu_cache_rtl_rebase_track_report.md` (2026-05-22).

## 1. What changed in the RTL since 2026-05-22

### 1.1 The headline: default config flipped to *production*

`3af9362 [CFG] make L1 folded/hash-way/fwd-buffer config-selectable` (top repo,
2026-06-01) + insitu-cache `fbabd6a` make the L1 data-bank micro-architecture
selectable via four `cachepool_*.mk` knobs (emitted as `VLOG_DEFS`):

| `.mk` knob | `cachepool_512` default |
|---|---|
| `l1d_use_folded` | **1** (folded) |
| `l1d_fold_way_group` | 0 → auto = min(4, ways) = 4 |
| `l1d_use_hash_way` | **1** (hash-way) |
| `l1d_use_fwd_buf` | **1** (forwarding buffer on) |

So the shipping `cachepool_512` is now the **production** cache:
**folded + hash-way + forwarding-buffer ON**. The unfolded + LRU + no-fwd config
is the explicit opt-in **conventional** cache (`0/0/0`).

This is the opposite of what the v2 doc (2026-05-22) recorded as the default
(unfolded + LRU). That was correct then — at the time the `cachepool_cache_ctrl`
module default was `UseHashWaySelect=0` and the folded/hash integration into the
cachepool path landed afterwards (the 2026-05-27 `[RTL] plumb hash-way folded
cache integration` series). The default has since moved to production.

Also: `cachepool_512` default size dropped to **1 tile / 4 cores** (was 4/16).

### 1.2 Forwarding buffer promoted to a top-level parameter

`fbabd6a [RTL] support unfolded/conventional cache: parameterize fwd-buffer, fix
PartSplit=1`: `UseForwardingBuffer` is now a top-level parameter on
`insitu_cache_tcdm_wrapper`, threaded through `cachepool_cache_ctrl`. It is a
**1-entry write-back SRAM row cache** (`src/utilities/sram_forwarding_buffer.sv`;
an N-entry `_multi` variant exists): matching reads return buffer data
combinationally (SRAM read suppressed), matching writes merge, dirty data is
written back on address change. Part-aware when folded. Tunable
`EnableRawForwarding` / `EnableInflightWriteMerge`.

**Elaboration constraint** (`fbabd6a`, `608f54c`): `UseHashWaySelect=0` (LRU) is
legal **only** for the unfolded cache with the buffer off — i.e.
`fold OR fwd-buffer ⇒ hash-way=1`.

### 1.3 Correctness / verif fixes (low perf impact)

- `bab86f3` reserve one MSHR slot when `InfoStoreWidth` divides `CacheLineWidth`
  (per-line MSHR sub-entry capacity one fewer in that case).
- `4f41fd4` fix MSHR drain-count overflow.
- `2710920` tcdm_wrapper: break a grant-feedback comb loop (folded grant path).
- `8815d14` expose drain state via ports (observability; drops hier refs).
- sync-flush-fixes branch (`01763a4`, `efb42f2`, `eb4ae5c`, `2178e47`, `1365331`):
  cache-sync/flush FSM hardening — relevant only once the model implements flush
  (still the reserved `enable_flush` knob).

## 2. Model updates applied (this round)

### 2.1 `prompt/insitu_cache_architecture_v2.md`
- Header ⚠ note + new **§0.1** (config-selectable folded/hash/fwd table, the two
  supported configs, the `fold|fwd ⇒ hash` constraint, the forwarding-buffer
  description + perf role) and **§0.2** (RTL fixes since 2026-05-22).
- Corrected the §0 delta-table rows for `DataPartSplit` and `UseHashWaySelect`
  (production defaults, not unfolded/LRU) and added a forwarding-buffer row.

### 2.2 `core/models/cache/insitu/insitu_cache_config.py`
- New knob `use_forwarding_buffer` (default `True`; RTL constraint noted: requires
  hash-way). Its same-row-forward timing effect is folded into
  `hit_latency_cycles` for now (explicit model = Phase B).
- `use_hash_way_select` default flipped `False → True` (production).
- **`make_cachepool_512_config()` is now the production cache**: hash-way, folded
  (`refill_bank_write_cycles=2`, `folded_evict_penalty_cycles=3`), fwd-buffer on,
  `miss_penalty_cycles=7` (was 8 — the −1 offsets the folded `refill_bank_write`
  +1 so the calibrated cold-miss total is unchanged).
- New **`make_cachepool_512_conventional_config()`** = unfolded + LRU + no-fwd
  (the prior 2026-05-22 default; `refill_bank_write=1`, `miss_penalty=8`,
  `folded_evict=0`).
- `make_cachepool_512_legacy_config()` now also sets `use_forwarding_buffer=False`
  (predates the buffer).
- `make_cachepool_512_calib_config()` inherits production → matches the RTL calib
  DUT banner `PartSplit=4, Folded=1, Hash=1`.

### 2.3 `insitu_cache_controller.{py,cpp}`
- Publishes / reads `use_forwarding_buffer` (informational; logged in the
  instantiation trace).

## 3. Verification

- `make all TARGETS="insitu_cache_calib insitu_cache_microbench"` — clean.
- **Re-calibration under the production config holds exactly:**
  - Cold read-miss = **MemLatency + 17** at ML ∈ {10,50,100,200} → 27/67/117/217.
  - Warm read-hit isolated = **10** (ML-independent).
  - Cold-stream miss throughput = **0.0188 acc/cyc** @ ML50 (RTL 0.0181).
  The production switch is timing-equivalent to the prior conventional calibration
  for these traces (no evictions / no set conflicts), as expected.
- Microbench runs clean; numbers unchanged from the prior calibrated run (the
  patterns don't trigger evictions or set conflicts, so folded-evict / hash-vs-LRU
  don't bite, and `refill_bank_write 2 + miss_penalty 7 == 1 + 8`).

## 4. Not done (unchanged Phase-B backlog)

Topology refactor (single wide cache + input par-coalescer + scalar bypass-xbar),
explicit forwarding-buffer same-row-forward model, real flush FSM, write early-ack,
bounded miss accept-depth / true occupancy. See `prompt/insitu_cache_architecture_v2.md`
§11 and `prompt/insitu_cache_calib_report.md` §5.
