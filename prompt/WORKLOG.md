# GVSoC InSitu-Cache Model — Development Log

> Newest entries at top. Convention defined in `CLAUDE.md`
> §"Development log (for weekly reports)". Append on every meaningful
> change and **always** when committing (any submodule or the parent).
> Weekly reports (`prompt/weekly_report_<date>.md`) are assembled from this
> file + `git log`, not from memory.

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
