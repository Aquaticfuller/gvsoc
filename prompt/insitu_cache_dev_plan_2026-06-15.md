# InSitu Cache GVSoC Model -- Development Plan (2026-06-15)

> **Status note (2026-06-15, applied after the adversarial fact-check).** This plan was drafted against a stale memory note that said the Spatz closed-loop path *hangs*. **That is no longer true:** the hang was root-caused (a 4-bug cascade + a wide-access interco-split bug) and **fixed and committed** — core `3d712809`, pulp `d8abb08`; `examples/spatz/test-riscvTests-vfadd` with `use_insitu_cache=True` now **passes all 15 TCs (retval=0, cycles=58001)**. So **Phase 0 below is essentially DONE.** The *genuine* remaining closed-loop gaps are (a) **DMA/cache incoherence** — the cluster DMA writes TCDM directly, bypassing the cache, and the cache-side `flush_all()`/`i_FLUSH` is implemented but **dormant** (not wired to the L1D peripheral); this is owned by **Phase 4** (flush/sync FSM); and (b) **topology** for apples-to-apples cycle comparison, owned by **Phase 2**. Also: a future async-capable Spatz model is already supported by a **one-line cluster-site flag** (`inline_sync_miss=False` reverts to the park+MSHR+deferred-resp path the calib driver already exercises). **Build/validate gotcha:** the run loads model `.py` from `install/generators/`, NOT source — a `.so`-only rebuild silently uses the stale installed config; do a full `make` (or copy the `.py`) when validating a config-flag change.

## 1. Goals & guardrails

**Primary goal.** A cycle-approximate GVSoC model of the CachePool InSitu L1 D-cache that is faithful to **per-access timing** (calib open-loop, <5% vs RTL) and is being driven toward **whole-system closed-loop cycle comparison** against the RTL cluster (Spatz + shared-L1 + L2). The model is explicitly *not* cycle-exact — it reproduces RTL latency/throughput *behaviours* via calibrated knobs and a small set of structural mechanisms.

**Hard guardrails (non-negotiable for every phase):**

- **Never regress the calibrated open-loop numbers.** The locked reference set (from `calib-tb-refs`, run @93d1c11) that every change must keep within tolerance:
  - warm read-hit = **10 cyc isolated / 7 cyc streaming** (MemLatency-independent, flat across L=10/50/100/200)
  - cold read-miss = **MemLatency + 17 cyc** (BurstLength=4 shipping config)
  - miss throughput **serialized** ≈ 1/(MemLatency+17) (single-outstanding line refill — *not* divided by any MSHR depth)
  - single-port hit ceiling ≈ **0.86 acc/cyc**; port-scaling 1→4 = 0.62/0.76/0.83/0.86 (sub-linear, one shared controller)
  - warm write = **8 cyc** isolated, write throughput ≈ **0.49 acc/cyc**; read-after-write same word = **7 cyc**
  - coalescer warm ≈ **4×** single-port hit rate; cold 4-port coalesced 128 accesses → exactly 32 mem reads
  - dirty-victim eviction ≈ **+10%** latency over clean cold miss
  - These are validated by `pulp/insitu_cache_calib/` replaying `port,rw,addr,size,delay` traces through `insitu_calib_mem` (the GVSoC twin of `refill_mem_model.sv`) and diffing the per-access `latency` column. **Any phase must re-run the calib suite and show no regression in these columns.**
- **Closed-loop must stay Spatz-safe.** The Spatz closed-loop path **runs today** (`use_insitu_cache=True` passes vfadd 15/15, cyc=58001 — see the status note above; the old "HANGS" claim in `insitu_cache_closedloop_state.md` is superseded). The closed-loop completion-protocol invariants that make it work must be **preserved by every phase**: `inline_sync_miss` (complete synchronous misses inline — no re-entrant `resp()` into the v1-ISS core LSU, which faults on it); `functional_writethrough` (push real write bytes to memory for the HTIF/ISS backdoor reader, else the program hangs in a bogus syscall); and the interco wide-access split (`num_outputs>1`) that keeps multi-controller data coherent. No phase may reintroduce a non-OK status on a synchronous LSU path.
- **Gate every new behaviour behind a config flag, default-off.** New RTL fidelity must default to the current calibrated behaviour so the open-loop CSV diff is byte-identical until a knob is explicitly flipped (the established pattern: `if (write_through_mode_) …`, `defer_refills`, `per_cycle_output_arb`, `enable_input_coalesce`).
- **Single source of truth for knobs** stays `insitu_cache_config.py`; defaults track CachePool ctrl defaults (not cache_top defaults).

## 2. Guiding principles

1. **Calibrate-then-structuralize.** Phase A keeps the v1-topology model and adds behaviours as calibrated *latency/occupancy knobs* validated against the calib TB. Only promote a knob to a *structural mechanism* (Phase B) when (a) a knob can no longer hit the target across the parameter sweep, or (b) closed-loop fidelity demonstrably needs the structure (e.g. shared-bank contention across cores). This mirrors the documented stance B.
2. **Gate new behaviour, default-off.** Each item lands behind a `Config` field defaulting to today's behaviour; flip only in the relevant factory (`make_cachepool_512_config` / `_calib_config`) or at Spatz instantiation. This is what makes "never regress" mechanically enforceable.
3. **Validate each step open-loop and/or closed-loop, explicitly.** Every work item states *which* calib phase / RTL reference number it is checked against, or *which* closed-loop test (Spatz kernel) it must keep passing. Open-loop is the cheap regression gate; closed-loop is the acceptance gate for sharing-topology work.
4. **Prefer the shipping regime.** Calibrate the **BurstLength=4 single-outstanding-refill** shipping config first (per stance B and `THROUGHPUT_EXPERIMENT.md`). The BurstLength=1 experiment branch is *not* the shipping config — treat it as a separate validation target, not the default.
5. **Don't model what RTL doesn't have, and note where both sides agree on absence.** AMO/LR-SC has no datapath in `cachepool_cache_ctrl` (it lives in the tile-level `spatz_cache_amo` shim); the model must place AMO at the tile, not the controller. No "AMO in controller" work.

## 3. Phased plan

Ordered by value/dependency. Phases marked **[CL-PREREQ]** are prerequisites for whole-system closed-loop cycle comparison.

---

### Phase 0 — Spatz closed-loop bring-up **[DONE — committed core `3d712809`, pulp `d8abb08`]**

- **Status.** ✅ **Complete.** The post-rebase hang (a 4-bug cascade: no data modelling / write-back invisible to HTIF / refill-address rewrite deadlock / LSU synchronous-slave protocol) plus a wide-access interco-split data bug were root-caused and fixed. `examples/spatz/test-riscvTests-vfadd` with `use_insitu_cache=True` passes all 15 TCs (`retval=0, cycles=58001`). The fixes are gated to the cluster config (`carry_data_ = inline_sync_miss || functional_writethrough`, set only at the `snitch_cluster.py` site) so the open-loop calib is byte-identical.
- **What this leaves open (now owned by later phases, NOT Phase 0).** The basic closed-loop path runs, but two real limitations remain before *meaningful* closed-loop cycle comparison: **(1) DMA/cache incoherence** — the cluster DMA writes TCDM banks directly, bypassing the cache; the cache-side `flush_all()`/`i_FLUSH` exists but is **dormant** (not wired to the L1D peripheral), so any DMA-staging kernel serves stale lines → **owned by Phase 4** (flush/sync). **(2) Topology** — the GVSoC `spatz` target is a single flat tile of 2 cores / 4 address-interleaved controllers, not 4 tiles × 4 per-core caches with a shared-bank substrate → **owned by Phases 1–2**.
- **Residual hardening (small, optional).** Confirm the inline-miss path stays exactly OK-only on every LSU type (FpuLsu/AraVlsu) as new behaviour lands; keep `vfadd` (and add `dp-fconv2d`) as a closed-loop smoke gate in CI.
- **Validation (the gate that now exists).** Closed-loop smoke: `gvsoc --target=spatz --target-property use_insitu_cache=True --binary examples/spatz/test-riscvTests-vfadd run` ⇒ 15/15 PASS, `cycles=58001`. Open-loop: full calib suite unchanged. Both must stay green through every later phase.

---

### Phase 1 — Structural per-core controller refactor: single wide-line cache + structural `par_coalescer` + scalar `bypass_xbar` (item **a**) **[CL-PREREQ]**

- **Objective.** Replace the v1 per-core topology (N narrow controllers + hashed N→M crossbar + N write-through coalescers) inside *one core's* path with the **current RTL `cachepool_cache_ctrl` structure**: a parallel coalescer over the 4 Spatz VLSU lanes (`par_coalescer`, ExtFactor=1 equal-window), a 2:1 `reqrsp_xbar` merging the Snitch scalar **bypass** path, one **single 512b-wide** cache, and the **refill burst / writeback** FSM (BurstLength=4). This is the documented Phase-B refactor (architecture_v2 §0/§1/§11) and the structural foundation everything else hangs off.
- **Work items (files).**
  - New/rewritten `core/models/cache/insitu/insitu_cache_controller.{cpp,py}` to model **one wide cache** (4-way × 128-set × 512b line, hash-way) per core instead of 4 narrow controllers. Keep the calibrated latency stack-up (10/7 hit, MemLatency+17 miss) intact.
  - Promote the interco's `enable_input_coalesce` latency-window trick to a **structural coalescer** component: CSHR 1-cycle window keyed on `{write, line-tag}` (R/W never merge), `hitmap`/`ofsts` per-port, per-port depth-4 FIFOs, round-robin next-window tag pick, `rsp_spliter` fan-out with per-port backpressure. Misses now coalesce (cold 4-port 128→32 mem reads must hold structurally, not by knob). New file e.g. `insitu_cache_par_coalescer.{cpp,py}`.
  - Structural **scalar bypass**: 2:1 merge (coalesced VLSU + Snitch scalar), word pad-on-write / extract-on-response by `addr_offset`, `bypass_coalescer` flag carried end-to-end. Replaces the latency-only `scalar_bypass_port` knob.
  - **Refill burst FSM**: model the 3-state Idle→Partial→Refill reassembly (4×128b beats, fast-path Refill→Partial) and the 2-state Read→Write writeback serialization (BurstLength single-beat writes, `write_strb_is_zero` drop), plus the **single-outstanding-read** gate (`refill_read_outstanding_q`). Fold today's `defer_refills`/`refill_drain_cycles` into this.
  - `insitu_cache_tile.py` / `insitu_cache_config.py`: switch `make_cachepool_512_config` from `num_controllers=4` to **one wide controller per core**; retire the per-controller hash interco for the intra-core path.
- **RTL feature it closes.** `cachepool_cache_ctrl` structural unit; structural `par_coalescer` (CSHR/FIFOs/hitmap/rsp_spliter); Snitch 2:1 bypass xbar; refill burst/writeback FSM; single-outstanding-refill serialization made structural.
- **Dependencies.** Phase 0 (for closed-loop acceptance). Open-loop work can proceed in parallel with Phase 0.
- **Effort.** L (largest single piece; effectively a model rewrite of the per-core datapath).
- **Risk.** High: must reproduce *all* of §1's locked numbers after the rewrite; the coalescer FIFO depths and the single-outstanding gate are the throughput-critical pieces.
- **How to validate.**
  - Open-loop (primary gate): full calib suite via `insitu_cache_calib` — warm hit 10/7, cold miss MemLatency+17, miss throughput ≈1/(MemLatency+17), 1-port hit ceiling 0.86, **coalescer warm ≈4×**, **cold 4-port 128→32 mem reads** (now structural), write 0.49/8 cyc, RAW 7 cyc, eviction +10%. Diff per-access `latency` column vs `results_memlat{10,50,100,200}.csv`.
  - Closed-loop (acceptance): the 4 real kernels already at +2.6..+6.4 (per `insitu_cache_gap_state.md`) must not regress; `fdotp` miss (+62.7) is the known-inherent outlier.

---

### Phase 2 — Tile/Group composite: programmable-mapping interco + remote/inter-tile xbar + partitioning (item **b**) **[CL-PREREQ — the central closed-loop gap]**

- **Objective.** Model the **fully-shared L1 banking** that the model currently *entirely lacks* (per `gvsoc-model-side`: "the cross-tile fully-shared-banking microarchitecture is ABSENT"). Build the tile = 4 cores × 1 wide controller + the **5 per-lane `tcdm_cache_interco` crossbars** (each 4-core + 1 remote-in → 4-bank + 1 remote-out), the **programmable bank address mapping** (`dynamic_offset`, BankSel/TileID fields), the **runtime private/shared partition** (`num_private_cache`, modulo folding, `private_start_addr`), the **address rotation + refill inverse-rotation**, and the **group-level inter-tile remote xbar** (5 per-port-class `reqrsp_xbar`, PipeReg=1/RspReg=1).
- **Work items (files).**
  - New `insitu_cache_tcdm_interco.{cpp,py}`: per-lane (NumCores=4 + 1 remote)×(NumCache=4 + 1 remote) crossbar with `addr_bank = addr[dynamic_offset +: 2]`, `addr_tile = addr[dynamic_offset+2 +: 2]`, per-output round-robin arbitration (rr_arb_tree), input request spill (+1 cyc) + output fall-through response (0 cyc). Local-vs-remote routing by `addr_tile == tile_id`.
  - Runtime partition logic: `num_private_cache` register (private/shared modulo fold), `private_start_addr` per-request classify, exposed as config / CSR-writable.
  - Address rotation to MSB on the bank side, inverse rotation on the refill path (so each cache sees a dense index).
  - New `insitu_cache_group.{cpp,py}`: NumTiles=4 tiles + 5 per-port-class inter-tile `reqrsp_xbar` (the +1 req / +1 rsp remote-hop latency; `dst*N+src%N` request select, `tile_id*N+t%N` response select so req/rsp share a master port).
  - `insitu_cache_tile.py`: assemble 4 controllers + 5 intercos + the per-(cb,j) request spill (+1) / response spill (0) decouple registers; AMO shim slot on lane j=4 only (Phase 5).
  - `insitu_cache_config.py`: new `InsituCacheTileConfig`/`InsituCacheGroupConfig` fields (num_tiles, num_cores_per_tile=4, num_remote_ports, dynamic_offset default 14, num_private_cache, private_start_addr 0xA000_0000).
- **RTL feature it closes.** Cross-tile fully-shared L1 banking; `tcdm_cache_interco` programmable mapping + partition; remote-port + inter-tile group xbar; address rotation/inverse. This is the *single biggest determinant* of whole-system cycles (cross-core bank contention, remote-tile 1-req/cyc/port-class cap, partition mode), and is the reason the model cannot currently do faithful 16-core closed-loop.
- **Dependencies.** Phase 1 (needs the single-wide controller as the bank endpoint). Phase 0 (closed-loop). **Hard prerequisite for any multi-core / 16-core closed-loop comparison.**
- **Effort.** L.
- **Risk.** High: arbitration fairness (round-robin vs fixed-priority in `reqrsp_xbar` — open question in the map), remote-pipeline ordering invariant (all traffic to a remote tile funnels through one pipeline to preserve write-before-read), and the spill-register latency accounting all directly move closed-loop cycles.
- **How to validate.**
  - Open-loop: single-tile single-core path must still reproduce all §1 numbers (interco adds the known +1 cyc already in `interco_latency_cycles`).
  - Closed-loop (acceptance): a multi-core Spatz kernel with **bank contention** (e.g. shared-buffer stencil) compared vs RTL cluster cycles; sweep `dynamic_offset` and `num_private_cache` and confirm the model tracks RTL trend (private vs shared, interleave granularity). Confirm remote-tile bandwidth caps at ~1 req/cyc/port-class.

---

### Phase 3 — Per-resource outstanding / MSHR-occupancy caps (item **c**)

- **Objective.** Make the FIFO/occupancy caps that bound sustained throughput *real* and *enforced*, replacing the cyclestamp approximations: miss/evic/retr/resp/winfo FIFO depths (4/4/16/4/4), the in-situ MSHR subarray cap (`NumSubarray` → MSHR_FULL_STALL), the per-port requester budget (NumSpatzOutstandingLoads=32, Snitch=16), and the single-outstanding-refill gate (now from Phase 1).
- **Work items (files).** `insitu_cache_controller.cpp`: enforce `resp_fifo`/`wt_fifo` levels (currently read but never enforced — `gvsoc-model-side` "levels never enforced"); add MSHR subarray counter per pending line with MSHR_FULL_STALL behaviour; model the per-port outstanding-load budget (32 VLSU / 16 scalar) as the Little's-law throughput bound. `insitu_cache_config.py`: surface the depths and the per-port budget. `insitu_cache_tile.py`: the per-lane Spatz response reorder FIFO (depth 32) at the CC boundary.
- **RTL feature it closes.** winfo/resp FIFO occupancy + RESP_STALL; in-situ MSHR subarray-full escalation; per-port outstanding budget (the limit that dominates miss bandwidth once the refill gate is removed in the BurstLength=1 regime).
- **Dependencies.** Phase 1 (FIFOs live in the wide controller). Light coupling to Phase 2 (xbar backpressure interacts with FIFO-full denials).
- **Effort.** M.
- **Risk.** Medium: over-enforcing depths can *introduce* new stalls that break the calibrated 0.86/0.49 ceilings — must be gated and tuned against the calib injection-gap sweep.
- **How to validate.** Open-loop: injection-gap sweep (gap 0/1/3/7 → 0.865/0.467/0.243/0.124) and the depth-4 throughput knee; the `mshr_depth_1p` calib phase (max_outstanding pegs at 32). Confirm BurstLength=1 experiment (if run as a side validation) becomes requester-budget-bound at ~32/(MemLatency+13) above the crossover.

---

### Phase 4 — SPM partition + flush/sync FSM wired to the L1D peripheral (item **d**) **[CL-PREREQ for any kernel that flushes/uses SPM]**

- **Objective.** Replace the behavioural drop-all `flush_all()` and the capacity-shrink SPM fold with the real **cache_sync** control: the 4-op `cache_sync_insn` (00 flush+inval / 01 flush / 10 inval / 11 init), the set-walk flush FSM with per-dirty-line writeback, the **CHECK_PEND drain interlock** (outstanding_refill_cnt==0 stable for CheckPendDrainCycles=20, `sync_block_upstream`/`sync_block_install` gating), the peripheral CSR delivery (`l1d_insn`/`tile_sel`/lock/busy), and the SPM division-remap (`bank_depth_for_SPM`, tag=addr/cache_part_sets, set=…%cache_part_sets+SPM_base).
- **Work items (files).** `insitu_cache_controller.cpp`: a real flush/sync FSM (set-walk, per-line writeback through the eviction path, clear meta), the 20-cycle pre-flush drain bubble, upstream gating during sync; wire `enable_flush` (currently read but **never referenced** in logic) into actual behaviour; SPM arithmetic remap behind `enable_spm`. `insitu_cache_tile.py` + a new `insitu_cache_peripheral.{cpp,py}`: the CSR block (XBAR_OFFSET, CFG_L1D_INSN, CFG_L1D_TILE_SEL, L1D_PRIVATE, L1D_ADDR, INSN_COMMIT, FLUSH_STATUS, SPM_COMMIT), per-tile lock, `l1d_busy` gating of core+remote ports during flush. `insitu_cache_config.py`: SPM + sync knobs.
- **RTL feature it closes.** cache_sync 4-op flush/invalidate/init; sync↔install drain interlock (CHECK_PEND=20); SPM tag/set division-remap + partitionable_flushable wrapper; flush back-pressure (busy gating). These are required for any closed-loop kernel that issues a flush or uses scratchpad-stack — and the flush bubble + busy-gating directly affect whole-system cycles.
- **Dependencies.** Phase 2 (peripheral drives all tiles; `dynamic_offset`/`num_private_cache` CSRs live here). Phase 1 (writeback path). Phase 0 (closed-loop).
- **Effort.** M (FSM + CSR plumbing; the drain interlock is the fiddly part).
- **Risk.** Medium: the CHECK_PEND drain and upstream gating can deadlock closed-loop if the install/refill bookkeeping isn't airtight; keep behind a flag and default to today's drop-all flush until validated.
- **How to validate.** Open-loop: the calib TB ties sync/SPM off, so this is **closed-loop-validated** — a Spatz kernel that issues `l1d` flush and reads back, compared vs RTL flush latency (≈(CacheBankDepth−SPM_sets) + per-dirty-line writeback + 20-cyc bubble). SPM: a kernel using scratchpad-stack with `bank_depth_for_SPM`>0, confirm cacheable set count shrinks and timing tracks RTL.

---

### Phase 5 — AMO / LR-SC at the tile (item **e**)

- **Objective.** Model atomics where RTL puts them — the **tile-level `spatz_cache_amo` shim on lane j=4 only** (Snitch scalar port), *not* in the controller. 4-state FSM Idle→DoAMO→WriteBackAMO→Wait (read-modify-write serialized across bank round-trips), LR/SC reservation table, `is_amo` response filtering.
- **Work items (files).** New `insitu_cache_amo.{cpp,py}` instantiated in `insitu_cache_tile.py` on the scalar lane only (VLSU lanes bypass). Reservation single-entry (addr+core), SC success = reservation valid & same core & same addr; foreign write/AMO clears it. `insitu_cache_config.py`: enable flag.
- **RTL feature it closes.** AMO RMW serialization (holds the scalar port for read+compute+write+wait), LR/SC reservation — currently **absent** in the model (and correctly absent from `cachepool_cache_ctrl`).
- **Dependencies.** Phase 2 (tile composite + lane indexing). Phase 0 (closed-loop). Phase 1 (controller is the bank the AMO reads/writes).
- **Effort.** M.
- **Risk.** Low–Medium: contained shim; main risk is the multi-round-trip latency accounting and reservation correctness under cross-core contention.
- **How to validate.** Closed-loop only (calib TB has no AMO): a Spatz/Snitch kernel using `amoadd`/LR-SC (e.g. a spinlock or atomic accumulator), compared vs RTL for both correctness (SC success pattern) and the per-AMO cycle cost (≥ read+compute+write+wait round trips).

---

### Phase 6 — Bank-conflict modelling (item **f**)

- **Objective.** Model the intra-controller and intra-tile bank conflicts that the current per-set cyclestamp collapses away: the pseudo-dual-port **WR_CONFLICT** 1-cycle read-replay (same pseudo-bank, different row), the **folded/skewed data-bank write-priority grant** (`l1_data_bank_gnt` — a read sharing a column with a concurrent write is degranted/dropped → replay), and the forwarding-buffer same-bank interactions.
- **Work items (files).** `insitu_cache_controller.cpp`: per-pseudo-bank (BankFactor=2 → low set-bit selects bank) read/write conflict → +1 cyc replay; folded-bank per-column write-priority grant with read degrant→replay (the source of the ~0.25 miss/cyc cap in the BurstLength=1 regime, and a real-kernel timing contributor). `insitu_cache_config.py`: BankFactor, PartSplit, fold-mode knobs already present — wire them to behaviour. Promote the flat `folded_evict_penalty_cycles` knob to the structural folded-read where it matters.
- **RTL feature it closes.** WR_CONFLICT bank-conflict penalty; folded/skewed write-priority grant + dropped-read replay; pseudo-dual-port R/W FSM behaviours.
- **Dependencies.** Phase 1 (the wide controller's bank model). Benefits from Phase 2 (cross-core same-bank pressure is where conflicts actually bite in closed-loop).
- **Effort.** M.
- **Risk.** Medium: bank conflicts are second-order for the calibrated open-loop numbers (which are mostly conflict-free streams) but can matter a lot for real strided kernels; easy to over-model and regress the hit ceiling. Gate it.
- **How to validate.** Open-loop: a strided/conflicting trace through the calib TB (the suite's multi-port disjoint-stripe vs same-bank phases); confirm WR_CONFLICT shows the 1-cyc replay and folded-bank degrant matches. Closed-loop: a bank-conflict-heavy Spatz kernel vs RTL.

---

### Phase 7 — Async-Spatz-model readiness (item **g**)

- **Objective.** Ensure the model is correct under an **asynchronous / out-of-order Spatz** front-end (responses returning out of program order across the 4 controllers and per-controller MSHRs), which the per-lane depth-32 reorder FIFO in the CC already assumes. This is forward-looking robustness for when the Spatz model issues independently per lane.
- **Work items (files).** `insitu_cache_controller.cpp` + `insitu_cache_tile.py`: confirm response association is by carried info (way/depth/req_id), not program order; ensure the per-lane reorder FIFO (Phase 3) and the response routing (`user.core_id`/`req_id`) handle out-of-order completion; stress hit-under-miss / miss-under-miss to a single bank. Possibly a `tcdm_id_remapper`-style ROB if a merged stream needs reorder IDs.
- **RTL feature it closes.** Out-of-order multi-bank response handling; per-lane outstanding-load reorder; hit-under-miss/miss-under-miss correctness.
- **Dependencies.** Phases 1, 2, 3.
- **Effort.** S–M (largely validation + hardening of mechanisms built earlier).
- **Risk.** Low (correctness hardening), but uncovers latent re-entrancy bugs (cf. the Phase 0 hang class).
- **How to validate.** Closed-loop: an out-of-order-issue Spatz kernel (independent loads across lanes hitting different banks) runs correctly and tracks RTL cycles; no hangs. Open-loop: the calib coalesced/multiport phases unaffected.

---

## 4. Quick wins vs large refactors

| Item | Phase | Size | Quick win? | Why |
|---|---|---|---|
| Spatz closed-loop bring-up | 0 | — | ✅ **DONE** | Already fixed & committed (core `3d712809`, pulp `d8abb08`); vfadd 15/15, cyc=58001. |
| Enforce per-resource caps + per-port outstanding budget | 3 | M | **Quick win** (subset) | The miss/evic/retr FIFOs are already counted+gated (cheap to tighten). NOTE: `resp_fifo_level_` is declared/reset but **never incremented**, and there is **no `wt_fifo_level_`** — those counters must be wired up (increment on push / decrement on drain) before they can be enforced, so it's slightly more than a pure "enforce" edit. Then add the 32-VLSU / 16-scalar per-port budget. |
| Wire `enable_flush` into actual behaviour | 4 | S | **Quick win** (subset) | Flag exists but is dead code today; small step toward real sync. |
| AMO/LR-SC tile shim | 5 | M | Medium | Self-contained new component on one lane; no controller surgery. |
| Bank-conflict penalties (WR_CONFLICT + folded grant) | 6 | M | Medium | Localized to controller bank model; knobs already present. |
| Structural `par_coalescer` + scalar `bypass_xbar` | 1 | L | **Large refactor** | Replaces interco latency-trick with real CSHR/FIFO/rsp_spliter + 2:1 xbar; misses must coalesce structurally. |
| Single-wide controller + refill burst FSM | 1 | L | **Large refactor** | Core datapath rewrite; must re-hit every locked open-loop number. |
| Tile/Group shared-bank substrate (5 intercos + remote + group xbar + partition) | 2 | L | **Large refactor** | The biggest closed-loop determinant; entirely absent today. |
| SPM division-remap + flush/sync FSM + peripheral CSR | 4 | M–L | Medium–Large | New FSM + CSR block + drain interlock. |
| Async-Spatz hardening | 7 | S–M | Medium | Mostly validation of earlier mechanisms. |

## 5. Sequencing recommendation

**Phase 0 is done** (closed-loop runs; vfadd 15/15). So the real "do next" is **Phase 1**, the open-loop structural refactor (single-wide controller + structural par_coalescer + bypass_xbar + refill burst FSM). Its validation is open-loop (does not need any further closed-loop work) and it is the structural foundation for Phases 2–6. Land Phase 1 only once the full calib suite is green (no regression on the §1 locked numbers), because everything downstream builds on this controller. Keep the `vfadd` closed-loop smoke test green throughout.

**Then Phase 2 (Tile/Group shared-bank substrate).** This is the central closed-loop gap — the model has *no* cross-tile sharing today — and is the dominant determinant of 16-core cycle accuracy. It needs Phase 1's wide controller as the bank endpoint and Phase 0 for acceptance. After Phase 2 you can do the *first meaningful multi-core closed-loop comparison*.

**Phase 3 (caps)** slots in right after/with Phase 2 — small, high-fidelity, and it's where the FIFO-depth and 32-outstanding throughput bounds become real (and interact with xbar backpressure).

**Phase 4 (SPM + flush/sync + peripheral)** next, because real kernels issue flushes and use scratchpad-stack; the flush bubble and busy-gating are closed-loop-visible.

**Phases 5 (AMO) and 6 (bank conflicts)** are independent, lane-/controller-local refinements — schedule by which closed-loop kernels you need (AMO for atomics/sync kernels, bank-conflict for strided kernels). **Phase 7** is the final hardening pass once the async Spatz model lands.

Rationale in one line: *fix the gate (0) → rebuild the per-core datapath structurally and prove it open-loop (1) → build the sharing substrate that closed-loop actually needs (2) → enforce the real caps (3) → add control-plane (4) → refine atomics/conflicts (5,6) → harden async (7).*

## 6. Risks & open questions

- **Closed-loop DMA/cache incoherence (the real residual from Phase 0, owned by Phase 4).** Phase 0 is done (vfadd passes), but the cluster DMA writes TCDM directly, bypassing the cache, and `flush_all()`/`i_FLUSH` is implemented yet **dormant** (not wired to the L1D peripheral) — so any DMA-staging kernel will read stale lines. *Mitigation:* Phase 4 wires the flush/sync FSM to the peripheral; until then, restrict the closed-loop kernel suite to cache-unaware kernels (like vfadd) and treat DMA-staging kernels as Phase-4 acceptance gates.
- **Calibration regression risk on the Phase 1 rewrite.** The locked open-loop numbers were tuned against the v1 latency stack-up; a structural rewrite can drift them. *Mitigation:* keep the calibrated latency knobs (hit/streaming/miss/write/RAW) as the per-access targets and treat the calib CSV diff as a blocking CI gate on every Phase-1 commit.
- **`reqrsp_xbar` arbitration policy is unconfirmed** (round-robin LockIn vs fixed-priority; `slv_rr_i/mst_rr_i` tied to 0) — this directly affects cross-core fairness and closed-loop cycles in Phase 2. *Open question:* read `reqrsp_xbar.sv` arbitration before committing the interco arbitration model.
- **`dynamic_offset` runtime value** (peripheral default 14 vs software-reprogrammed at boot) changes bank striping in any cycle model. *Open question:* confirm what the CachePool SDK boot code programs before kernels run (Phase 2/4).
- **Exact MSHR `NumSubarray` value** depends on the cluster's `info_t` width (not resolvable from the cache files alone). *Open question:* read `cachepool_cache_ctrl`/`cachepool_pkg` to fix the merge depth before Phase 3 enforces MSHR_FULL_STALL.
- **BurstLength=4 (shipping) vs BurstLength=1 (experiment branch).** The shipping config is single-outstanding-serialized; the experiment removes the gate (7–14× miss speedup, then bank-/budget-bound). *Decision (stance B):* calibrate and validate against BurstLength=4 first; treat BurstLength=1 as a *separate* validation target, not the default — do not let it leak into the default factory.
- **`fdotp` inherent miss-throughput gap (+62.7).** Per `insitu_cache_gap_state.md` this is inherent to the streaming-miss pattern; the structural refactor (Phase 1) and single-outstanding modelling may or may not close it. *Open question:* re-measure `fdotp` after Phase 1; if still large, document as a known model limitation rather than chasing it with a kernel-specific knob.
- **Over-modelling second-order effects (Phases 6/3).** Bank conflicts and FIFO caps are easy to over-apply and regress the hit/write ceilings. *Mitigation:* every such behaviour gated default-off and validated against the injection-gap and multiport calib phases before enabling in the production factory.
- **Closed-loop acceptance needs a curated kernel set.** There is no open-loop check for sharing topology, SPM, flush, or AMO — those are *only* validatable closed-loop. *Open question:* assemble a small RTL-vs-GVSoC kernel suite (bank-contention stencil, flush+reload, SPM-stack, atomic accumulator, out-of-order multi-lane) with RTL reference cycle counts to serve as the Phase-2/4/5/6/7 acceptance gates.
