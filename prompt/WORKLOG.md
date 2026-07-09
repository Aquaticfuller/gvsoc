# GVSoC InSitu-Cache Model — Development Log

> Newest entries at top. Convention defined in `CLAUDE.md`
> §"Development log (for weekly reports)". Append on every meaningful
> change and **always** when committing (any submodule or the parent).
> Weekly reports (`prompt/weekly_report_<date>.md`) are assembled from this
> file + `git log`, not from memory.

---

## 2026-07-09 (cont'd 3) — CachePool v2: confirmed fdotp reaches EOC on the full 256-core topology too

**Status:** doc-only update (no code change).

- Ran `test-cachepool-fdotp-32b_M32768` on the real, default 256-core
  topology (no `CACHEPOOL_V2_*` debug env vars, `timeout 300`) for the
  first time since the §13.2.5 fix. Reaches EOC with no hang, in 250
  simulated cycles (128% utilization) -- far fewer than the 16-core debug
  topology's 6290 cycles, as expected with 16x the parallel work.
- Check still fails: `Calc:452.100891, Exp:628.153869`. This is a
  *different* miscalculated value than both the 16-core debug run
  (`350.577697`) and the pre-boot-hang-fix baseline in §13.1
  (`189.697906`) -- consistent with a genuine, distinct-per-topology
  numerical bug (§13.1), not an artifact of any of today's livelock fixes.
- This is the first time the model has run end-to-end on the real topology
  since the investigation began; re-investigating §13.1's numeric mismatch
  on this topology is the natural next step.

---

## 2026-07-09 (cont'd 2) — CachePool v2: Ara/AraVlsu completion-signaling bug fixed — fdotp reaches EOC for the first time

**Status:** uncommitted (`core` submodule — full detail in
`prompt/cachepool_v2_architecture.md` §13.2.5).

- Root-caused the "puzzling half" bug flagged at the end of §13.2.1 (and
  confirmed as the sole remaining blocker at the end of the previous entry).
  `[VLSU_DBG]` for the specific stuck core showed all 128 of its DENIED
  bursts had genuinely completed (matching RESPONSE lines, last one at
  `nb_pending_bursts_after=0`) thousands of cycles before the eventual
  stall -- so this was never a lost response.
- **Bug**: `AraVlsu::fsm_handler`'s (`core/models/cpu/iss/src/ara/
  spatz_vlsu.cpp`) check for whether the head-of-queue instruction can be
  marked done (and `ara.insn_end()` called) was nested inside
  `if (_this->pending_size) { ... }` -- i.e. it only ran while some other,
  newer instruction happened to still be mid-issue. Once every waiting
  instruction finished issuing (`pending_size` back to 0,
  `nb_waiting_insn==0`), that whole block stopped running, even though the
  head instruction's bursts had long since all completed asynchronously via
  `data_response()`. This permanently stranded the head instruction
  "done in practice, never marked done", head-of-line-blocking `Ara`'s
  global 8-slot queue forever.
- **Fixed**: moved the completion-check block out from under
  `if (_this->pending_size)` so it runs unconditionally every FSM
  invocation (gated only on its own pre-existing conditions). No other
  logic changed.
- **Verified**: rebuilt, reran the same bounded 16-core fdotp run. **The
  simulation reaches EOC for the first time in this entire investigation**
  (5755-cycle steady-state execution, 88% utilization). The result check
  still fails (`Calc:350.577697, Exp:628.153869`), but this is expected --
  the debug topology (16 cores) doesn't match the `Exp` reference value's
  assumed 256-core reduction. Re-running §13.1's numeric-mismatch item on
  the full 256-core topology, and re-verifying `fmatmul` (which very
  plausibly hit the identical bug), are the natural next steps.

---

## 2026-07-09 (cont'd) — CachePool v2: third root cause fixed (L1 NoC address-window aliasing); all memory-response-loss bugs eliminated; livelock now isolated to Ara/AraVlsu completion signaling

**Status:** uncommitted (`core`, `pulp` submodules — full detail in
`prompt/cachepool_v2_architecture.md` §13.2.4).

- Fixed the residual bug flagged at the end of the previous entry: `FlooNoc::get_entry()`
  (`pulp/floonoc/floonoc.cpp`/`.hpp`) only did a plain contiguous `base<=addr<base+size`
  range match, but `L1NocAddressConverter` leaves cacheline "tag" bits (above the
  group_id/bank_offset field) untouched, so incrementing tag by 1 shifts the address by
  exactly `num_groups × noc_size_per_group` — a whole period over every group's window.
  Added an optional `period` field to `Entry`/`get_entry()` (default 0 = old behavior) and
  plumbed it through `floonoc.py`'s `o_NARROW_MAP`; `cachepool_v2_cluster.py` now passes
  `period = nb_groups × noc_size_per_group` on every registered window, so every tag value
  resolves correctly instead of only tag==0. Also fixed a related boundary-clamp underflow
  in `NetworkQueue::enqueue_router_req` that the periodic case exposed (harmless for this
  workload's 4-byte bursts, but wrong in general).
- **Verified**: zero `NO_ENTRY_FOUND` drops (down from 8), simulation progresses further
  still (cycle ~2.76M → ~3.24M before stalling).
- **Conclusively isolated the remaining hang as NOT a memory/NoC bug.** At the new stall
  point, the stuck core's `AraVlsu` (`[VLSU_FSM_DBG]`) shows itself fully idle
  (`nb_waiting_insn=0, pending_size=0x0`) while `Ara`'s global instruction queue
  (`[ARA_DBG]`) is still stuck full (`nb_pending_insn=8`) on a head-of-queue entry that
  never gets marked done. This is the "puzzling half of the picture, not yet resolved"
  noted at the end of §13.2.1 — a desync between `AraVlsu`'s own local completion indices
  and `Ara`'s separate global scoreboard (`Ara::insn_end()` not firing, or firing on the
  wrong entry, for the stuck instruction). With memory-side noise now fully eliminated,
  this is the sole confirmed remaining blocker. Next step: audit `AraVlsu`'s three-index
  bookkeeping (`insn_first`/`insn_first_waiting`/`insn_last`) in `spatz_vlsu.cpp` against
  `Ara::insn_end()`'s call site in `ara.cpp` — see §13.2.4 for the precise pointer.

---

## 2026-07-09 — CachePool v2: two root causes of the "lost VLSU response" livelock found & fixed; residual narrower NoC address-window bug found (open)

**Status:** uncommitted (`core`, `pulp` submodules — full detail in
`prompt/cachepool_v2_architecture.md` §13.2.3).

- Rebuilt + reran `test-cachepool-fdotp-32b_M32768` on the 16-core debug
  topology (bounded via `timeout`, per §13.2.1's log-size gotcha) to confirm
  the §13.2.2 boot-hang fix still holds: cores now reach real program code
  past the bootrom, then hang at the already-documented vfmacc PC.
- Mined the existing (already-in-tree) `[VLSU_DBG]` ISSUE/RESPONSE log for one
  core: found every burst of the very first post-boot vector load returned
  `IO_REQ_DENIED` from cycle ~16457 on, with **zero** matching RESPONSE lines
  ever — that core's `AraVlsu` froze permanently right there.
- **Fix 1** (`core/models/cache/insitu/insitu_cache_controller.cpp`):
  `handle_request()`'s three fifo-full `IO_REQ_DENIED` sites (retr/miss/evic)
  are correct for the open-loop calib driver (which retries) but not for
  `inline_sync_miss_`/cluster mode, where `AraVlsu` treats any DENIED as
  "someone is holding this, ignore it" (true only for the FlooNoc NI's
  DENIED contract) and never retries — silently dropping the request. Added
  `admission_stall_queue_` + `try_admit_stalled()`: in `inline_sync_miss_`
  mode, park the request and return `PENDING` instead of `DENIED`; retry
  admission whenever a fifo slot frees. Verified real but **not** the cause
  of this particular trace (no change to the DENIED-storm log after this fix
  alone).
- **Fix 2** (actual cause of this trace) — `pulp/cachepool_v2/
  cachepool_v2_cluster.py`: added `[NI_DBG]` instrumentation to
  `pulp/floonoc/floonoc_network_interface.cpp` (raw `fprintf`, since
  `--trace=` is unusable at this scale per §13.2.1) and found the FlooNoc's
  `NetworkQueue::enqueue_router_req()` silently drops a burst (`return;`, no
  status, no `resp()` — there's even a dead `// TODO` for the never-
  implemented invalid-response path) whenever `FlooNoc::get_entry()` finds no
  address-range match. Root cause: `L1NocAddressConverter` only rearranges
  the low `constant_bits_lsb+bank_offset_bits+group_id_bits` bits and leaves
  bit 29 (the `0x8000_0000` vs `0xa000_0000` DRAM-region selector) untouched,
  but `cachepool_v2_cluster.py`'s `o_NARROW_MAP` registrations only ever
  covered `0x8000_0000`-based windows — so any cross-group request whose
  address was in `0xa000_0000+` (exactly where fdotp's source data lives)
  never found a routing entry. Fixed by mirroring the same per-group windows
  at `dram_base = 0xa0000000` (distinct `name=` per entry so both windows
  coexist).
- **Verified**: after both fixes, the same run completes its first ever
  DENY→RETRY_READ→FINAL_RESP round trip (previously zero completions in the
  whole run) and progresses ~170× further (cycle ~16464 → ~2.76M) before
  hitting the *already-documented* vfmacc/Ara-queue-full livelock from
  §13.2.1/§13.2.2 — i.e. this round's fixes cleared the earlier blocker;
  that livelock itself is still open.
- **Residual bug found, not fixed**: even with both fixes, 8 more
  `NO_ENTRY_FOUND` drops occurred at addresses whose "tag" bits (above the
  group_id/bank_offset field) are nonzero — the base+size contiguous-window
  match in `FlooNoc::get_entry()` only ever captures tag==0 per group; larger
  offsets either drop (same bug class) or could in principle numerically
  alias into a different group's window. Rare in this workload (8 events in
  ~2.76M cycles) but architecturally real; plausible contributor to whatever
  response-loss remains in the still-open vfmacc livelock. Flagged for next
  round — see §13.2.3's "Residual" note for the proposed fix direction
  (mask-based entry matching instead of contiguous windows).

---

## 2026-07-08/09 — CachePool v2: `pulp` rebased onto upstream/master; permanent-boot-hang root cause found & fixed (wrong Hierarchical_Interco port name); second hang localized to lost VLSU async responses (open)

**Status:** uncommitted (`pulp`, `core`, `engine` submodules — see full detail in
`prompt/cachepool_v2_architecture.md` §13.2.2, not duplicated here).

- Rebased `pulp` (`Aquaticfuller/gvsoc-pulp`) onto `gvsoc/gvsoc-pulp` `master`
  (55 commits, incl. the `SnitchMempool` core originally requested) — clean,
  no conflicts. `core`/`engine` untouched.
- Two pre-existing latent bugs (unrelated to the rebase, just never previously
  exercised) fixed to unblock the rebuild: `Hierarchical_Interco`'s always-
  constructed `Cache` sub-block segfaulting at small elaboration sizes
  (`pulp/mempool/l2_interconnect/hierarchical_interco.py`), and
  `Hierarchical_cache`'s per-tile icache sizing math going fractional/negative
  at `cores_per_tile < 2` (`pulp/mempool/hierarchical_cache.py`, worked around
  not fixed).
- Added a `CACHEPOOL_V2_NB_X_GROUPS`/`_NB_Y_GROUPS`/`_TILES_PER_GROUP`/
  `_CORES_PER_TILE` debug-topology override + bootrom BOOTDATA patcher to
  `cachepool_v2_system.py`, turning an 8+ minute repro into ~15s.
- **Root cause of the long-standing fdotp/matmul "silent hang" found**: every
  core was permanently stuck on the very first bootrom instruction. Traced
  through the ISS decode/fetch path, the generic GVSoC component-binding
  engine (`engine/engine/src/component.cpp`, `ports.cpp`), and the AXI router
  chain to a single wrong port name in `cachepool_v2_group.py` — bound a
  tile's AXI output to `Hierarchical_Interco`'s `'input'` port, but with the
  default `nb_slaves=1` it actually exposes `'input_0'`. The mismatch
  silently created an orphaned, never-connected placeholder port (GVSoC
  auto-creates one for any unrecognized "self"-referenced name rather than
  erroring), so every instruction fetch and L1 refill for every core got
  `IO_REQ_INVALID` forever, permanently caching a decode of "illegal
  instruction" at the reset vector. **Fixed.**
- Verified: post-fix, PC advances cleanly out of the bootrom and deep into
  real program code (millions of cycles, `fdotp` reaches `0x80002fc8`+).
- A **second, distinct hang** appears once boot completes, same general class
  as the previously-documented matmul `Ara`-queue livelock (§13.2.1): traced
  to `AraVlsu`'s per-port request-object pool permanently draining because
  some async burst's memory response never arrives, freezing `pending_size`
  and head-of-line-blocking `Ara`'s global 8-slot queue. Root location within
  the L1 FlooNoc/cache-bank chain not yet found — open.
- Operational notes worth remembering: the `gvsoc` CLI wrapper silently
  swallows the launched process's stdout/stderr — invoke
  `install/bin/gvsoc_launcher --config=gvsoc_config.json` directly instead;
  and `gvsoc_config.json` is never regenerated if it already exists (no
  staleness check), so `rm -f gvsoc_config.json` before every regen or you
  silently keep simulating stale topology/wiring.

## 2026-07-08 — CachePool v2: fdotp/matmul functional verification, two Ara/Spatz bugs fixed, matmul deadlock traced to Ara/AraVlsu queue desync (open)

**Status:** uncommitted (core submodule). Full detail in
`prompt/cachepool_v2_architecture.md` §13.1–§13.2.1 (kept current, not
duplicated here).

**Context:** verifying the CachePool v2 build/run flow works end-to-end on
`fdotp-32b_M32768` and `fmatmul-32b_M32_N32_K32`. fdotp's `result[64]`→`result[256]`
array-size bug (software, ManyRVData) was fixed upstream by the user; re-ran
and found a *different*, still-open numeric mismatch (`Calc:189.697906` vs
`Exp:628.153869`, ratio ≈0.302). Root cause not yet identified — ruled out
the two bugs fixed below (bit-for-bit identical fdotp output before/after).

**Two real bugs found and fixed** (both in `core/models/cpu/iss/src/`, per
the user's out-of-order-memory hypothesis — CachePool's NUMA/cache paths
return `IO_REQ_PENDING`/`IO_REQ_DENIED` far more than the flat
standalone-Spatz testbench this model was originally validated against):
1. `spatz/fpu_sequencer.cpp:101-109` (`Sequencer::float_handler`) — missing
   `nb_out_reg` offset when indexing `args[]` for the FREG-input hazard
   check, so e.g. `flw`'s single OUTPUT arg's flags got checked instead of
   its INPUT arg's, and the wrong (aliased) scoreboard slot got queried.
2. `ara/spatz_vlsu.cpp` (`AraVlsu::fsm_handler`) — `ara.insn_commit()` was
   called unconditionally at burst-issue time, even for async
   `IO_REQ_PENDING`/`IO_REQ_DENIED` responses, prematurely signalling
   vector-chaining consumers that data was ready before `data_response()`
   had actually written it. Deferred the async case's commit into
   `data_response()` (2 extra IoReq arg slots pushed, 4 total for AraVlsu,
   10/16 of the documented budget — still safe).

**Verification:** rebuilt clean; both fixes confirmed to have **zero**
observable effect on fdotp (bit-for-bit identical output) and **zero**
effect on the matmul hang's onset cycle (still hangs at the same
`pc=0x800007b0`, same cycle 6197, before and after). Real bugs, not the
cause of either symptom.

**matmul hang (was a crash, now a livelock/deadlock, still open):** the
`spatz_lane_width=8`→`4` fix from a previous session stopped the
`IO_REQ_INVALID` abort, but running `fmatmul-32b_M32_N32_K32` now hangs
forever instead. Traced (via targeted rate-limited `fprintf` instrumentation
— `--trace-level=trace` was unusably slow, hanging elaboration itself for
10-15s with zero output even scoped narrowly) to: `Ara`'s shared 8-slot
`pending_insns[]` queue gets permanently stuck full from cycle ~6092, head
instruction `vle32.v v20, (t2)` (`pc=0x800007cc`) never marked `done`,
head-of-line-blocking all subsequent vector instructions via
`vector_insn_stub_handler`'s `queue_is_full()` gate. `AraVlsu`'s own local
bookkeeping (`nb_waiting_insn`, `pending_size`) looks idle throughout the
hang, suggesting a desync between `AraVlsu`'s three internal indices
(`insn_first`, `insn_first_waiting`, `insn_last`) and `Ara`'s single global
`insn_first` / `insn_end()` completion signal. Not yet pinned to an exact
line — next step is a careful read of `AraVlsu::fsm_handler`'s bottom
completion check against `Ara::insn_end`, not more instrumentation.

**Debug instrumentation left in tree** (gated/rate-limited, harmless, not
yet cleaned up): `spatz_vlsu.cpp` (`[VLSU_DBG]`, `[VLSU_WAIT_DBG]`,
`[VLSU_BURST_DBG]`), `ara.cpp` (`[ARA_DBG]`), `snitch.cpp` (`[STUB_DBG]`).
Strip once the real fix lands.

**Operational note:** matmul runs must be wall-clock-bounded
(`timeout ≤30s`) — a hung run's default per-cycle trace spam produces
multi-GB logs in seconds. Two separate accidental multi-GB logs were
generated and deleted during this session.

---

## 2026-06-16 — Structural rewrite kickoff: master plan + Step 1 (decode/encode datapath)

**Direction (user):** implement EVERY microarch/arch component with the REAL RTL logic (not the
cycle-approximate latency knobs), THEN calibrate. So the build-time gate is now functional correctness
+ structural fidelity; performance calibration is a final pass. Keep the existing calibrated model as a
selectable parallel fallback (switch only at the cluster integration boundary).

**Master plan:** `prompt/insitu_cache_structural_plan_2026-06-16.md` (from a 10-agent workflow:
8 RTL-port readers → synth → adversarial review = SOUND-WITH-FIXES). 7-component, dependency-ordered
build: Step0 scaffold → **Step1 decode/encode** → Step2 bank array → Step3 fwd buffer → Step4 cache core
→ Step5 par_coalescer → Step6 xbar/bypass/SPM/sync → Step7 system composite (+DRAMSys DDR4 on refill).
Review must-fixes folded into the plan: (1) the structural core MUST keep a **synchronous-slave mode**
(run the per-cycle FSM internally, return OK inline) for the cluster — same constraint inline_sync_miss
solves; (2) validate by diffing per-access data/latency vs the RTL reference dataset, not the RTL SV
scoreboard; (3) reuse insitu_calib_mem as the Step-4 refill responder; (4) resolve FIFO depths / MRP /
BankFactor from cachepool_cache_ctrl.sv before Step 4. (The refill-evict-fsm reader hit a transient API
error — re-read cachepool_cache_ctrl.sv directly at Step 4.)

**Step 1 DONE:** `core/models/cache/insitu/insitu_cache_decode.hpp` (committed) — a header-only,
RTL-faithful transcription of `insitu_cache_decoder.sv` + `insitu_cache_encoder.sv`: address decode,
the real **hash-way = lowtag^lowset** (replaces the model's Knuth-hash approximation), the SOP
hit/hit_pend/hit_conflit/all_pend classify (status bit-encoding INVALID=0/VALID=1/READ_PEND=2/
WRITE_PEND=3), the full-assoc LRU victim (first-credit-0 / min-LRU), the encoder LRU-credit update
(max_lru_credit = #VALID|INVALID ways; allocate→ways-1, complete→mlc, MRU-bump), and masked byte merge.
Pure logic, no ports/events; used by the Step-4 core. Validated standalone (g++ self-test, all checks
pass); not yet referenced by any compiled target → zero build impact.

**Step 2 DONE:** `insitu_cache_bank_array.hpp` (core `d6d244b8`) — RTL-faithful pseudo-dual-port bank model
(transcribes `pseudo_dual_port_tcdm_wrapper` + `pseudo_dual_port_bank.sv` + `folded_data_bank.sv`): the
6-state R-vs-W classify, `bank_select = low log2(BankFactor) bits of the set/row`, and the **WR_CONFLICT
penalty via a PER-CYCLE write scoreboard** (a read to the same way + same bank-select + different row
that a write took this cycle → retry next cycle, +1) — the structural replacement for `set_busy_until_`.
Ways are independent SRAMs (no cross-way conflict); same-row = WR_SAME_ADDR forward (no penalty); SRAM
read latency=1. Validated standalone (classify + scoreboard + per-cycle reset all pass); header, zero
build impact.

**Step 4 DONE (first runnable):** `insitu_cache_core.{cpp,py}` (core `07203629`) — the RTL-faithful
STRUCTURAL cache core: a per-cycle ClockEvent FSM (2-stage pipeline: stage-0 arbitrate {request,
refill} → preread reg; stage-1 decode+FSM+one bank write+output drain) consuming Step-1 decode +
Step-2 bank. REQ_PROC: read-hit / write-hit / read-hit-pend (in-situ MSHR append) / miss-allocate /
victim dirty-writeback; single-outstanding refill install + drain of all queued readers; bank
WR_CONFLICT → read retries next tick; functional data path. **Latency EMERGES from pipeline cycles**
(not knobs) — calibration deferred. Gated by `InsituCacheTileConfig.use_structural_core` (default
False → the calibrated controller, byte-identical: default-off fmatmul mean-Δ 3.9 confirmed); the tile
swaps InsituCacheCore for InsituCacheController when set. Open-loop/async ONLY (the cluster keeps the
controller until the synchronous-slave inline mode lands). **Validated:** compiles; runs synthetic
(cold_miss/warm_stream/raw/cold_stream) + the real single-tile fmatmul t0c0 (5488 acc) with
**data_err=0**, no hangs. **Concurrency fidelity fix (core `05e856b2`):** replaced the 1-deep input
buffer with a bounded streaming accept queue (~NumSpatzOutstandingLoads=32) — `max_outstanding` now
tracks the budget (3 → 34 on fmatmul t0c0, 32 on cold_stream), data_err=0. KNOWN/deferred: per-access
latency still over-predicts (fmatmul t0c0 ~251 vs RTL ~18) = single-outstanding-refill serialization +
the open-loop replay-backpressure double-count (the `per_cycle_arb`/fix-#5 effect) → the CALIBRATION
phase. New config knobs: `bank_factor` (RTL L1BankFactor=2), `use_structural_core`. Open: Steps 3/5/6/7
(fwd-buffer FSM, real par_coalescer, xbar/SPM/sync, composite + DDR4) + the cluster sync mode + the
core timing-calibration pass.

---

## 2026-06-16 ~03:00 +0200 — Miss-path diagnosis vs the new single-tile RTL reference (no code change)

**Status:** diagnosis only (a temp `enable_multi_read_pend=True` experiment was run and **reverted** —
zero effect; tree clean at P2-inc1). RTL reference received from the RTL side:
`ManyRVData_rebase/reports/cache_calib/rtl_ref_1t_2026-06-16/` (single-tile 4-core, Burst=4; closed-loop
mem = DRAMSys DDR4-1866, NOT MemLatency=50; per-access CSVs at ML=50 = open-loop reference).

**What.** Open-loop per-access replay of 5 single-tile kernels (idotp/fmatmul/fft/fdotp/gemv) through the
calib model, diffed vs the new RTL `.rtl.csv`. Hit path faithful (+0.2…+7.5 cy); **miss path
over-predicts +17…+80 cy under deep saturation** (these are memory-bound; RTL per-miss latency up to
330 cy). **Root-caused to the `max_outstanding` gap (calib_report §13):** GVSoC bounds outstanding by
the per-port requester budget (4 VLSU × 32 = **128**) vs RTL's cache-internal cap (~**56**) → ~2× deeper
queue → flat +40…+80 cy. NOT multi-read-pend (flipping it, verified live in the dumped config, had zero
effect — queue is budget-bounded, not retr_fifo-bounded). The over-prediction is flat across the trace
(steady-state queue depth, not an unbounded backup); `max_outstanding=128` confirmed in CALIB_REPORT.

**Why hard:** capping outstanding at ~56 regresses the matched synthetic miss-throughput (coal_cold/
cold_stream/evict) — the §13 coupled/NO-GO result. And the open-loop saturated latency likely
over-states the error that matters: the real metric (closed-loop cycle count) is throughput-driven, and
throughput IS matched (≤7%).

**Recommendation (in `prompt/insitu_cache_misspath_diagnosis_2026-06-16.md`):** don't chase the open-loop
saturation latency in isolation; validate **closed-loop** `region_cyc` vs the §D RTL table (needs DDR4
DRAMSys on the refill path + single-tile topology + dynamic_offset≈6 + the RTL ELFs). Only model the
per-resource MSHR cap (P3) if closed-loop cycles are off in a way attributable to outstanding depth — in
which case ask the RTL side for per-kernel `max_outstanding` to set the cap precisely.

---

## 2026-06-15 20:59 +0200 — Phase-2 increment 1: per-core controller cardinality (gated, default-off)

**Status:** committed — core `d821214b`, pulp `b88f878` (pushed force-with-lease to forks); parent
pointer bumped locally. First Phase-2 (topology) step. Approach from a 3-strategy design workflow +
adversarial review (verdict GO-WITH-FIXES); chose Strategy 1 (per-core cardinality first).

**Why pivot from Phase-1 front-end increments:** after inc1 (par_coalescer), the remaining P1
front-end micro-steps were found to be open-loop-neutral and/or topology-entangled (response-split is
a no-op since the RTL splits in ~1 cyc; scalar-bypass/single-wide need the per-core structure;
miss-coalesce duplicates the controller MSHR). The design workflow verified the model's address
routing is ALREADY RTL-faithful, and the model is wrong in two separable ways: (1) cardinality
(num_controllers fixed at 4 vs RTL one-cache-per-core), (2) one monolithic arbitration domain vs RTL's
per-port-class xbars. Phase-2 fixes these and unlocks closed-loop cycle comparison (the real goal).

**What (inc1).** `InsituCacheTileConfig.controllers_track_cores` (default **False**). When on, the
cluster site (`snitch_cluster.py`) sets `num_controllers = nb_core` — one L1 cache per core (RTL
`NumL1CacheCtrl = NumCores`, `cachepool_pkg.sv:121`), instead of the factory's fixed 4. Power-of-two
`nb_core` asserted (the interco routes by `(addr>>dynamic_offset)&(num_outputs-1)`). No `.cpp` change —
routing/wide-split/tile-loop already handle `num_outputs>1` generically.

**Files:** core `models/cache/insitu/insitu_cache_config.py` (flag field); pulp
`pulp/snitch/snitch_cluster/snitch_cluster.py` (set num_controllers when flag on, power-of-two guard).

**Verification (full build+install):**
- Default-off (committed): fmatmul-M32 3.9, coal_cold 0.4961, vfadd 15/15 cyc=58001 — byte-identical
  (calib uses a separate single-controller factory; flag read only at the cluster site).
- Flag-on @nb_core=2 (temp flip in the production factory, then reverted): interco elaborates
  **N=10 M=2** (2 per-core controllers, `ctrl_0`+`ctrl_1`), vfadd **retval=0** (passes). Cycle count
  unchanged at 58001 because vfadd isn't bank-contention-bound — a correctness test, not a
  discriminating benchmark; the topology effect needs a contention kernel + the RTL reference.

**Caveats / follow-ups:** per-controller capacity is NOT yet RTL-scaled (total tile capacity tracks
controller count) → Phase-2 inc3. The diffable closed-loop number needs (a) the per-port-class xbars
(inc2), (b) capacity scaling (inc3), and (c) an **RTL single-tile reference cycle count** (`cachepool_1t.mk`,
BurstLength=4 regime) — which requires an RTL sim run (outside this environment; flagged as inc0, a
user/RTL-sim task). Structure map: `prompt/insitu_cache_structure_map_2026-06-15c.md`.

---

## 2026-06-15 20:22 +0200 — Phase-1 increment 1: structural par_coalescer (gated, default-off)

**Status:** committed — core `040fdef3` (pushed force-with-lease to fork); parent pointer bumped
locally. First implementation step of the dev-plan Phase 1 (structural per-core cache refactor).
Approach chosen via a 3-strategy design workflow + adversarial calibration/Spatz-safety review; user
picked "build P1 at the par_coalescer."

**What.** Added `InsituCacheParCoalescer` (`insitu_cache_par_coalescer.{cpp,py}`) — a standalone
per-controller front-end that is the structural extraction of the interco's inline
`enable_input_coalesce` window: same-cycle/same-line read merge (followers inherit the leader's warm-
hit latency, return OK, no re-forward, no accept slot) + output-accept arbitration + interco_latency.
Gated by `InsituCacheTileConfig.use_structural_coalescer` (default **False**). When on, the interco
becomes a pure address router via a new `defer_to_coalescer` flag (skips merge+arb+latency, just
routes), and the tile inserts one par_coalescer between each interco output and its controller.

**Why this placement.** The merge and the output-arb must move *together* (a merged follower must not
consume an interco accept slot); so the interco's per-output body was relocated wholesale into the
coalescer, fed by a route-only interco — reproducing the calibrated numbers by construction.

**Files:** core `models/cache/insitu/`: `insitu_cache_par_coalescer.{cpp,py}` (new),
`insitu_cache_interco.{cpp,py}` (defer_to_coalescer router gate), `insitu_cache_config.py`
(`InsituCacheParCoalescerConfig` + tile `use_structural_coalescer` + interco `defer_to_coalescer`),
`insitu_cache_tile.py` (structural wiring). No pulp change.

**Verification (full build+install of calib + spatz):**
- Default-off (committed): fmatmul-M32 mean-Δ **3.9**, coal_cold wide@ML50 **0.4961**, vfadd **15/15
  cyc=58001** — byte-identical (interco path unchanged; component not instantiated).
- Structural-on (temp flip in calib, then reverted): **all 19 calib traces' per-access latency
  byte-IDENTICAL** to the default interco-merge path (verified by CSV diff; incl. the coal_warm
  same-line VLSU tail = 124×7-cyc + 4×10-cyc merged hits). Proves the extraction is faithful — the
  par_coalescer merge == the interco merge, exactly.

**Open-loop payoff:** none expected, and none seen — by design (the dominant residual is already
fixed/inherent; see the design-workflow finding). The value is *structural foundation* for the
remaining Phase-1 increments and eventual closed-loop fidelity. Structure map:
`prompt/insitu_cache_structure_map_2026-06-15b.md`. Plan: `prompt/insitu_cache_dev_plan_2026-06-15.md`.

---

## 2026-06-15 (later) — RTL deep-read: microarch/arch reference rewrite + gap analysis + dev plan

**What.** Did a complete, verified deep read of the CachePool InSitu cache RTL (IP + cachepool
integration, ~22k lines) and produced three docs. Driven by a 15-agent workflow (10 parallel RTL/
model readers → 3 synthesis agents → 2 adversarial verifiers that re-checked claims against source;
both verifiers returned **high accuracy**). No code changed — docs only.

**Files (prompt/):**
- `insitu_cache_architecture_v2.md` — **rewritten** (471→635 lines) as the authoritative RTL
  microarchitecture+architecture reference. Tracked file (shows `M`); old version recoverable via git.
  Added §0.1 "Verified resolutions" capturing the 8 fact-check corrections (WordWidth=32 active not 64;
  L1BankFactor=2 hardcoded; config-512 geometry 1024/256/128/64KiB; refill burst is a line-width effect
  at fixed 128b refill, committed=Burst4 vs uncommitted-working-tree Burst1; dynamic_offset FF reset=14
  vs CSR resval=0; tcdm_id_remapper unused in CachePool; pseudo_dual modules live inside the wrapper;
  cache_sync_insn has 4 modes).
- `insitu_cache_rtl_coverage_matrix.md` — **replaced** (was 2026-06-08; old backed up to
  /tmp/coverage_matrix_2026-06-08.bak) with the RTL-vs-GVSoC gap analysis (arch + microarch + full
  matrix). Untracked.
- `insitu_cache_dev_plan_2026-06-15.md` — **new** phased GVSoC dev plan (Phase 0 done → Phase 1
  structural per-core controller + par_coalescer + bypass → Phase 2 Tile/Group shared-bank substrate →
  Phase 3 caps → Phase 4 SPM+flush/sync → Phase 5 AMO → Phase 6 bank-conflict → Phase 7 async-Spatz).
  Untracked. Applied the verifier fix: Phase 0 re-scoped to **DONE** (closed-loop hang already fixed/
  committed core 3d712809/pulp d8abb08; vfadd 15/15), residual closed-loop gaps reassigned to Phase 4
  (DMA/flush) + Phase 2 (topology); resp/wt-FIFO "quick win" reworded (counters not yet wired).

**Key RTL facts now documented (corrected understanding):** Group(4 tiles)→Tile(4 CC + 4 per-core L1
ctrls)→CC; NumL1CacheCtrl=NumCores (one cache/core), fully-shared L1 via per-lane tcdm_cache_interco +
remote ports + inter-tile xbar with register-programmable mapping + runtime bank partitioning; per-core
ctrl = single wide-line cache + par_coalescer (equal-window CSHR, hitmap, last-writer-wins wide merge,
rsp_spliter) + 2:1 scalar bypass reqrsp_xbar + 4-beat refill burst FSM; 7-state core FSM; 7-state
flush/sync FSM (4 cache_sync opcodes, CheckPendDrainCycles=20); the GVSoC model is structurally v1
(4 address-interleaved ctrls + hashed interco) and matches none of the shared-L1 substrate → Phase B.

**Memory:** [[rtl-integrated-topology]] updated to point at these docs. No commit (docs; per the
docs-stay-local convention). Related: [[insitu-cache-closedloop-state]].

---

## 2026-06-15 14:17 +0200 — Closed-loop Spatz bring-up: cache runs vfadd end-to-end; open-loop regression fixed

**Status:** committed — core `3d712809`, pulp `d8abb08` (pushed force-with-lease to forks;
parent pointer bumped locally, not pushed). Files: core `models/cache/insitu/{insitu_cache_controller.cpp,
insitu_cache_controller.py,insitu_cache_interco.cpp,insitu_cache_config.py,insitu_cache_tile.py}`,
pulp `pulp/snitch/snitch_cluster/snitch_cluster.py`.

**What.** Made the InSitu cache work CLOSED-LOOP on `--target=spatz --target-property
use_insitu_cache=True` — `examples/spatz/test-riscvTests-vfadd` now PASSES all 15 TCs
(`retval=0, cycles=58001`), where it previously hung at boot.

**Why it hung (4-bug cascade, all fixed; gated to the cluster config):**
1. *No data modelling* — cache was a pure timing overlay; every load returned garbage → program
   derailed into a bogus HTIF syscall (router livelock). Added per-line `line_data_` flat store +
   `exchange_line_data()` (serve reads / apply writes / install refills), all gated behind
   `carry_data_ = inline_sync_miss_ || functional_writethrough_`.
2. *Write-back invisible to HTIF backdoor* — `functional_writethrough`: every write also pushes its
   real bytes straight to backing memory (via the evict port) so the ISS/HTIF backdoor reader sees
   them.
3. *Refill-address rewrite deadlock* — `wide_axi` rewrites the refill req addr in place
   (subtract remove_offset); `refill_resp_handler` re-decoded set/tag from the mutated addr → never
   matched the pending line → MSHR never drained. Fixed: stash `pending_refill_addr_`.
4. *LSU synchronous-slave protocol* — spatz uses the **v1 ISS** (`iss/`, NB_OUTSTANDING off); all 3
   snitch LSUs accept only synchronous `IO_REQ_OK` (PENDING/DENIED fatal; re-entrant resp() aborts).
   `inline_sync_miss`: misses that resolve synchronously complete INLINE (return OK like a hit, no
   park/resp); write-commit backpressure → ADDED LATENCY instead of DENIED.

**The actual data bug (not DMA/flush):** wide-access spanning. The interco interleaves controllers
at 4-byte granularity (`dynamic_offset=2`, bits[3:2] WITHIN the line), so an 8-byte memcpy store
routed wholesale to ctrl0 left ctrl1's copy of the upper word stale. Fix: interco now SPLITS an
access crossing the granule, routing each byte-range to its owning controller (gated
`num_outputs_>1` → calib with `num_outputs=1` is byte-identical). vfadd is cache-unaware, so the
split alone fixes it. A flush/invalidate (`flush_all()` + `i_FLUSH` ports, tile `i_FLUSH(ctrl)`) is
implemented cache-side but DORMANT (not wired to the cluster L1D peripheral) — kept for future
cache-aware DMA-staging kernels.

**Open-loop regression — ROOT-CAUSED & FIXED (this was the commit blocker).** The uncommitted work
regressed calib (fmatmul M32 +3.9→+7.5, coal_cold 0.4961→0.6531) deterministically. Cause:
`make_cachepool_512_config()` (the shared base factory) set `inline_sync_miss=True` /
`functional_writethrough=True`, and the open-loop calib config DERIVES from it
(`make_cachepool_512_calib_config()` → `cfg = make_cachepool_512_config()`), inheriting the flags.
With `inline_sync_miss=True` the calib miss path took the inline-completion branch that stamps
`refill_lat` directly and never calls `reserve_install_pipe`, so the `defer_refills` occupancy
serialization (§10) was bypassed → miss throughput/latency inflated to the pre-occupancy numbers.
(The earlier inspection-bisect was blind because the *installed* `.py` under `install/generators/`
was never refreshed during quick `.so`-only rebuilds — the run always saw the stale True flags.)
**Fix (Option B):** the two flags are DRIVER/integration flags, not cache geometry — removed them
from the base factory (left at field default False, so calib/conventional/legacy all inherit the
calibrated path) and set them explicitly at the closed-loop cluster site (`snitch_cluster.py`,
which always needs them: the LSU protocol requires a synchronous slave + functional coherence).

**Verification (clean full build `make all TARGETS="insitu_cache_calib spatz:use_insitu_cache=True"`):**
- Open-loop calib: fmatmul M32 mean Δ **3.9** (hit +3.3), coal_cold wide @ML50 **0.4961** — both
  exactly the fix #5 targets.
- Closed-loop: vfadd all 15 TCs PASSED, `retval=0 cycles=58001`.
- No temp diagnostics left in the C++; `defer_refills=False` (Spatz default) path untouched.

Related: `prompt/insitu_cache_calib_report.md §10` (occupancy model), `[[insitu-cache-closedloop-state]]`,
`[[insitu-cache-gap-state]]`. Open follow-up: closed-loop cycle comparison vs RTL needs geometry
reconciliation (GVSoC spatz ≈ 4-core vs RTL 16-core CachePool traces).

---

## 2026-06-13 (later) — Phase-B fix #5: per-cycle output arbitration (THE hit-latency lever)

**Status:** committed — core `6362b3da`, pulp `f0706bc` (local; not yet pushed). This is the
big real-kernel alignment result: it closes 85–97% of the per-access latency gap on 4 of 5
kernels. Driven by taking the §6 "fix the hit-path serialization" item.

**Diagnosis.** A latency-component discriminator (env-gate each queue-wait term, re-measure fft —
whose misses align so shared paths are isolable) pinned the residual on the **interco output
arbitration**, NOT the per-set bank: removing the bank wait moved fft by 0.1 cy; removing the
output wait collapsed it +36.7 → +3.9. This overturned the prior abstract hypothesis (set_busy)
*and* the §8 "gemv is inherent cascade" conclusion.

**Root cause.** `output_busy_until_` was a monotonic per-output busy-until cyclestamp — it
accumulates across cycles, modelling sustained 1/cyc backpressure. Correct for CLOSED-LOOP (Spatz:
the core stalls on the returned latency) but DOUBLE-COUNTS in open-loop replay, where the trace's
t_issue already encodes the RTL's cross-cycle backpressure → ~+33 cy phantom hit inflation.

**Fix.** New `per_cycle_output_arb` interco mode: reset the accept counter each cycle, serialize
only genuinely same-cycle requests (`output_accept_width`/cyc, default 1). Mode tracks the trace's
**injection semantics**: default accumulate (Spatz + max-rate synthetic phases that rely on
accumulate backpressure for saturated throughput); per-cycle for real-kernel replay (opt-in via
`INSITU_CALIB_PER_CYCLE_ARB=1`, set by the replay tool).

**Result (clean sequential before→after, mean Δ vs RTL):** fmatmul M32 26.5→**3.9**, fft 34.6→
**3.2**, fmatmul M128 62.7→**6.4**, gemv 76.1→**2.6**, fdotp 75.0→**21.1**. Hit Δ now +0.3…+4.5
on EVERY kernel. fdotp's hit path is exact (+0.3); its whole residual is the miss-path cascade
(+62.7, unchanged) = the inherent open-loop limit. gemv → +2.6 proves it was a model defect, not
inherent.

**No regression.** Accumulate `else`-branch is byte-identical to the original → synthetic phases
(coal_cold 0.4961, evict 0.1659, warm_hit 10, cold_miss 67) and closed-loop microbench (7 lines:
3.88/3.73/1.98/3.70/3.73/2.05/3.73) provably unchanged (they never set the env knob).

**Methodology note.** gvsoc writes `gvsoc_config.json` into the cwd, so concurrent replay
processes sharing one cwd race on it (±0.3 cy nondeterminism). All numbers from strictly
sequential runs (verified reproducible).

**Files.** core `6362b3da`: `insitu_cache_config.py` (+per_cycle_output_arb, +output_accept_width;
calib config left at default + comment), `insitu_cache_interco.{cpp,py}` (two-mode arbitration).
pulp `f0706bc`: `insitu_cache_calib/__init__.py` (env knob). parent:
`insitu_cache_realkernel_alignment_2026-06-12.md` §9 + §8 NB + resolution banner, this log,
`weekly_report_2026-06-15.md`.

---

## 2026-06-13 — Phase-B fix #4 (scalar bypass) + fix #2 (same-cycle MSHR-drain coalescing)

**Status:** committed in `core` `49c377d9` (continuation of the real-kernel alignment work; fix #1
was pushed earlier as `37982db9`). Both are RTL-faithful refinements with marginal real-trace
impact; the dominant gemv/fdotp residual remains the open-loop refill cascade (not a cache-model
fix — see `insitu_cache_realkernel_alignment_2026-06-12.md` §6/§8).

**Fix #4 (APPLIED) — scalar bypass port.** The Snitch scalar request goes through the RTL 2:1
`reqrsp_xbar`, not the VLSU coalescer: a read hit returns ~3 cy and doesn't contend for the per-set
bank. New `controller.scalar_bypass_port` / `scalar_hit_latency_cycles`, fed by an
`interco.forward_initiator` knob that tags each forwarded req with its input-port index (via
`IoReq::set_initiator(int)`, V1 io.hpp). All three default OFF → Spatz path byte-identical; calib
DUT sets port=4, latency=3. Trims the scalar-port Δ but it's a minor fraction of each kernel mean.

**Fix #2 (APPLIED) — same-cycle MSHR-drain coalescing.** The `par_coalescer` merges same-cycle
same-line reads into one entry, so they retire together. `fsm_drain_mshr` now advances the
per-subarray stagger only when a pending reader's `arrival_cycle` differs from the previous one,
not once per reader. Correct RTL behaviour but **zero measured impact** on these traces (few
same-cycle same-line readers survive to the drain). Kept as a harmless refinement.

**Result (mean per-access latency Δ vs RTL):** fmatmul M32 +27.0→**+26.5**, fft +34.7→**+34.6**,
fdotp +75.0 (flat), gemv +76.1 (flat). **Synthetic regression fully unchanged** — microbench 7
lines, cold_stream wide 0.254, evict wide 0.166, warm_stream 7/7, coal_cold 0.496, warm_hit 10,
cold_miss 67.

**Files.** core (`49c377d9`): `insitu_cache_config.py` (+scalar_bypass_port, +scalar_hit_latency_cycles,
+interco.forward_initiator; calib config wires port=4/lat=3), `insitu_cache_controller.{py,cpp}`
(is_scalar branch + arrival-cycle-aware drain stagger), `insitu_cache_interco.{py,cpp}`
(forward_initiator tagging). parent: `insitu_cache_realkernel_alignment_2026-06-12.md` §8, this log.

---

## 2026-06-08 (later) — Phase-B fix #1: pipelined-bank set_busy (real-kernel hit-inflation)

**Status:** fix #1 implemented + verified (ready to commit). Fix #3 attempted + reverted. Fixes
#2/#4 scoped. Driven by the real-kernel alignment finding (`insitu_cache_realkernel_alignment_2026-06-12.md`).

**Fix #1 (APPLIED) — `bank_accept_cycles` (default 1).** The per-set `set_busy_until_` stamp now
advances by the bank ACCEPT interval (pipelined, 1 cyc) instead of the full hit latency, so
back-to-back accesses to a hot/reused set pipeline rather than serialize. This was the #1 cause of
the real-kernel per-access latency over-prediction (hot-set serialization on multi-port reuse).
Result: meanΔ vs RTL — fmatmul M32 +61→**+27**, fft +73→**+35**, fmatmul M128 +85→**+63** (big
wins); gemv +77→+76 (neutral); fdotp +71→+75 (slight). **Synthetic calib + microbench fully
unchanged** (the stamp only fires under same-set contention, which the synthetic distinct-set/
coalesced phases avoid) — warm hit 10, streaming 7, cold-miss ML+17/+13, cold_stream 0.254,
coal_cold 0.496, coal_warm 3.37, microbench 7 lines identical. So fix #1 is a strict improvement
with no regression.

**Fix #3 (single-outstanding-refill backpressure) — ATTEMPTED, REVERTED.** A cache-side gate
(DENY a new miss while a refill is outstanding) backfired (gemv/fdotp miss latency +400-600).
Root cause: the gate stalls misses but not hits, so a replayed hit to a not-yet-refilled line
runs ahead and waits — but in the RTL the *core* stalled on that line's miss. **Open-loop trace
replay can't reproduce the core's data-dependency stall when the cache's miss-timing differs.**
Same wall as the coal_cold deferred-completion NO-GO. Machinery removed.

**Fixes #2/#4 scoped** (structural coalescer, scalar bypass) — secondary; neither addresses the
gemv/fdotp refill-cascade residual (which is partly inherent to open-loop replay). Left as clean
follow-ups.

**Files.** core: `insitu_cache_config.py` (+bank_accept_cycles), `insitu_cache_controller.{py,cpp}`
(pipelined set_busy). pulp: `insitu_cache_calib/__init__.py` (INSITU_CALIB_COALESCE_MAX_LAT debug
knob from the discriminator). parent: `insitu_cache_realkernel_alignment_2026-06-12.md` §8.

---

## 2026-06-08 (later) — Alignment check vs RTL run_2026-06-12 → ALIGNED-CONFIRMED

**Status:** assessment only (doc update: calib report §14). No code change.

**What.** Verified the model still works post-upstream-pull and re-checked alignment against the
latest RTL reference `ManyRVData_rebase/reports/cache_calib/run_2026-06-12` (BurstLength=1, DUT
`93d1c11`). Model smoke + full wide-mode sweep ran clean. The RTL run's REPORT.md states it is
**cycle-identical to the Jun-3 char_bl1 baseline (0 mismatches, 20 phases × 4 ML)** — the RTL
timing-opt batch is performance-neutral, so the reference is unchanged from the calibration
baseline; this is a post-pull re-confirmation.

**Result — ALIGNED-CONFIRMED** (independent GVSoC re-measure + RTL re-parse + adversarial audit,
workflow `wwvh8r7bx`, 3 agents). Every number reproduced exactly on both sides. Throughputs +
headline latencies match within tolerance: warm hit 10, streaming 7, write 8, RAW 7, cold-miss
ML+13 exact across the sweep; coal_warm 3.37 vs 3.28; coal_cold thr ≤6.2% across the full ML
sweep; cold_stream ≤10% (L≥50); evict ~6%; memory traffic matches. All divergences are the
**pre-documented residuals** (saturation hit ceiling, coal_cold latency/out shape, evict out +
write-allocate latency, cold_stream low-ML plateau) — **none introduced by the 2026-06-08 pull**
(calib byte-identical). Coverage gaps (no model issue): `bw_hit_1/2/3port`, `mshr_depth_1p` have
no GVSoC trace. Audit nits (cosmetic): a "≤6%" bucket header understated 4 cells (in-line figures
correct); CLAUDE.md's ML+17 cold-miss headline is the Burst=4 default (Burst=1 here is ML+13, as
the calib report already notes). Full table: calib report §14.

**Files.** `prompt/insitu_cache_calib_report.md` (§14), `prompt/WORKLOG.md`.

---

## 2026-06-08 — Pull upstream: rebase dev branches + engine bump + elfutils build dep

**Status:** rebased + build-verified + parent committed locally + **dev branches pushed to the
forks** (`--force-with-lease`). Recovery SHAs: core `edfc99d2`, pulp `cd04829`, engine `a6d92918`.

**What.** Pulled the latest upstream into both dev branches.
- Synced fork views from real `gvsoc/gvsoc-{core,pulp}` (fetch upstream): core/master 15
  behind, pulp/master 7 behind, both 0 ahead (clean ff).
- Rebased `insitu-cache` onto `upstream/master` in each: **no conflicts** — all 6 core + 7 pulp
  cache commits replayed. core `edfc99d2→9364002e`, pulp `cd04829→b8d08e4`. Local `master`
  refs fast-forwarded to upstream.
- **Engine bump `a6d92918→5863c25e`** (origin/main, +15): required — upstream core
  `iss/iss_v2/riscv.py` now calls `Component.add_libraries(['dw','elf'])`, added to the engine
  in `a3d410b4`. (Error before bump: `'SnitchFast' object has no attribute 'add_libraries'`.)
- **New upstream build dep — elfutils headers.** Upstream `e1346286/33945126` made the ISS
  trace resolve PC→symbol via libdw (`<elfutils/libdwfl.h>` + `add_libraries(['dw','elf'])`).
  The host (AlmaLinux 8) has the runtime libs but not `elfutils-devel`, no passwordless sudo.
  Resolved without sudo: `scripts/setup_elfutils_headers.sh` dnf-downloads the matching
  `elfutils-devel-0.190` RPM into gitignored `third_party/elfutils-devel/`, extracts the headers,
  and makes the missing `libdw.so` link symlink. Build exports `CPATH` (include) + `LIBRARY_PATH`
  (link). Documented in CLAUDE.md "Build environment". (User-approved: provide elfutils-dev.)

**Verification.** `make build TARGETS="insitu_cache_calib insitu_cache_microbench
spatz:use_insitu_cache=True rv64"` clean (exit 0) with `CPATH`/`LIBRARY_PATH` set. Calibration
**byte-identical post-rebase**: warm hit 10, cold miss 67 (BL4) / 63 (wide), coal_cold wide
0.496 (mem_rd 32), cold_stream wide 0.254, coal_warm 3.37/lat 7, microbench hit_repeat_r4 1.98.
Used `make build` (NOT `make all`, which would `git submodule update` and reset the rebase to
the stale parent pointers — so the parent pointer bump below must precede any `make all`).

**Files / pointers.** parent: submodule bumps core/pulp/engine + `scripts/setup_elfutils_headers.sh`
(new) + `CLAUDE.md` (elfutils build-env note) + this log. Submodule working trees: rebased
(content of the cache files unchanged → objects identical → calib unaffected).

**Pushed (2026-06-08):** core `insitu-cache` `6347ea65→9364002e` (forced), pulp `f80254b→b8d08e4`
(forced); fork `master` refs fast-forwarded to upstream (core `26c86fd4→6ca5e8f9`, pulp
`abcddd6→4319260`). Remote == local verified. Parent `main` stays local per the
submodules-only-push preference.

---

## 2026-06-04 (later) — Streaming read-hit pipelining: latency 10 → 7

**Status:** implemented + verified (regression-clean); committed — core `edfc99d2`,
pulp `2282baa` (local; not pushed).

**What.** Modelled the RTL read-hit pipeline fill/drain so a streaming hit costs 7 cyc and
an isolated hit 10 (both MemLatency-independent). New gated knob
`InsituCacheControllerConfig.streaming_hit_latency_cycles` (default -1 = OFF). In the VALID
read-hit branch of `insitu_cache_controller.cpp`, base latency =
`streaming + min(hit_latency-streaming, cycles_since_last_read_hit)` — a per-controller
warmth gradient anchored on `last_read_hit_cycle_`. The calib config sets it to
`hit_latency-3` (=6 → interco(1)+6 = 7 streaming). READ hits only (writes, forwarded reads,
and MSHR-drain responses keep their own latency).

**Why a gradient, not a binary warm/cold.** The RTL has three decoupling registers
(coalescer req-spill, resp-spill, rsp_spliter/output-FIFO) that drain 1/cycle when idle, so
the latency rises smoothly with the injection gap. The design workflow's RTL grounding
(`wbkqdkn9u`) surfaced the exact gap-sweep: gap0→7, gap1→8, gap3→10, gap7→10. The gradient
reproduces all of it; a binary model would give only 7 or 10.

**RTL grounding (workflow `wbkqdkn9u`, 3 agents).** Parallel RTL-report reader + RTL-hit-path
reader + synthesis. Mechanism confirmed: isolated 10 = end-to-end fill of every registered
stage; streaming 7 = steady-state once the three decoupling registers stay occupied; both
config-fixed, MemLatency-independent (REPORT.md §3.1, CHARACTERIZATION.md §3, the 7/7/10 CSV
signature). The synthesis also scoped the outstanding-distribution gap (Change B) as a
deferred per-resource occupancy item.

**Verification (ML50, target insitu_cache_calib).** Added `bw_hit_gap{0,1,2,3,7}` traces to
verify the gradient — GVSoC tail latency 7/8/9/10/10 **exact** vs RTL; gap≥1 throughputs also
exact (gap1 0.476 vs 0.467, gap3 0.244 vs 0.243, gap7 0.124 vs 0.124). warm_stream latency
10→7; coal_warm latency 10→7 (7/7/7) and throughput 3.12→3.37 (RTL 3.28, +2.7%, closer in
abs). Misses unchanged (cold_miss 67/63, cold_stream 0.254, coal_cold 0.496); writes/RAW
unchanged (8/7). **Spatz/microbench no-op:** build clean; microbench 7 CALIB_REPORT lines
byte-identical (hit_repeat_r4 1.98). **Spatz-safe:** pure inline-OK latency adjustment, knob
default-OFF.

**Honest residual.** With the latency now correct (7), the *saturation* single-port hit
throughput reads ~0.91 (warm_stream/bw_hit_gap0) vs RTL 0.865 (~5.7% over) — the correct
latency unmasked a small accept-ceiling over-prediction (RTL accepts ~0.955/cyc, model
~1.0). Separate sub-cycle accept-rate item; gap≥1 (below the ceiling) matches exactly.

**Files.** core: `insitu_cache_config.py` (+streaming_hit_latency_cycles, calib wiring),
`insitu_cache_controller.{py,cpp}` (gradient + last_read_hit_cycle_). pulp:
`insitu_cache_calib/gen_traces.py` + `traces/bw_hit_gap*.trace`.

**Open (Change B — THREE approaches tried + reverted → confirmed needs a structural refactor):**
outstanding *distributions* — coal_cold out 128 vs 56 (and lat 146 vs RTL 82), evict out 32
vs 4. Throughputs already match. Empirically ruled out the incremental fixes (all gated
default-OFF, defer_refills-only, cold_stream/evict held throughout):
  1. **Accept-depth cap** (`max_inflight_reads`=56, completion-multiset, DENY-when-full):
     coal_cold regressed 0.496→0.183 (lat→250). The capped same-line followers serialize on
     `set_busy` (they "hit" the inline-VALID-but-not-ready line), complete late, never retire
     → cap stuck → throughput starved.
  2. **Ride-the-refill** (a not-ready read hit skips `set_busy`, completes at ready_cycle):
     barely moved coal_cold (lat 146→142, out still 128) — proving the latency floor is the
     *drain backlog depth* (128 in flight), not `set_busy`.
  3. **Cap + ride-the-refill combined:** still regressed (0.214 / lat 234 / out 85) — the
     DENY/retry churn without faster refills.
**Structural conclusion:** the `refill_drain_cycles` cyclestamp serves DOUBLE duty — it sets
both the miss *throughput* AND the spread-out `ready_cycle`s (hence the latency). cold_stream
relies on it for throughput (0.254); coal_cold inherits its deep backlog as latency (146).
RTL instead gets coal_cold's throughput from the **cache accept depth** (≈56) with **fast
pipelined refills** (→ lat 82). Matching all of {thr, lat, out} therefore needs a real
occupancy refactor that DECOUPLES the throughput limiter (refill+writeback rate / accept
depth) from the per-access latency (refill completion) — i.e. a deferred-completion miss path
(line stays READ_PEND until a scheduled refill-done event; followers MSHR-merge), which is
exactly the "heavy event-pool" deliberately avoided in the §10 occupancy model. cold_stream's
match (32/95/0.254, requester-bound) is the regression tripwire any such refactor must hold.
**Decision pending:** high effort + regression risk for a diagnostic-out + one-phase-latency
gain, when all throughputs already match — so left for an explicit go-ahead.

**2026-06-04 — deferred-completion design workflow (`wuw0hl7ph`, 4 agents) → adversarial NO-GO.**
Ground (exact RTL timing + GVSoC event API) → design the event-scheduled deferred-completion
miss path → adversarial verify. Verdict **NO-GO**, two fatal flaws, both confirmed empirically:
  - *miss_fifo throttle:* the calib config inherits `miss_fifo_depth=4`; moving its decrement
    to event-fire time would clamp coal_cold to 4 outstanding → collapse (attempt #1 redux).
    Fixable (raise the depth).
  - *writeback-pairing throughput is false for the GVSoC trace:* coal_cold_4port is read-only,
    32 distinct lines into a 1024-entry cache → every miss lands in an INVALID way → **mem_wr=0**
    (VERIFIED: `[CALIB_MEM] mem_rd=32 mem_wr=0`). RTL coal_cold has **mem_wr=32** because the
    shared RTL TB's sets were pre-dirtied by earlier phases. So GVSoC and RTL coal_cold are
    DIFFERENT scenarios. The current GVSoC throughput match (0.496 vs 0.467) is an *artifact* of
    the followers' `set_busy` serialization (≈ RTL's writeback drain by coincidence). Removing
    that serialization — the very thing the deferred-completion fix does to cut latency — would
    make throughput OVERSHOOT to ~0.9 unless real writebacks pair.
**Net:** the faithful fix needs THREE things together — (1) regenerate coal_cold to pre-dirty
its 32 sets so writebacks fire (mem_wr=32, replicating the RTL TB state); (2) the
deferred-completion event path (followers MSHR-merge → latency ~82); (3) raise miss_fifo_depth
+ reset/event hygiene. That is substantial trace surgery + a risky MSHR-path event refactor, and
the corrected design has not been re-verified. Given all throughputs already match and the gap
is one phase's diagnostic out-count + latency, this is parked for an explicit decision rather
than barrelling past the NO-GO. Full analysis: workflow `wuw0hl7ph` output.

## 2026-06-04 (later) — coal_cold occupancy refactor: design↔verify loop → NO-GO on code, doc deliverable

**User direction:** "do the occupancy refactor" → then "re-verify, then implement." So I ran a
3-round design↔verify loop (workflow `w4ohzna7g`, agents measuring on the live tree). Final
verdict **GO-WITH-FIXES = NO-GO on any code refactor; GO only on documentation**. The loop
*proved* (not asserted) the refactor is futile/harmful:

- **Deferred completion is a measurement no-op.** `t_resp = t_issue + get_full_latency()`
  (calib_driver.cpp:304); follower latency is determined at issue (controller.cpp:654-660).
  coal_cold lat = ML+96.5 lockstep (106.5/146.5/196.5/296.5) — a +6-cyc/line install ramp tail,
  not a deferrable stagger. Deferring `resp()` moves the metric by zero.
- **Pre-dirty regresses:** measured 0.31 thr / 169 lat / 96 out (double-reserves the install pipe).
- **Accept-throttle breaks coalescing:** DENYs cold followers before MSHR-merge; port-0 race.
- **thr/lat/out are one coupled knob:** D-sweep D={0,1,3,6,9} → coal_cold {0.653,0.653,0.496,
  0.365,0.288}, cold_stream {0.408,0.408,0.254,0.145,0.102}; D=3 is the joint optimum.

**Decision:** did NOT implement any refactor (no ClockEvent / finish_refill / accept-throttle /
new knob; even the "optional" miss_fifo=64 bump omitted — verified inert: in wide mode the memory
returns OK synchronously so miss_fifo never fills, peak ~1). **Landed only docs:** calib report
§13 (the four proofs + the Phase-B scoping) + a gen_traces.py comment warning not to pre-dirty
coal_cold. The model stays well-calibrated: all throughputs + headline latencies match;
coal_cold lat/out are coupled RTL-shape residuals whose only convergent fix is a Phase-B
controller same-line MSHR-collapse + ~14-line install cap (scoped, unproven, not implemented).

**Spatz/inline byte-identity:** trivially held — no model code (.cpp/.py) changed; the
gen_traces.py edit is comment-only (traces byte-identical after regen). **Files:** core: none;
pulp: `insitu_cache_calib/gen_traces.py` (comment); parent: `prompt/insitu_cache_calib_report.md`
§13, `prompt/WORKLOG.md`.

---

## 2026-06-04 — Phase-B input par-coalescer: close coal_warm (0.06 → 3.12 acc/cyc)

**Status:** implemented + verified (regression-clean); ready to commit (core + pulp).

**What.** Modelled the RTL input `par_coalescer` as a **same-cycle, same-line read-HIT merge
inside `insitu_cache_interco`** (the per-cycle arbitration point), default-OFF. The first
read of a line in a cycle forwards normally; same-cycle followers to the same line inherit
its latency and do **not** re-consume the per-output accept slot — so N VLSU words to one
line cost ~one bank access (RTL: ~4× the single-port hit rate). New gated knobs on
`InsituCacheIntercoConfig`: `enable_input_coalesce` (False), `cache_line_bytes` (64),
`coalesce_max_latency` (-1). The calib config sets them (coalesce on, threshold = hit+7 ≈ 16).

**Why the interco, not the controller (overrode the design's first pick).** A controller-only
merge can't close the gap: the interco's `output_busy_until` serializes the 4 same-cycle
reqs (grows 4/cyc while `now` grows 1/cyc), capping throughput at ~1/cyc regardless of the
controller. Merging at the interco removes that serialization at its source.

**Two fixes the first build exposed:**
1. *Only 3 of 4 ports merged.* The coal_warm trace preloaded via **port 0**, so port 0
   entered the measured phase ~32 cyc behind ports 1–3 (its preload tail) → it never shared
   a cycle with them. Fix: preload via the **scalar port (4)** so all four VLSU ports stay
   cycle-aligned. (gen_traces.py)
2. *coal_cold regressed 0.49 → 0.65.* The inline refill makes a cold line VALID immediately,
   so cold same-cycle followers were wrongly merged as warm hits. Fix: `coalesce_max_latency`
   — only a forwarded read whose latency is warm-hit-sized (≤16) seeds the window; a
   refill-sized "hit" (≥60) does not, so cold followers fall through to the MSHR-merge path.

**Result (ML50):** coal_warm **0.06 → 3.122** acc/cyc (RTL 3.282, −4.8%), latency flat 10
(RTL 7 — the known hit-pipelining residual). coal_cold held at **0.494** (RTL 0.467),
mem_rd=32. **All other phases byte-identical** (warm_stream 0.877, warm_write 8.0/0.478,
raw_same_word 7.0, cold_miss wide 63, cold_stream wide 0.254, evict mem_wr 1024). Spatz/
microbench no-op proven: build clean; microbench 7 CALIB_REPORT lines unchanged; merge
gated off (`make_cachepool_512_config` leaves `enable_input_coalesce`=False).

**Spatz-safe by construction.** Pure same-cycle latency adjustment on the already-inline-OK
hit path: never holds a req, never defers a resp, never returns non-OK, never touches
`IoReq::get_args()`. Default-OFF; only the calib config flips it.

**Scalar bypass — deferred (low value).** The RTL scalar "~60" is the *isolated* cold-miss
latency, which the model **already** matches (`cold_miss_isolated` = 63–67). The sample
trace's idx11=175 is *memory-refill contention* (port 0 issues 4 serializing misses at the
same instant) that RTL would also show; it is not a cache-path issue. Modeling the bypass
precisely is a memory-arbitration refinement on a synthetic trace, not a headline metric.

**Files.** core: `insitu_cache_config.py` (interco knobs + calib wiring),
`insitu_cache_interco.{py,cpp}` (merge logic). pulp: `insitu_cache_calib/gen_traces.py`
(coal_warm preload via scalar port).

---

## 2026-06-03 04:30 +0200 — Calibration check vs REPORT_BL1.md (20-phase BurstLength=1)

**Status:** assessment only (no code change). Doc-only update (calib report §9.1).

**Result — partially calibrated.** Ran every GVSoC trace in wide mode @ML50 vs the RTL
`REPORT_BL1.md` 20-phase table:
- ✅ **Matches:** all hit/write/RAW latencies+throughputs (warm hit 10, warm write 8, RAW 7,
  warm_stream 0.877 vs 0.865, warm_write_stream 0.478 vs 0.489) — the report's "unchanged"
  invariant holds; cold-miss latency ML+13 exact across the sweep; memory-traffic structure
  (cold_stream rd=64, coal_cold rd=32, evict rd=2048/wr=1024) on every miss phase;
  cold_stream max_outstanding=32 (requester-bound).
- ⚠ **Over-predicts wide-mode miss throughput:** cold_stream 0.41 vs 0.243 (1.7×),
  coal_cold 0.65 vs 0.467 (1.4×, out 128 vs 56), evict 0.49 vs 0.177 (2.8×, out 32 vs 4).
- ❌ coal_warm 0.06 vs 3.282 — pre-existing input-coalescer gap (not BL-related).

**Root cause:** GVSoC bounds outstanding by the per-port budget (32) with flat per-access
latency (63); RTL bounds by cache-internal resources that differ per access type (MSHR
accept ~56, write-allocate accept ~4) AND inflates latency under load (→100/82/98). So
GVSoC pegs at the ~0.5 plateau for every miss-heavy phase; RTL varies 0.18–0.47. Closing it
needs the cache-occupancy model (deferred refill + per-resource caps + under-load latency)
— the recurring Phase-B item (calib report §5(7)/§9.1).

**Files touched.** `prompt/insitu_cache_calib_report.md` (§9.1).

---

## 2026-06-03 20:27 +0200 — Occupancy model: close wide-mode miss throughput (cold_stream/coal_cold/evict)

**Status:** committed — core `6347ea65`, pulp `f80254b` (pushed); parent committed locally.
This commit also carries the 2026-06-03 03:45 wide-refill experiment work (same files).
Builds clean; default + spatz provably unchanged.

**Context.** §9.1 showed GVSoC over-predicts wide-mode miss-heavy *throughput* (inline
resolution → flat 63-cyc latency, no contention; only the per-port budget bound). Ran a
research+design multi-agent workflow (7 agents) to ground the fix in the RTL resource
structure, then implemented a **simpler** mechanism than the proposed event-pool rewrite.

**What was done (all gated behind new `defer_refills`, default False = inline = spatz path):**
- `insitu_cache_controller`: `refill_resp_handler` serializes refill *completion* cycles via
  a monotonic cyclestamp `refill_drain_busy_until_` (+`refill_drain_cycles` per completion;
  refill_lat REPLACED, no double-count) → queued-miss latency inflates under load → the
  driver's slot-deferral paces issues → install-rate-bound throughput + latency ramp.
  `issue_eviction` advances the same cyclestamp (+folded penalty) so writebacks share the
  pipeline (evict ≈ ½ read-miss rate). Reset in reset(); knobs read in ctor; mirrored in
  controller.py.
- New config knobs (no-op defaults): `defer_refills` + `refill_drain_cycles` (these two
  produce the entire effect). Calib wide block (`__init__.py`) sets defer_refills=True,
  refill_drain_cycles=3 (env `INSITU_CALIB_REFILL_DRAIN`); make_cachepool_512_config (spatz)
  keeps defaults. (An adversarial-review workflow found 3 further knobs I'd added for a
  pool/DENIED approach — `max_outstanding_refills`/`writeback_outstanding`/
  `model_backpressure_denied` — were DEAD; removed them + factored the two cyclestamp
  advances into one `reserve_install_pipe()` helper.)
- `gen_traces.py`: cold_stream_long (already added) for the plateau.

**Calibration vs RTL BL1 (@ML50):** cold_stream 0.254 (RTL 0.243), coal_cold 0.494 (0.467),
evict_dirty 0.166 (0.177), evict_wb 0.166 (0.178), cold_miss isolated 63 (=ML+13), lat ramp
63/95/125 (RTL 63/100/130). **All four miss-heavy throughputs within ~7%** (was 1.4–2.8×
over). Sweep: coal_cold ≤6%, cold_stream ≤10% (24% @ML10 — fixed drain can't match RTL's
flat install-cap at low ML).

**No regression:** default (BL4) calib unchanged (cold miss ML+17, cold_stream 0.0188, warm
hit 10, write 8/0.478, RAW 7, coal mem_rd 32); wide hits/writes unchanged; `spatz:use_insitu_
cache=True` builds (93 targets); microbench identical. Spatz-safe by construction
(defer_refills=False → inline path verbatim, no new non-OK).

**Verification.** Adversarial-review workflow (3 agents: C++ correctness + spatz-safety +
synthesis) → **GO-WITH-FIXES → GO**: confirmed no latency double-count, monotonic+reset
cyclestamp, head-of-line unaffected, defer_refills=False path byte-identical, no new non-OK
on any path. Applied its must-fix (removed 3 dead knobs) + nit (helper). Post-fix: all
numbers unchanged, builds clean (100 targets).

**Residuals (secondary):** per-phase max_outstanding + latency *distributions* (coal_cold
out 128 vs 56, evict out 32 vs 4) would need an explicit per-resource pool/event model
(future phase). Throughputs + latencies match. See calib report §10.

**Files touched.** `core/models/cache/insitu/insitu_cache_config.py`,
`insitu_cache_controller.{cpp,py}`, `pulp/insitu_cache_calib/__init__.py`,
`prompt/insitu_cache_calib_report.md` (§10).

---

## 2026-06-03 03:45 +0200 — Wide single-beat refill throughput experiment (mirror RTL)

**Status:** committed (with the occupancy round) — core `6347ea65`, pulp `f80254b`.
Builds clean; default-config calibration fully preserved.

**Context.** Mirrors `ManyRVData_rebase/reports/cache_calib/THROUGHPUT_EXPERIMENT.md`
(+ `char_bl1/*.csv`): RTL `refill_data_width=512` ⇒ BurstLength=1, misses pipeline (no
single-outstanding gate), deep memory queue; the binding limit becomes the requester's
32-outstanding budget (Little's law plateau ≈ 32/(ML+13) ≈ 0.5). RTL cold_stream jumps
0.018 → 0.243 (64-burst).

**What was done (toggle `INSITU_CALIB_WIDE_REFILL=1`; default config untouched).**
- `insitu_calib_mem`: new `serialize_refills` (default True) + `max_outstanding` (default 8)
  knobs. When False, refill reads run concurrently (no `mem_busy_until` one-at-a-time).
- `calib_driver`: a request now holds its per-port outstanding slot until the response
  returns (deferred slot-free via an inflight-completion multimap), so `outstanding_budget=32`
  genuinely binds (`max_outstanding` reads 32, not the prior artifactual 1). This is the
  §3 requirement. Verified non-regressive for the default config.
- `__init__.py`: `INSITU_CALIB_WIDE_REFILL` → refill_beat=cache_line (single beat),
  serialize_refills=False, max_outstanding=64, and miss_penalty=9 (cold miss ML+17→ML+13).
- `gen_traces.py`: added `cold_stream_long` (512 lines) to show the sustained plateau.

**Calibration (wide config) vs RTL bl1:**
- cold miss isolated = **ML+13** (23/63/113/213) ✅ exact across the sweep.
- mem_rd = **64** (one refill/miss) ✅; max_outstanding = **32** (ML≥50) ✅.
- **sustained plateau** (512-line stream, ML50) = **0.49** ≈ doc's `32/63 ≈ 0.5` ✅ —
  matches the doc's Little's-law plateau (the actual stated limit).
- 64-line burst throughput = 0.41 @ML50 (RTL 0.243) — over; the doc labels 0.243 a
  fill/drain short-burst artifact and computes the true plateau as ~0.5, which GVSoC hits.
  The residual is RTL's under-load latency inflation (lat_avg 100 vs my 63) from
  cache-internal miss-handling serialization — the same cache-occupancy gap as the
  calib report §5(7). Without the driver budget the wide config would run unbounded
  (~1/cyc); with it, bounded to ~0.5 — the doc's requirement is met.

**Verification.** `make build TARGETS=insitu_cache_calib` clean. **Default (serialized)
config fully preserved:** cold miss ML+17, cold_stream 0.0188, warm hit 10, write 8/0.478,
RAW 7, coal mem_rd 32, evict 0.0189/1024, microbench unchanged (max_outstanding now 32 vs
prior 1, no throughput change). Shared controller/config NOT touched this round
(miss_penalty=9 is a per-instance runtime override in the calib target) → spatz unaffected.

**Files touched.** `core/models/cache/insitu/insitu_calib_mem.{cpp,py}`,
`pulp/insitu_cache_calib/{calib_driver.cpp,__init__.py,gen_traces.py}`,
`prompt/insitu_cache_calib_report.md` (§9).

**Follow-up.** Exact 64-burst match (0.243) needs a cache-occupancy model that inflates
the under-load round-trip — the recurring deferred item (calib report §5(7)).

---

## 2026-06-02 11:29 +0200 — Commit all WIP + rebase dev branches onto upstream, bump engine

**Status:** committed (submodules pushed; parent committed locally).

**Commits.**
- `core` insitu-cache `233850f4` — "insitu-cache: calibration memory model + timing knobs".
- `pulp` insitu-cache `3d15e5d` — "insitu-cache: calibration + microbench testbench targets".
- parent `1e0586a` — docs/reports/worklog/rebase-tooling; parent `e1c7342` — submodule pointer bumps.

**Rebase / upstream pull.**
- Synced the `core` fork master from real upstream `gvsoc/gvsoc-core` (fast-forward
  `455488f8→26c86fd4`, +5 commits); `pulp` fork master already current.
- Rebased both `insitu-cache` branches onto `origin/master` via
  `scripts/rebase_dev_branches.sh` — **no conflicts** (core replayed 3 commits onto the
  5 new upstream ones). Force-with-lease pushed: core `671a27a5→233850f4` (forced),
  pulp `0d3625d→3d15e5d` (fast-forward).
- **Bumped `engine` `a8c57439→a6d92918`** — required: upstream core's new `fst_dumper`
  uses `Signal::description_set` (engine `3a6dd2dc`) and `memory_v3` advertises the
  `IoV2Sync` signature (engine `a6d92918`). gvrun unchanged (current).
- Gotcha: `make all` runs `git submodule update` which resets submodules to the
  parent-recorded SHAs — so the engine bump must be recorded in the parent (or use
  `make build`, which skips checkout) before building. Verified with `make build`.

**Verification.** `make build` of insitu_cache_calib / microbench / spatz / rv64 — clean
(116 targets, 0 errors; `fst_dumper` + `memory_v3` compile against the bumped engine).
Calibration metrics unchanged post-rebase: cold miss = MemLatency+17, warm hit 10,
write 8, RAW 7, cold-stream throughput 0.0188. Commit messages verified free of any
co-author / tool attribution. Parent submodule pointers == pushed remote SHAs.

**Note.** Parent (`main`) committed locally, not pushed (per the submodules-only push
preference). `.claude/` left untracked.

---

## 2026-06-02 10:47 +0200 — Close calib performance gaps: write path, forwarding buffer, writeback overlap

**Status:** uncommitted. Builds clean (calib + microbench + spatz:use_insitu_cache=True);
no regression on primary metrics.

**Context.** User asked to fill the documented performance gaps by further developing
the model. Closed the tractable ones (those not needing the Phase-B topology refactor).

**What was developed.**
- **Write path** (`insitu_cache_controller`): new `write_hit_latency_cycles` (write hit
  acks faster than a read returns) and `write_commit_cycles` (controller-wide
  write-commit backpressure — a write hit is DENIED while the prior write's commit slot
  is busy; upstream retries). Production config: 7 and 2.
- **Forwarding buffer**: new `fwd_hit_latency_cycles` + 1-entry `fwd_buffer_line_`. A
  read on the just-touched line forwards combinationally, **bypassing the bank** (no
  `set_busy` stall). Populated on hits only (cold-miss preloads don't populate it).
  Production config: 6.
- **Writeback overlap** (`insitu_calib_mem`): new `writeback_overlap` — eviction writes
  don't advance `mem_busy_until` (overlap the refill, as in RTL) but still count
  `mem_wr`. Enabled on the calib target's memory.
- All new controller knobs default to no-op; only `make_cachepool_512_config`
  (production) opts in. New config fields wired through `.py` + `.cpp`.

**Verification (@ ML50) — gaps closed:**
- warm-write latency 10 → **8** (RTL 8).
- write throughput (tail) 0.877 → **0.478** (RTL 0.489).
- read-after-write same-word 13 → **7** (RTL 7).
- eviction-stream throughput 0.0126 → **0.0189** (RTL 0.018); mem_wr=1024 preserved.
- **No regression:** cold miss = ML+17 (sweep 27/67/117/217), warm hit = 10,
  cold_stream throughput 0.0188, coal_cold mem_rd=32 — all unchanged.
- `spatz:use_insitu_cache=True` + `insitu_cache_microbench` build & run clean
  (microbench hit_repeat 2.55→1.98 c/p: forwarding buffer speeds repeated same-line reads).

**Remaining gaps (documented, need Phase-B topology or full occupancy model):**
scalar bypass port, input par-coalescer *warm throughput* (mem traffic already matches),
and bounded accept-depth / hit pipelining / multi-port hit ceiling (need PENDING +
real completion event + bounded outstanding — deferred to avoid perturbing spatz).

**Files touched.** `core/models/cache/insitu/insitu_cache_config.py`,
`insitu_cache_controller.{py,cpp}`, `insitu_calib_mem.{py,cpp}`,
`pulp/insitu_cache_calib/__init__.py`, `prompt/insitu_cache_calib_report.md` (§5/§6/§7/§8).

---

## 2026-06-02 09:51 +0200 — Mirror the new RTL calib phases (write / RAW / coalesce / evict) + mem-traffic counters

**Status:** uncommitted. Builds clean.

**Context.** The RTL `cache_calib` TB grew 7 new built-in phases since our harness
was built (RTL `reports/cache_calib/CHARACTERIZATION.md`, 2026-06-01): warm-write
latency/throughput, read-after-write same-word (forwarding buffer), cold/warm
coalesced 4-port, and dirty-fill / writeback-miss eviction. Its aggregate CSV also
gained `mem_rd`/`mem_wr` columns. User asked to add any new TB/trace patterns on the
GVSoC side.

**What was done.**
- `pulp/insitu_cache_calib/gen_traces.py`: added 7 traces mirroring the RTL phases —
  `warm_write_isolated`, `warm_write_stream_1p`, `raw_same_word`, `coal_cold_4port`,
  `coal_warm_4port`, `evict_dirty_fill` (2× capacity), `evict_wb_miss_stream`.
- `core/models/cache/insitu/insitu_calib_mem.cpp`: added a `stop()` end-of-sim hook
  (block.cpp invokes it recursively at sim close) emitting
  `[CALIB_MEM] mem_rd=… mem_wr=…` — refills = mem_rd, dirty evictions = mem_wr — so
  coalescing and eviction can be verified against the RTL `mem_rd`/`mem_wr` columns.
- `prompt/insitu_cache_calib_report.md`: new §7 with the GVSoC↔RTL comparison.

**Verification (@ ML50).**
- **Memory-traffic counts match:** `coal_cold_4port` **mem_rd=32** (= RTL; 128
  same-line accesses collapse to 32 refills — the controller's MSHR-merge reproduces
  the RTL input-coalescer's traffic reduction). `evict_dirty_fill` **mem_wr=1024**
  (RTL 1051); `evict_wb_miss_stream` mem_rd/wr=2048/1024 (RTL 2054/1029). All
  `data_err`-free, builds clean.
- **Throughput/latency gaps are the known Phase-B items** (not new): warm-write
  latency 10 vs RTL 8; write-stream throughput 0.877 vs RTL 0.489 (no write-path
  serialization); RAW same-word 10 vs RTL 7 (no explicit fwd-buffer forward); coal
  warm throughput ~0.06 vs RTL 3.28 (no input coalescer); evict throughput 0.0126 vs
  RTL 0.018 (GVSoC serializes the writeback fully vs RTL overlapping it).

**Files touched.** `pulp/insitu_cache_calib/gen_traces.py`,
`core/models/cache/insitu/insitu_calib_mem.cpp`,
`prompt/insitu_cache_calib_report.md`.

**Follow-ups.** The throughput/latency gaps map to the existing backlog (write
early-ack + write-info serialization, input par-coalescer, fwd-buffer same-row
forward, writeback/refill overlap, bounded accept-depth/occupancy). Upstream pull
still pending (see prior entry).

---

## 2026-06-01 22:49 +0200 — Track RTL update: cachepool_512 default → production (folded+hash+fwd-buffer)

**Status:** uncommitted. Builds clean; calibration re-verified.

**Context.** Re-reviewed the RTL (per `CLAUDE.md` §"Tracking new RTL revisions").
Found substantive updates since the v2 doc (2026-05-22): the insitu-cache submodule
moved to branch `zexin/sync-flush-fixes`; the integrating repo gained
`3af9362 [CFG] make L1 folded/hash-way/fwd-buffer config-selectable` and
insitu-cache `fbabd6a` (forwarding buffer → top-level parameter).

**Key finding.** The shipping `cachepool_512` default **flipped to the production
cache**: folded + hash-way + forwarding-buffer ON (`l1d_use_folded/hash/fwd_buf=1`).
Unfolded+LRU+no-fwd is now the opt-in "conventional" cache. Constraint:
`fold OR fwd-buffer ⇒ hash-way=1`. Default size also dropped to 1 tile / 4 cores.
My v2 doc was correct on 2026-05-22 but is now stale on the default.

**What was done.**
- `prompt/insitu_cache_architecture_v2.md`: header ⚠ note; new §0.1 (config-selectable
  folded/hash/fwd, the two supported configs, the constraint, forwarding-buffer
  description) + §0.2 (RTL fixes since 2026-05-22); corrected §0 delta-table rows.
- `core/models/cache/insitu/insitu_cache_config.py`: new `use_forwarding_buffer` knob
  (default True); `use_hash_way_select` default → True; **`make_cachepool_512_config`
  is now production** (hash, folded `refill_bank_write=2`/`folded_evict=3`, fwd on,
  `miss_penalty=7`); new `make_cachepool_512_conventional_config` (unfolded+LRU+no-fwd,
  `miss_penalty=8`); legacy config sets fwd=False.
- `insitu_cache_controller.{py,cpp}`: publish/read `use_forwarding_buffer` (informational).
- New track report: `prompt/insitu_cache_rtl_update_2026-06-01.md`.

**Verification.**
- `make all TARGETS="insitu_cache_calib insitu_cache_microbench"` — clean.
- Re-calibration under production config holds **exactly**: cold miss = ML+17
  (27/67/117/217 @ ML 10/50/100/200), warm hit = 10, cold-stream throughput 0.0188
  (RTL 0.0181). The `miss_penalty 8→7` + `refill_bank_write 1→2` swap keeps totals.
- Microbench runs clean, numbers unchanged (patterns don't trigger evictions/conflicts).

**Files touched.** `prompt/insitu_cache_architecture_v2.md`,
`prompt/insitu_cache_rtl_update_2026-06-01.md` (new),
`core/models/cache/insitu/insitu_cache_config.py`,
`core/models/cache/insitu/insitu_cache_controller.{py,cpp}`,
`prompt/insitu_cache_calib_report.md` (calibration note).

**Follow-ups.** Phase-B backlog unchanged (topology refactor, explicit fwd-buffer
model, flush FSM, write early-ack, occupancy model).

**Upstream check (2026-06-01, fetch only — no rebase/bump performed):**
- `engine`: **5 behind** `gvsoc/gvsoc-engine` main — `a8c57439 → a6d92918`
  (incl. `signature: add IoV2Sync sub-protocol signature`).
- `core`: fork `origin/master` and our `insitu-cache` are **5 behind** real
  `gvsoc/gvsoc-core` master (`26c86fd4 memory_v3: drop latency/bandwidth model,
  advertise IoV2Sync`, verilator/fst/iss_v2 fixes). **Coupled with the engine
  bump** — `memory_v3` advertises the `IoV2Sync` signature that engine
  `a6d92918` adds, so pulling core needs the engine bump too.
- `pulp`: **0 behind** (fork master == real upstream == our branch). Nothing to pull.
- `gvrun`: **0 behind**.
- **Blocked on:** uncommitted WIP in `core`/`pulp`/parent must be committed before
  rebasing (`scripts/rebase_dev_branches.sh`, runbook "with uncommitted changes"
  path). Not executed — user commits their own WIP. Recommended sequence: commit
  WIP → `scripts/rebase_dev_branches.sh --push` (rebases insitu-cache onto fork
  master; sync fork master from real upstream first) → bump `engine` to a6d92918
  → commit parent submodule pointers.

---

## 2026-06-01 22:01 +0200 — Adopt dev-log convention + build GVSoC-side calibration testbench

**Status:** uncommitted (no git commit yet). Builds clean; primary calibration
metrics matched.

**Context / motivation.** The RTL repo (`ManyRVData_rebase`) now ships a
standalone performance-calibration testbench around one `cachepool_cache_ctrl`
plus a deterministic fixed-latency refill responder, with a documented
trace + result-CSV interchange format and reference numbers
(`ManyRVData_rebase/reports/cache_calib/`: `PLAN.md`, `TRACE_SPEC.md`,
`CALIB_IMPLEMENTATION.md`, `REPORT.md`, `results_memlat*.csv`,
`traces/sample.trace`). Goal: build the GVSoC-side twin so both engines run the
*same* trace through the *same* memory-timing model and we diff the per-access
`latency` column to calibrate the GVSoC perf model.

**What was done.**
1. Adopted the RTL repo's "Development log" convention into this repo's
   `CLAUDE.md` (new §"Development log (for weekly reports)"), pointing the
   worklog at `prompt/WORKLOG.md` (this file). Added `CLAUDE.md`
   §"Calibrating the model against the RTL standalone testbench".
2. Built the GVSoC-side calibration testbench (twin of the RTL `cache_calib`):
   - `core/models/cache/insitu/insitu_calib_mem.{cpp,py}` — serializing
     fixed-latency refill memory (`mem_busy_until` cyclestamp; synchronous-OK so
     the controller's inline refill path works). MemLatency/BeatGap/AcceptEvery.
   - `pulp/insitu_cache_calib/calib_driver.{cpp,py}` — trace-replay driver +
     per-access monitor. Reads `port,rw,addr,size,delay`; per-port file-order +
     concurrent-port semantics (an access's `delay` gates *its own* offer from
     the prev accept — initial bug fixed); emits per-access + aggregate CSVs in
     the shared schema.
   - `pulp/insitu_cache_calib/__init__.py` — target wiring (driver → 1-ctrl tile
     → calib mem); trace/knobs via env vars; trace path resolves to the source
     repo even when run from the installed copy.
   - `make_cachepool_512_calib_config()` — single-controller DUT geometry
     (5 ports, 4-way × 256-set = 64 KiB), matching one RTL `cachepool_cache_ctrl`.
   - `pulp/insitu_cache_calib/gen_traces.py` — trace suite (warm-hit/cold-miss
     isolated, cold/warm streams). Sample trace copied byte-identical from RTL.
3. **Calibration knobs.** Added `miss_penalty_cycles` (default 0, non-invasive)
   to `InsituCacheController`. Set the canonical `make_cachepool_512_config`
   to the RTL-matched constants `hit_latency_cycles=9`, `miss_penalty_cycles=8`
   (the spatz integration + microbench inherit these).

**RTL reference numbers (config 512) the GVSoC model must reproduce:**
- Warm read-hit = **10 cyc** isolated, **7 cyc** streaming (MemLatency-independent).
- Cold read-miss first word = **MemLatency + 17 cyc** (verified at MemLatency∈{10,50,100,200}).
- **Serialized refills**: ≤1 outstanding line-refill; miss throughput ≈
  1/(MemLatency+17), NOT divided by accept depth. *(Most important to match.)*
- Single-port hit-throughput ceiling ≈ **0.86 acc/cyc**; 4-port all-hit ≈ 0.86 (sub-linear).
- Burst = 4 × 128b beats per 512b line, LSB-first.

**Calibration result (config 512, ML=50 unless noted) — primary metrics matched:**
- Warm read-hit isolated = **10 cyc** (RTL 10), MemLatency-independent. ✅ exact
- Cold read-miss isolated = **MemLatency + 17** (27/67/117/217 @ ML 10/50/100/200,
  RTL identical). ✅ exact across the sweep
- Cold-stream miss throughput = **0.0188 acc/cyc** (RTL 0.0181). ✅ within 4% —
  the serializing memory reproduces the RTL single-outstanding-refill behaviour.
- Single-port hit-throughput ceiling = **0.877 acc/cyc** (RTL 0.86). ✅ within 2%
- Sample mixed trace: clean read-misses match near-exactly (idx2 279=279);
  writes (idx6) + scalar port (idx11) diverge — known Phase-B gaps.

Full comparison + gap analysis: `prompt/insitu_cache_calib_report.md`.

**Files touched.**
- `CLAUDE.md` (+2 sections)
- `prompt/WORKLOG.md` (new)
- `prompt/insitu_cache_calib_report.md` (new)
- `core/models/cache/insitu/insitu_calib_mem.{cpp,py}` (new)
- `core/models/cache/insitu/insitu_cache_config.py` (new `miss_penalty_cycles`,
  calibrated canonical config, new `make_cachepool_512_calib_config`)
- `core/models/cache/insitu/insitu_cache_controller.{cpp,py}` (`miss_penalty_cycles`)
- `pulp/insitu_cache_calib/{__init__.py,calib_driver.cpp,calib_driver.py,gen_traces.py,traces/*}` (new)

**Verification.**
- `make all TARGETS=insitu_cache_calib` — clean (make exit 0).
- `make all TARGETS="insitu_cache_microbench insitu_cache_tb"` — clean; microbench
  runs, numbers shifted as expected for the calibrated config (e.g. hit_repeat_r4
  1.30 → 2.55 c/p, cold_stream_r4 2.67 → 4.11 c/p — reflects hit_latency 4→9 and
  miss_penalty +8). No regression.

**Follow-ups / open (Phase B / occupancy model).**
- Write early-ack (RTL acks at request acceptance; GVSoC over-charges a write miss).
- Scalar bypass port (RTL port 4 bypasses coalescer ≈60 cyc; GVSoC routes all 5
  ports identically).
- Bounded miss accept-depth + true occupancy: GVSoC resolves refills inline, so
  `max_outstanding` reads 1 and the queue-inflated *avg* miss latency over-predicts
  (throughput unaffected). Needs PENDING-with-completion-event instead of inline.
- Hit pipelining (RTL streaming hit 7 vs GVSoC 10) and the 4-port shared-controller
  hit ceiling (clean number needs synchronized stimulus + occupancy model).
- Optional finer cold-stream match: +~2 cyc memory occupancy to track RTL at low ML.
