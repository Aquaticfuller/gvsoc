# CachePool InSitu-Cache GVSoC Model — Prioritized Architecture-Gap Document

Date: 2026-07-26. Scope: the `cachepool_v2` / Spatz-cluster deployment path (`pulp/cachepool.py` → `snitch_cluster.py` → structural `InsituCacheCore` with `inline_sync_miss=True`), against RTL `dev/multi-group` @ `05e4671a`. Synthesized from six subsystem reviews (structural-core, coalescer-vlsu, xbar-routing, l2-dram-path, soc-cluster, amo-atomics, hash-partition-flush) with adversarial verification of the top claims.

---

## 1. Executive summary

**Fidelity posture.** The model is data-correct on all 8 CI kernel families and the cache controller is genuinely calibrated at the microarchitectural point the calibration harness can see: isolated hit/miss latency, refill occupancy, write-throughput knobs (match the standalone RTL calib TB within a few cycles). The hash-way decode is bit-for-bit RTL-exact in the deployed structural core, the topology transcription (lane xbars, remote xbar, AMO lane, barrier wiring) was verified line-by-line, and AMO/LR-SC *data* semantics match `spatz_cache_amo.sv` rule-for-rule.

**But the timing the cluster actually experiences is structurally unfaithful in ~20 places**, and the errors are not random — they are almost all in the *optimistic* direction, they grow with core count and memory pressure, and the single largest one (vector traffic is timing-invisible) masks most of the others. The current 8-kernel cycle agreement therefore cannot be credited to the backing path or the contention model: errors partially cancel (too-fast isolated refills vs. too-slow aggregate bandwidth; zero-latency vector loads vs. a 4 B/cyc-serialized backing store).

**The five findings that matter most, ranked:**

| # | Gap | Severity | Why it dominates |
|---|-----|----------|------------------|
| 1 | VLSU commits sync-OK bursts at issue, discarding all calibrated cache latency (`spatz_vlsu.cpp:338-348`) | critical | Every vector load/store has ~0-cycle load-use distance; makes gaps 2–5 below invisible on deployed kernels. The root masker. |
| 2 | MSB address rotation disabled → per-bank set-index aliasing collapses effective capacity 16× at 16-core (`insitu_cache_tile.py:184`) | critical | First-order *miss-rate* corruption, not a latency knob. fdotp-M32768: 16 KiB/bank footprint fits RTL's 64 KiB/bank, thrashes the model's 4 KiB/bank. Invisible to the capacity-insensitive calib TB. |
| 3 | No per-cell / per-xbar-output serialization in the deployed sync path (`run_request_sync`, `insitu_cache_xbar.cpp:93-115`) | critical (structural) / high | The shared-L1 contention effect — the design point of CachePool — is erased. Up to 20 lookups/cycle complete at one cell; RTL sustains 1. |
| 4 | "Uncached" 0xA0000000 region (all `.data` + `.pdcp_src` kernel inputs) bypasses the cache over a shared 8 B/cyc narrow link; RTL caches the whole 1 GiB | critical | The dominant streaming traffic of the CI kernels runs on a different machine than the RTL — 1–2 orders of magnitude bandwidth error on the hot path, and the cache sees none of that traffic. |
| 5 | Flat single-port zero-latency 4 B/cyc backing store vs. RTL's 4-channel scramble/NAPOT + per-channel DDR4 | critical | No channel parallelism, no 20:4 arbitration, no DRAM timing; the calibration anchor (ML=50) is ~3× the production path's delivered latency. |

Everything else — PEND-line semantics, write-miss acks, dirty-eviction cost, flush, CSRs, coalescer merge, AMO timing, issue-side geometry — is a P1/P2 correction layered on top of these.

**Two review claims the verifier flagged as overstated (reported honestly in §2):**
- "Write misses hold a VLSU outstanding slot for ML+17, collapsing store bandwidth" — *as written, wrong today*: the VLSU commits at issue and never holds a slot, so vector stores are currently *free* (under-charged). The over-charge is live only for the scalar LSU; it materializes for vector traffic only after finding #1 is fixed.
- "Early-VALID install frees VLSU outstanding slots ~ML early" — *moot today* for the same reason; live now only for the scalar LSU, first-order after finding #1.

**One cross-review contradiction resolved:** the hash-partition-flush review states no CI kernel calls `l1d_part`; the xbar-routing review (verdict CONFIRMED) shows `load-store/main.c` runs its main phases at `part=2` (`:253,:278,:318,:342`). Trust the latter.

---

## 2. The gaps, grouped by implementation theme

Gaps are grouped by *the fix they need*, not the subsystem that reported them — several fixes close findings from three reviews at once. Each entry: model / RTL / impact / severity / plan.

### Theme A — Make vector traffic consume cache latency (the root masker)

#### A1. VLSU sync-OK path commits at issue and discards all calibrated latency — CRITICAL
- **Model:** on `IO_REQ_OK` the burst pops args, returns the req to `req_queues[i]`, and calls `insn_commit()` in the issue cycle (`spatz_vlsu.cpp:338-348`). `get_full_latency()` appears nowhere in `spatz_vlsu.cpp` (the scalar `lsu.cpp:154,213-240` does consume it — the asymmetry is real). The FSM issues 1 burst/port/cycle (`:278-385`); the only vector memory timing is a +5-cycle start delay (`:145`). The `:92-97` comment documents commit-at-issue as fixed for the async path only.
- **RTL:** every burst books a per-port ROB entry that completes only when `spatz_mem_rsp_valid_i` returns (`spatz_vlsu.sv:181-182`, `:48`, `:169`): ~10 cy hit, ML+17 cold miss; VRF writeback and scoreboard release at response time.
- **Impact:** every vector load/store is zero-latency: dependent vector instructions start at issue, cold-miss streams run at full pin rate, the VLSU queue never backs up. Several-x optimistic on memory-bound kernels; masks Themes B, C, D below.
- **Plan:** port the delayed-commit scheme from the sibling Ara VLSU (`ara_vlsu.cpp:226-238`: on OK with latency>0, push into `delayed_bursts` with timestamp = now + `get_full_latency()`, commit + return to port queue at timestamp). Keep the req out of `req_queues[i]` until its timestamp so `nb_outstanding_reqs=8` (`ara.py:87`) re-creates ROB backpressure. ~1–2 days; re-run the 8 CI kernels + calib TB.

#### A2. VLSU lane burst is 8 B/cycle vs RTL's 4 B/cycle lane — HIGH
- **Model:** `spatz_lane_width=8` hardcoded (`snitch_cluster.py:224`) → `vu/lsu_width=8` (`ara.py:83`); each burst moves `min(8B, pending)` (`spatz_vlsu.cpp:294`) = 32 B/cyc/core; per-lane vico bandwidth also 8 (`snitch_cluster.py:421-426`).
- **RTL:** each Spatz memory port is ELEN=32b (`cachepool_fpu_512.mk:16` → `spatz_pkg.sv:31,44`); 4×4 B beats/cycle = 16 B/cyc/core pin peak. The par_coalescer merges the 4×4 B into one 128b beat, so the pin rate (not the cache port) is the limit.
- **Impact:** 2× optimistic floor on every throughput-bound vector phase, persisting after A1/B/C are fixed. Also `nb_outstanding_reqs=8` vs RTL `spatz_max_trans=32` (`cachepool_4t_fpu_512.mk:72`) — 4× less MLP under async completions.
- **Plan:** set `spatz_lane_width=4` (+ vico bandwidth 4, + `nb_outstanding_reqs=32`) for the cachepool target; if the ISS compute model needs 8B lanes, split each 8B burst into two 4B beats on consecutive cycles in the fsm (`spatz_vlsu.cpp:286-336`). ~1 day + calib-TB re-validation (expect 16 B/cyc/core sustained on warm unit-stride hits).

### Theme B — Serialization tokens: the missing 1-access/cycle resources (one idiom, four sites)

All four sites need the same `busy_until` accept-stamp idiom the codebase already uses (`write_commit_busy_until_`, `insitu_cache_core.cpp:100,304-308`). **Verifier caveat (applies to B1/B2):** for a unit-stride single-core stream the RTL's coalescer merges 4 same-part lanes into ONE access serving all 4 words, so raw per-core unit-stride bandwidth is roughly parity — the erased effect is *queueing delay and different-line/cross-core contention*, which is what these fixes restore. Land B1+B2 together with Theme C's merge or the model swings from unboundedly optimistic to ~4× pessimistic on unit-stride streams.

#### B1. No per-cell request serialization in the deployed sync path — CRITICAL (structural)
- **Model:** `run_request_sync` resolves each request in-call touching no shared state (`insitu_cache_core.cpp:290-327`); all 5 cell input ports share one handler (`:217-231`); the port-class xbar is a pure forwarder (+1 cy, no arbitration; `insitu_cache_xbar.cpp:93-115`). With `cell_coalescer=False`, up to 16 VLSU + 4 scalar lookups (4 cores share each xbar output) can complete at one cell in one cycle. The async per-cycle path *does* serialize via `stage0_arbitrate → preread_q_` (`:635-649`) — only the deployed sync path lacks it.
- **RTL:** one 1-deep req_buf + `stream_arbiter i_pre_reader_arbiter` (`insitu_cache_core.sv:894-903`), `upstream_req_ready_o=0` when occupied (`:908`), one task/cycle in REQ_PROC (`:1548`); 4 VLSU lanes funneled through `i_par_coalescer_for_spatz` (`cachepool_cache_ctrl.sv:344-380`) and the 2:1 `i_bypass_xbar` (`:454-496`). Net: ≤1 cache access/cycle/cell with queuing.
- **Impact:** per-cell hit bandwidth over-predicted up to ~4–5× with no queueing under sustained multi-lane/multi-core pressure; error grows with vector width and core count.
- **Plan:** per-cell accept token shared by all 5 ports: `accept = max(now, cell_busy_until)`; latency += `accept - now`; `cell_busy_until = accept + 1`; shared by reads, writes, refill installs; scalar lane at 1:1 RR vs the VLSU aggregate (matching the 2:1 xbar). ~1 day. Requires A1 to affect vector traffic.

#### B2. No per-output arbitration in the lane/remote xbars — HIGH
- **Model:** `insitu_cache_xbar.cpp:93-115` and `insitu_cache_remote_xbar.cpp:73-87` forward unconditionally with a fixed latency add; no grant token, no RR pointer. Two source tiles sharing a remote-in slot (sources 0&2 → slot 0, `cachepool_group.sv:285-295`) collide for free.
- **RTL:** `reqrsp_xbar.sv:96-146` = `stream_xbar` with per-output RR arbiter (LockIn), one grant/cycle/output; losers wait in per-input spill registers (`tcdm_cache_interco.sv:290-302`); remote xbar arbitrates 8×8 the same way (`cachepool_group.sv:399-432`).
- **Impact:** same-bank same-cycle conflicts cost +1/extra request in RTL, 0 in the model — persistent 5–20% throughput overstatement on lockstep streaming phases; worst case lock kernels (16 cores on one line: RTL serializes ~16, model parallel). Always model-faster-than-RTL.
- **Plan:** per-output `busy_until` + RR grant pointer in both xbar classes (the `BypassXbar` RR pattern in `route.hpp` shows the idiom); fold wait into `inc_latency` before forwarding. Then re-calibrate `xbar_latency`/`hit_latency` on the single-tile TB (token never contended there — single-core numbers must not move). ~2–3 days incl. re-calibration. Shares the B1 cell-side cap.

#### B3. No RMW lane occupancy on the bank-shared scalar lane — CRITICAL (AMO)
- **Model:** the AMO shim resolves each RMW atomically in one `req_handler` call (`insitu_cache_amo_shim.cpp:153-168`); the lane is never held busy. A cycle-level `AmoShim` FSM that models the back-pressure exists (`insitu_cache_amo.hpp:120-169`) but is never instantiated.
- **RTL:** `core_ready=0` in DoAMO/WriteBackAMO/Wait (`spatz_cache_amo.sv:236,249,268,294`): from accept until write-back response drains — ~15–20 cy on a hit, full refill time on a miss — no new request on that bank's lane 4 is accepted; lane 4 is shared by ALL cores through the port-class xbar (`cachepool_tile.sv:644-677`).
- **Impact:** contended-atomic throughput per bank: model unbounded vs RTL ~1 RMW/15–20 cy shared across all cores — ~5× over-prediction at 16 spinners, and the model misses the convoy interference on the lock holder's same-lane scalar traffic.
- **Plan:** `rmw_busy_until_` stamp in the shim (mirror `insitu_cache_core.cpp:303-308`): set at RMW start = now + scratch read full latency + 1 + write-RTT knob (~8, new cfg); at `req_handler` entry, any opcode, if `now < rmw_busy_until_` then `inc_latency(rmw_busy_until_ - now)`. ~30 lines + one knob. Fallback: wire the existing hpp FSM (~150 lines) only if accept-stall reorders responses.

#### B4. Retr/resp FIFO backpressure unfaithful — MEDIUM
- **Model:** `resp_fifo_` unbounded, no RespFifoDepth check (`insitu_cache_core.cpp:145,:508,:595-598`; `resp_fifo_depth` not even passed to the core, `insitu_cache_core.py:41-64`) — RESP_STALL can never occur. `retr_level_` counts *readers* against depth 16.
- **RTL:** RespFifoDepth=RetrFifoDepth=4 (`insitu_cache_tcdm_wrapper.sv:66-68`); read hit on full resp FIFO → RESP_STALL freezes the preread pipe (`insitu_cache_core.sv:1562-1584`); retr holds one entry per refilled *line*, drains 1/cycle through the arbiter shared with hits (`:1090-1094,:1147-1156`); refill may enter preread only when `retr_fifo_usage < Depth-2` (`:835-838`), throttling all subsequent misses via `refill_read_outstanding` (`cachepool_cache_ctrl.sv:684`).
- **Impact:** under multi-reader refills the model sails through with a 16-reader allowance and infinite resp sink; compounds with D1 (the sync path currently never creates multi-reader drains at all).
- **Plan:** bound `resp_fifo_` at 4 + stall stage-1 read hits when full; count retr in undrained refilled *lines* (cap 2 at install, mirroring `usage < Depth-2`), decrement as drained readers complete; pass `resp_fifo_depth` into core properties. Async path; pairs with D1.

### Theme C — The coalescer merge (restore the structure that justifies B's serialization)

#### C1. Same-part wide-beat merge + hitmap missing; dormant component keyed on the wrong granule and drops write merge — HIGH
- **Model:** `cell_coalescer=False` (`insitu_cache_config.py:433`; never set by `make_cachepool_fpu_512_config`, `:545-573`, nor the group path, `snitch_cluster.py:289-312`). The dormant component keys the window on the **64 B line** (`insitu_cache_coalesce.hpp:61`); writes pass through individually (`insitu_cache_cell_coalescer.cpp:119`), each paying `write_commit` serialization separately (`insitu_cache_core.cpp:304-308`).
- **RTL:** production folds PartSplit=4 → coalesces on a **128b part** — `CoalescerDataWidth = CacheLineWidth/PartSplit = 512/4` (`cachepool_cache_ctrl.sv:80-81`), tag = `addr[31:4]` (`req_coalescer_v2.sv:217`, DownstreamDataAlign=4), PartSplit=4 from `cachepool_tile.sv:792-807`. Same-cycle same-part same-type lanes merge into ONE 128b beat with hitmap + per-port offsets (`par_coalescer_equal_window.sv:269-304`; write-bit folded into the key `:161-163`); writes merge last-writer-wins (`:279-296`).
- **Impact:** masked today by A1/B1; the moment B1's token exists, the missing merge flips the model ~4× *pessimistic* on unit-stride hit streams and same-part store streams, and over-occupies the bank 4× vs RTL for other cores' traffic. Enabling the current 64B-keyed component would additionally over-merge 4× on part-strided patterns.
- **Plan:** three fixes then enable: (a) key the window on the 16 B part (`line_bytes/4` in folded config; carry `part_idx` through like `cache_ctrl.sv:326-337`); (b) implement the write merge using the existing hpp wide-merge (`insitu_cache_coalesce.hpp:84-91`); (c) route reads through `IO_REQ_PENDING` during the accumulation window — the VLSU already tolerates PENDING/DENIED (`spatz_vlsu.cpp:349-364`); the scalar lane bypasses the coalescer anyway. ~2–3 days incl. validation against the calib TB's coal_warm/coal_cold phases.

#### C2. CSHR window/watchdog and response-split pipeline timing absent — MEDIUM
- **Model:** the cell coalescer batches strictly by arrival cycle (fixed 1-cycle window, no watchdog, no cross-cycle accumulation; `insitu_cache_cell_coalescer.cpp:128-141`); `split_and_resp` (`:192-207`) resp()s all members immediately.
- **RTL:** window closes on the FIRST different-line arrival (`req_coalescer_v2.sv:305-316,382-404`) or after watchdog = number of *unoccupied* ports idle cycles (`:184-206` — a lone lane waits up to 3 cycles); occupy map accumulates across cycles (`:319-338`); +1 req spill (`par_coalescer_equal_window.sv:196-208`), +1 resp spill + 1 per-port resp FIFO (`:320-407`); the splitter holds downstream_ready until every hitmap port accepted (`rsp_spliter_v2.sv:116-137`).
- **Impact:** once C1 lands: cross-cycle-skewed same-line bursts never merge (lost bank-occupancy savings under lane skew); sparse single-lane traffic misses the up-to-3-cycle watchdog hold (~3 cy/line optimistic on gathers). The ~4-cycle pipeline latency is already folded into the calibrated 10-cycle hit.
- **Plan:** replace the arrival-cycle window with a CSHR FSM (close on first different-part arrival or `watchdog_credit = NumPorts - popcount(hitmap)` idle cycles; accumulate occupy map); add explicit +1/+1 req/resp terms; hold the group response until all members' resp() accepted. ~2 days.

### Theme D — PEND-line semantics: MSHR-merge, hit-under-miss, write-miss ack

#### D1. Sync path installs refilled lines VALID in-call — no merge wait for sharers — HIGH
- **Model:** miss allocates READ_PEND/WRITE_PEND and completes to VALID with memcpy'd data in the same call (`insitu_cache_core.cpp:348-389`); only the requester's response is stamped issue+ML+penalty (`:392-397`); the hit-pend/conflict/all-pend branches are dead (`:329`). A follower during the refill window takes an ordinary 10-cycle hit. (The coalescer-vlsu "hit-under-miss" finding is the same gap seen from the lane side.)
- **RTL:** miss allocates a PEND line (`insitu_cache_core.sv:1812`); same-line readers merge as MSHR subarrays and WAIT (`:1632-1762`, non-MRP path `:1725-1762`); `proc_refill` installs (`:2319+`) and merged readers drain 1/cycle through the shared resp arbiter (`:1147-1156`); opposite-type accesses stall in WR_CONFLICT_STALL (`:1799`). Exactly one outstanding refill (`cachepool_cache_ctrl.sv:684,:729`, cleared `:869`).
- **Impact:** cold-line followers complete ~(ML+17−10) cy early each (~6× at ML=50); effective hit rate inflated on shared-line producer/consumer and halo patterns. **Verifier caveat:** the claimed "frees VLSU slots ~ML early" is moot today (VLSU frees at issue, A1); live now only for the scalar LSU, first-order after A1.
- **Plan:** keep the line PEND with `ready_cycle` = the stamped resp_cycle (the analytic controller already has `line->ready_cycle`, `insitu_cache_controller.cpp:526`); a sync access hitting a PEND line gets `inc_latency(ready_cycle - now + drain)`; opposite-type waits then merges; install data/VALID only at `now >= ready_cycle` (or lazily on first touch). ~half a day for the clamp variant; validate with a two-core same-line cold-miss test.

#### D2. Write misses charged full refill latency — RTL acks stores at acceptance — HIGH
- **Model:** the miss branch makes no read/write distinction (`insitu_cache_core.cpp:329-398`): store miss stamped issue+ML+17; async path parks the write in the MSHR until `install_refill` (`:546,:577-589`).
- **RTL:** write responses come from the winfo FIFO pushed AT REQUEST ACCEPTANCE (`insitu_cache_tcdm_wrapper.sv:731`, WRespFifoDepth=4 `:64`); a store — hit or miss — is acked ~2 cy after acceptance; the WRITE_PEND merge with the refill happens inside the cache, invisible to the LSU.
- **Impact:** **verifier caveat — partially wrong as written.** The claim "holds a VLSU slot for ML+17, collapsing store bandwidth" is inverted today: the VLSU commits at issue (A1), so vector store misses are *free*. The over-charge is live only for the scalar Snitch LSU (which consumes the stamp), and materializes for the VLSU only after A1. The cache-level gap is real and correctly characterized.
- **Plan:** for write misses, ack with `write_hit_latency_cycles_` (acceptance latency) + acceptance backpressure when >4 write acks outstanding; do NOT add refill latency to the store response. Keep the line WRITE_PEND with `ready_cycle` (per D1) so a subsequent load stalls correctly; apply store data at ready time.

#### D3. In-situ MSHR capacity unbounded — LOW
- **Model:** `mshr_` unbounded per line (`insitu_cache_core.cpp:142`); hit-pend merges always succeed.
- **RTL:** pending-reader infos live in the line payload, capped at NumSubarray (~9 for the cachepool info_t on a 512b line); the 10th reader enters MSHR_FULL_STALL (`insitu_cache_core.sv:237-253,:1729-1760`).
- **Impact:** only under >9-way pileups on one line (16-core spin/broadcast during a slow refill). Rare in CI.
- **Plan:** cap `mshr_` at computed NumSubarray; stall on overflow, released at `install_refill`. Pairs with D1.

### Theme E — Address mapping: rotation, CSRs, and the 0xA0000000 routing

#### E1. MSB address rotation disabled → 16× effective-capacity collapse at 16-core — CRITICAL
- **Model:** `insitu_cache_tile.py:184` hardcodes `enable_rotation=False`; the rotation call (`insitu_cache_xbar.cpp:105-110`) is dead. Banks receive the raw address with BankSel=addr[7:6], TileID=addr[9:8]; `set_index=addr[6+:8]`, `tag=addr>>14` (`insitu_cache_decode.hpp:55-58`). For any bank in the 4-tile group, addr[6:9] is constant → only 16 of 256 sets used → **4 KiB/bank effective instead of 64 KiB** (64 KiB aggregate of 1 MiB). Single-tile: 16 KiB of 64 KiB.
- **RTL:** `tcdm_cache_interco.sv:320-405` rotates the N routing bits to the MSB on EVERY local-bank request (unconditional, no enable parameter; `bits_to_rotate` table `:363-385`); refill un-rotates before L2 (`:334-336`).
- **Impact:** first-order miss-rate corruption. fdotp-32b_M32768: 256 KiB/16 banks = 16 KiB/bank — fits RTL, thrashes the model → refills AND dirty writebacks inflated ~4×; 1.5–3× cycle error on memory-bound kernels; dwarfs every calibrated latency knob. Invisible to the capacity-insensitive single-tile calib TB — that is why it survived calibration.
- **Plan:** (1) `enable_rotation=True` at `insitu_cache_tile.py:184` (knob + `route.hpp rotate_addr/bits_to_rotate` already implement the RTL mode table); (2) add refill/evict-side unrotation — `insitu_cache_core.cpp:334-335` and refill/evict/functional-WT request addresses through `route.hpp::unrotate_addr()` with the same N (store per-bank). Validate: a 64 KiB/bank footprint shows near-zero conflict misses; then re-run the 8 CI kernels. ~1–2 days. **Must land before any miss-rate or cycle comparison vs RTL is trusted.**

#### E2. `xbar_offset` (dynamic_offset) CSR is a scratch no-op — HIGH
- **Model:** the whole L1D config block is RW scratch with the comment "future: wire to crossbar" (`spatz/cluster_registers.cpp:238,:269-302`); offset frozen at build: `dynamic_offset=log2(64)=6` (`snitch_cluster.py:311` → static property `insitu_cache_xbar.py:53`).
- **RTL:** real committed register (`cachepool_peripheral.sv:71-87`) feeding `dynamic_offset_i` (`tcdm_cache_interco.sv:229-231`); `l1d_xbar_config` clamps ≥6 and flushes before commit (`l1cache.c:8-26`). CI kernels run coarse: fdotp-32b offset=13 at M32768 (`main.c:79-83`), idotp=13, gemv/gemv-opt=8 at M1024; only fft (6) and fmatmul (5→6) match the model.
- **Impact:** bank-interleave granule differs up to 128×: RTL homes each core's contiguous chunk on ONE bank (conflict-free 1:1 streaming — the optimization these kernels were written around); the model sprays every 64 B line across all 16 banks. Compounds with E1 (RTL's coarse chunks are what makes 16 KiB/bank fit) and B2 (the resulting same-bank pressure isn't even charged). Easily tens of percent on the dot-product/gemv family.
- **Plan:** wire the XBAR_OFFSET commit to a runtime setter on all 5 lane xbars of all tiles (`RouteGeom::dyn_offset` is already a runtime field); honor flush-before-commit ordering (needs F1's flush model for dirty safety). The cache cores' `off_bits` stays log2(line) — only routing fields move. ~1 day + revalidation of the 4 affected families.

#### E3. `num_private_cache` / `private_start_addr` CSRs are scratch no-ops — HIGH
- **Model:** `insitu_cache_xbar.py:37-39` → the 4-tile group is ALL-SHARED, frozen at construction; `route.hpp:80-103` implements all three modes with the RTL's modulo folding — never exercised. L1D_PRIVATE/L1D_ADDR are in the scratch block (`cluster_registers.cpp:269-288`).
- **RTL:** `l1d_private_q` (reset 0) and `private_start_addr_q` (reset 0xA000_0000) are live (`cachepool_peripheral.sv:174-175`); `tcdm_cache_interco.sv:144-152,:233-265` muxes all-private/all-shared/mixed at runtime. **load-store CI kernel runs its main phases at part=2 half-half** (`load-store/main.c:253,278,318,342`, boundary via `l1d_addr` `:144`); the other 7 families never call `l1d_part`.
- **Impact:** for load-store the model runs the wrong partition most of the kernel: RTL private-region traffic is local-only (2 banks/tile, no remote hops); the model sprays it across all 16 banks with remote hops. Zero impact on the other 7 kernels. Also blocks evaluating CachePool's headline feature (runtime partitioning).
- **Plan:** same plumbing as E2 (shared work); `route.hpp route_request:85-101` and `bits_to_rotate:113-118` already implement the mode table incl. non-power-of-2 folds; enforce flush-before-repartition. ~1 day shared with E2; re-validate load-store per-phase.

#### E4. 0xA0000000 "uncached" region is actually CACHED in RTL — CRITICAL
- **Model:** `cachepool.py:49-54,:170,:186-187` routes [0xA0000000,0xBFFFF800) around the cache over the narrow AXI (bw=8) into a separate 4 B/cyc-serialized zero-latency memory; VLSU lanes default to narrow_axi (`snitch_cluster.py:424-432` — the comment admits this dodges the M32768 eviction bug). All `.data` and `.pdcp_src` kernel inputs are linked at 0xA0000000 (`common.ld:127-147`).
- **RTL:** one PMA rule base=0x80000000 mask=0xfc000000 makes ALL of 0x80000000–0xBFFFFFFF cacheable (`cachepool_pkg.sv:464-469`); scalar MainMem map and Spatz ports route everything in the DRAM range through the L1 (`cachepool_cc.sv:688-695,:769-787`; no address split on VLSU ports, `cachepool_tile.sv:1435-1441`). 0xA0000000 is the *private-bank boundary*, not an uncached region.
- **Impact:** the dominant streaming traffic of the CI kernels travels a shared 8 B/cyc link into a 4 B/cyc memory in the model vs the calibrated cache + 16×16 B/cyc refill fabric + 4×64 B/cyc channels in RTL — 1–2 orders of magnitude on the hot path (fdotp-8192's 64 KiB of streams: ≥16k cycles vs ~0.3–0.7k). Symmetrically the cache sees none of this traffic: no eviction pressure, no refill occupancy, no cold misses — the sync-slave calibration simply does not apply to the kernels' main data flow.
- **Plan:** fix the M32768 eviction data bug that motivated the bypass, then delete the bypass maps and extend `cache_region` to [0x80000000,0xC0000000) (`snitch_cluster.py:421-432,:439`; `cachepool.py:147`). Interim (if the bypass must stay): move the uncached mapping to the wide AXI and widen/re-latency the backing memory to bound the error. Rerouting is ~10 lines; the cache bug fix is the real work (days).

### Theme F — Flush / reconfiguration is free (four reviews converge on one fix)

#### F1. Flush/sync FSM is a zero-cycle stub despite an existing transcription — HIGH (×4 reviews; the warm-cache bias makes it critical for gemv/fft)
- **Model:** CFG_L1D_INSN/COMMIT/FLUSH_STATUS are 1-cycle scratch with FLUSH_STATUS pinned to 0 (`cluster_registers.cpp:269-307`); the structural core's flush slave is an accept-as-OK stub (`insitu_cache_core.cpp:232-233`); tile/group flush ports exist but are never bound (`insitu_cache_tile.py:239-240`, `insitu_cache_group.py:88-92`; no 'flush' reference in `snitch_cluster.py`/`cachepool.py`); `insitu_cache_sync_fsm.hpp` (faithful 7-state transcription, `kCheckPendDrainCycles=20` at `:62`) is included by no .cpp.
- **RTL:** full chain — peripheral commit latches insn/tile_sel and locks selected tiles (`cachepool_peripheral.sv:144-178`); tile decodes insn per bank and gates ALL core+remote traffic via `l1d_busy_i` (`cachepool_tile.sv:520-599,:883-907`); each bank runs the 7-state FSM: CHECK_PEND waits for a 20-consecutive-cycle drain, then a per-set walk with a serialized downstream eviction per dirty way (`insitu_cache_tcdm_wrapper.sv:282-289,:845-1075`); all upstream blocked for the walk (`sync_block_upstream`, `:722-728`). A clean flush/init costs ~21+256 cycles per bank (banks parallel → ~280 cy wall per tile) plus per-dirty-line evictions; software spins on `l1d_wait`.
- **Impact:** (a) missing stall: every kernel pays flush at startup, gemv/fft pay it mid-run — model charges ~4 cycles; (b) **missing invalidation — the most damaging part**: RTL's gemv/fft flush at iteration 0 leaves the cache cold, so timed iterations ≥1 all miss; the model keeps every line VALID, so iterations ≥1 hit on iteration-0 residue. The reported metric is min-per-iteration cycles (`gemv/main.c:107-115`) → the headline number is biased systematically optimistic, not just total sim cycles; (c) missing dirty-writeback burst on L2 during flush; (d) remote gating (`cachepool_tile.sv:561-599`) absent.
- **Plan:** wire `insitu_cache_sync_fsm.hpp` into `InsituCacheCore`: real `flush_itf_` handler, tick from `tick_event_`; while `busy()` gate `in_q_` admission; `drain_now` = (mshr empty && miss_fifo empty && retr_level_==0 && !preread valid) held 20 consecutive cycles; walk sets issuing an evict-port write per dirty way; drive FLUSH_STATUS busy until the ready pulse; implement the tile-level insn decode from committed `l1d_private`. ~2–3 days. **Stopgap (do this first, hours): charge a fixed 21+num_sets cycles of flush stall and invalidate all lines on any flush insn** — fixes the warm-cache bias without the writeback burst.

### Theme G — L2 / DRAM backing path

#### G1. Flat single-port backing store vs 4-channel scramble/NAPOT mesh — CRITICAL
- **Model:** every controller's refill+evict fans into one tile master (`insitu_cache_tile.py:147-148,:236-238`) → one group 'l2' with zero-timing muxing (`insitu_cache_group.py:84-86`) → one `wide_axi` input (`snitch_cluster.py:451`) → two flat router hops → one `o_MAP(self.i_HBM(), ..., latency=0)` (`cachepool.py:178`) and one `memory.Memory` (width_log2=2 → 16 cycles per 64B line, globally serialized via `next_packet_start`; `memory.cpp:330-341`). The RTL-faithful `insitu_cache_l2_addr.hpp:78-107` (scramble/NAPOT) is **dead code** — included nowhere.
- **RTL:** `scrambleAddr` with Interleave=16 → channel id at addr[11:10] (`cachepool_cluster.sv:604`, `cachepool_pkg.sv:495-516`); NAPOT decode to 4 channels (`:625-652`); 20-input/4-output reqrsp_xbar with PipeReg=1 (`:672-701`); per-channel reqrsp_to_axi MaxTrans=64 + axi_cut (`:726-779`).
- **Impact:** no channel parallelism, no 20:4 arbitration, no per-channel queuing. Under a 16-core miss storm the model's last refill waits ~N×16 memory-occupancy cycles; RTL ~(N/4)×(DRAM service) with bank overlap. Several-x error on miss-heavy phases; the 1 KiB striping also erases row-buffer locality.
- **Plan:** `InsituCacheL2Demux` between group o_L2 and the SoC: instantiate `L2AddrMap` with bank_be_width=64, interleave=16 (NOT the header default 1), `scramble()+channel_of()` per refill/evict → 4 slave ports; 4 memory (or DRAMSys) instances with reverted per-channel addresses (mirror `tb_cachepool.sv:305-313`); model the 20:4 xbar as 1-cycle pipe + RR per channel with shared pending limits ~64. 2–4 days incl. 4-channel calib validation.

#### G2. Idealized memory vs per-channel DDR4 timing — CRITICAL
- **Model:** `memory.Memory('mem', latency 0, width_log2=2)` (`cachepool.py:268`): isolated refill round trip ~18–20 cy. DRAMSys exists (`cachepool.py:264-266`) but the vendored model segfaults (documented OPEN `:262-263`). The occupancy calibration anchored on the standalone TB's ML=50 (`refill_mem_model.sv:61`) — the production path delivers ~3× less than the anchor the +17 miss overhead was tuned against.
- **RTL:** 4 independent DRAMSys DDR4 instances (`tb_cachepool.sv:315-338`, `sim_dram.sv`) at 1 GHz with full tRCD/tRP/tCAS/refresh per channel.
- **Impact:** isolated cold miss ~2–2.5× too fast (~18–20 vs ~35–45+ cy); under load, no row-buffer/bank/refresh effects and a 4 B/cyc global cap vs 4×64 B/cyc channels — streaming phases simultaneously too slow (bandwidth) and too fast (latency); per-kernel errors cancel unpredictably.
- **Plan:** stopgap (hours): `width_log2=6` + explicit latency ~30 calibrated from DRAMSys logs; re-tune miss_penalty against that anchor. Real fix (1–2 weeks): ~300-line per-channel DDR4 timing model (per-bank FSM tRCD/tRP/tCAS/tRFC, FR-FCFS, 64 B/cyc data) ×4 behind G1's demux; or debug the vendored DRAMSys segfault (needs debug build; 10–100× wall-clock cost).

#### G3. 10 MHz SoC clock collapses all ns-based (DRAM) timing 100× — HIGH
- **Model:** `cachepool.py:248`: `frequency=10000000` → 1 cycle = 100 ns; DRAMSys syncs against SystemC ps wall-time (`dramsys_v2.cpp:347`) so tRCD≈13.3 ns = 0.13 cycles.
- **RTL:** `tb_cachepool.sv:33`: ClockPeriod=1.0 ns (1 GHz).
- **Impact:** even with the DRAMSys path fixed, DRAM timing contributes ~100× too few cycles — silently invalidates the DRAMSys calibration path the comments advertise (`cachepool.py:251-253`), independent of the segfault.
- **Plan:** raise the board clock to 1 GHz; audit ns-based properties (none in the insitu path besides DRAMSys); re-run the 8 CI kernels to confirm cycle counts unchanged (everything else is cycle-counted). Hours + validation sweep.

#### G4. Refill concurrency: async completion + eviction write-ack ordering missing — HIGH
- **Model:** per-controller single-outstanding refill is RTL-faithful, but the closed loop completes the refill SYNCHRONOUSLY inside `req()` (`insitu_cache_controller.cpp:643-668`) — no in-flight window; cross-controller interaction only through the flat memory's `next_packet_start`. Dirty eviction is fire-and-forget; `defer_refills_` occupancy is off in the cluster config.
- **RTL:** 16 controllers + 4 bypass ports overlap in the mesh; per-channel MaxTrans=64; a dirty victim costs BurstLength=4 separate acked 128-bit writes, and read-refills serialize w.r.t. writeback writes (`refill_mem_model.sv:36-40`; Write FSM `cachepool_cache_ctrl.sv:742-785`).
- **Impact:** streaming phases: model aggregate refill throughput bandwidth-capped at 4 B/cyc with zero latency overlap (several-x pessimistic) while scattered misses are ~2× optimistic; dirty-eviction stalls under-modeled by ~4–20 cy per dirty miss.
- **Plan:** with G1 in place, switch closed-loop refill to async completion (return PENDING, park on the MSHR, complete via `refill_resp_handler`); add a per-controller writeback-in-flight counter: on dirty eviction, block next refill issue until the write response returns (mirror `refill_read_outstanding_q` for writes). 3–5 days + calib re-tune.

#### G5. Sync-path refill latency stamped from min-ever `ml_nominal_` — HIGH
- **Model:** `ml_nominal_` = MIN(get_full_latency) over the whole run (`insitu_cache_core.cpp:373`); every refill response stamped issue + ml_nominal_ + fixed penalties (`:392`), discarding the per-call contention-aware latency read at `:372`. The MIN is a deliberate anti-double-count for the serializing calib store (`:106-114`), but on the cachepool target it pins refill cost at best-case forever.
- **RTL:** no nominal mode; `refill_read_outstanding` clears only when the assembled line is accepted (`:729,:869`) — every cycle of downstream contention extends observed miss latency.
- **Impact:** after the first quiet refill, refill cost never grows with memory pressure — 16-core streaming phases systematically optimistic; the model's own write-through/eviction traffic cannot inflate refill latency at all. Error grows exactly where the model is used to project scaling.
- **Plan:** stamp `resp_cycle = issue + per-call full_latency + penalties` when the backing path is contention-aware; keep min-nominal behind a config flag for the calib store only (or fix the calib store to not serialize). Half a day; interacts with G1/G2 (per-call latency only becomes interesting once the backing path is).

#### G6. Functional write-through floods the single serialized memory — MEDIUM
- **Model:** `functional_writethrough=True` (`snitch_cluster.py:309-310`): every store issues a fire-and-forget write via the evict port (`insitu_cache_controller.cpp:729-745`) into the same flat memory — latency deliberately ignored, but it still consumes the memory's serialized 4 B/cyc bandwidth (`memory.cpp:330-341`). RTL L1D is pure write-back (`WriteThroughMode=0`, `cachepool_cache_ctrl.sv:507`).
- **Impact:** every stored word = 1 cycle of fictitious occupancy on the one shared resource that serializes all refills/evictions/icache fills; store-dense phases get refill latencies inflated by queuing behind traffic RTL never has. (Also 2× store bytes on the wide_axi router vs RTL — congests icache/DMA/uncached traffic.)
- **Plan:** make the functional write a true backdoor: `funcwr_req_.set_debug(true)` (`memory.cpp:324` skips bandwidth accounting for debug reqs) or a dedicated zero-timing backdoor port; keep evictions on the timed port. Hours; verify HTIF/backdoor coherence.

### Theme H — Store-path and eviction costs inside the cache

#### H1. Dirty eviction is free — no EVIC_STALL, no folded re-read, no evict-burst occupancy — HIGH
- **Model:** sync path writes the victim back fire-and-forget, zero added latency/occupancy (`insitu_cache_core.cpp:332-347`); async path single-tick evic_fifo push, drained 1/tick with status ignored (`:531-539,:624-632`). `folded_evict_penalty_cycles=3` exists (`insitu_cache_config.py:527`) but is never passed to the structural core (`insitu_cache_core.py:41-64`).
- **RTL:** production folded (PartSplit=4, `cachepool_tile.sv:792-798`): dirty-victim miss defers the allocate and enters EVIC_STALL — re-reads the whole victim line, waits a cycle, pushes evic + replays the write, ~3–4 FSM cycles with `preread_allowed=0` blocking ALL requests including hits (`insitu_cache_core.sv:1890-1910,:2224-2267`); the eviction is a 4-beat burst on the single downstream port shared with refills (`insitu_cache_tcdm_wrapper.sv:1326-1340`; Write state holds `cache_req_ready=0` for the burst, `cachepool_cache_ctrl.sv:742-785`); no new refill while one outstanding (`:684/:729`).
- **Impact:** streaming kernels under-charged ~4–8 cy per dirty miss: the hit-blocking FSM stall absent, the eviction burst that delays the miss's own and the next refill absent, evictions never feel L2 backpressure.
- **Plan:** in `run_request_sync`, when victim is VALID+dirty: (1) add `folded_evict_penalty_cycles` (wire the existing knob through `insitu_cache_core.py`) to miss latency and to a hit-blocking busy window; (2) extend `sync_refill_busy_until_` by BurstLength (4) cycles; (3) async path: model the EVIC_STALL dance and honor `evict_itf_` backpressure instead of voiding status. Pairs with G4's write-ack ordering.

#### H2. Write-hit ack latency and forwarding-buffer timing — MEDIUM
- **Model:** write hits get the same +10 as reads (`insitu_cache_core.cpp:325`); `write_hit_latency_cycles=7` (`insitu_cache_config.py:521`) unread by the structural core. `insitu_cache_fwd_buffer.hpp` is explicitly "NOT yet wired" (`:24-26`); the sync path charges every read hit a flat 10, while `fwd_hit_latency_cycles=6` and the streaming formula (`insitu_cache_config.py:524,:176-185`) are consumed only by the analytic controller (`insitu_cache_controller.cpp:506-521`).
- **RTL:** write hits ack at acceptance via winfo FIFO (~8 cy incl. interco); production runs UseForwardingBuffer=1 (`insitu_cache_tcdm_wrapper.sv:1650-1676`): buffer-line reads skip the SRAM read, writes merge without the bank write port, RAW bypassed (`insitu_cache_core.sv:862-871`); calib TB measured fwd read = 7 vs 10, streaming gaps shrink (gap0→7, gap1→8, gap3→10).
- **Impact:** +2 cy per store hit; ~+3 cy/read on high-locality phases (vector streams touch one 64 B line 16× consecutively — a large fraction of read hits are buffer/streaming hits at ~7 in RTL). Direction: mildly pessimistic here — one of the few.
- **Plan:** cheap: per-way last-touched-line register (mirror `fwd_buffer_line_`, `insitu_cache_controller.cpp:206`) → charge `fwd_hit_latency_cycles_` on same-line reads + the streaming-warmth formula; pass `write_hit_latency_cycles_` into the core and use it for write hits/misses (natural ack point for D2). Full: wire FwdBuffer into `stage1_process`.

### Theme I — AMO/LR-SC timing (data is right; time is zero)

*Overall: the in-call RMW is even MORE atomic than the RTL — single-threaded resolution guarantees the multi-core shared-cell atomicity the RTL buys with `core_ready=0`. Two officially "deferred" items are RTL-faithful non-gaps — do NOT "fix" them: cross-LANE reservation clearing (VLSU lanes physically bypass the shim, `cachepool_tile.sv:658-659,724+`) and the DMA-vs-AMO conflict detector (`amo_conflict_o` exists only in a stale header comment, `spatz_cache_amo.sv:15`).*

#### I1. AMO RMW resolves in zero time — CRITICAL
- **Model:** full RMW inside `req_handler` (`insitu_cache_amo_shim.cpp:153-168`); the core stamps calibrated latency on `scratch_` (hit +10, miss ML+17) but `resp_handler` (`:171-212`) never transfers it — orig returns OK carrying only the 1-cycle xbar latency. Net: an AMO is ~10 cy FASTER than a plain load to the same bank.
- **RTL:** AMO forwarded as a read through the lane-4 spill (+1), crosses the cache pipeline (~10), response returns through the bypassed resp spill (`spatz_cache_amo.sv:230-246`; `cachepool_tile.sv:682-708`).
- **Impact:** every AMO response ~11 cy early on a hit, ~68 cy early on a cold miss; spin-lock retry loops iterate too hot; acquire/critical-section schedule of all 16 cores skewed; AMO-heavy phases measure several percent fast.
- **Plan:** after the in-call scratch read completes, `orig->inc_latency(scratch_.get_full_latency())` before returning OK (same for the SC-success write). ~4 lines; re-run calib to confirm no double-counting with the xbar stamp.

#### I2. SC latency not modeled; failed SC never visits the bank — HIGH
- **Model:** failed SC returns OK immediately, data=1, no cache access (`insitu_cache_amo_shim.cpp:131-137`); successful SC discards the write latency as in I1 (`:139-150`).
- **RTL:** every SC is forwarded (`spatz_cache_amo.sv:220,:148-151`) — a failed SC goes as a harmless read, full round trip ~11 cy, response data overridden; both outcomes cost the same and both occupy the bank.
- **Impact:** LL/SC retry storms under-counted in retry latency and lane-4 load.
- **Plan:** fail path: `orig->inc_latency(read-hit RTT knob)`; success path: transfer scratch write latency. ~6 lines, same knob as I1.

#### I3. Foreign-core true-AMO does not clear the LR/SC reservation — MEDIUM (one line)
- **Model:** `res_.on_foreign_access` called only on WRITE pass-through (`insitu_cache_amo_shim.cpp:118-121`), never in the true-AMO branch.
- **RTL:** foreign write OR any true AMO clears (`spatz_cache_amo.sv:178-182`).
- **Impact:** core A LR(X); core B amoadd(X); core A SC(X) — model lets the SC succeed; RTL must fail it. Latent (CI uses amoswap-only mutexes) but real timing consequences the first time an LL/SC loop runs.
- **Plan:** one line at the top of the true-AMO branch: `res_.on_foreign_access(core, addr, amo_op_, /*is_write=*/false);`.

### Theme J — Issue-side and SoC integration corrections (mostly constant-offset)

- **J1. Scalar LSU extremes (HIGH):** single-outstanding build: PENDING/DENIED → `insn_stall()` freezes the whole core (`lsu.cpp:278-281`); sync path permits unlimited outstanding (`lsu_implem.hpp:47-52`); `nb_outstanding` defaults to 1, never overridden for Snitch (`riscv.py:116,219-220`). RTL: `snitch_lsu` with 16 outstanding (`cachepool_4t_fpu_512.mk:75`), stall-on-use. Two opposing errors: pessimistic full-core stalls exactly under contention (suppressing the MLP the refill-occupancy calibration assumed), optimistic >16 MLP on clean sync streams. Plan: build with `nb_outstanding=16` + scoreboard path (`scoreboard_reg_set_timestamp`, `lsu.cpp:397-400`); requires the cache sync-slave to tolerate a pending scalar request. Medium effort, integration risk; quantify stall fraction via lsu trace first.
- **J2. Icache geometry (MEDIUM):** one shared 8 KiB/2-way/32B L1 with 1-line L0s and one refill port for 16 cores (`snitch_cluster.py:193-194`; `hierarchical_cache.py:50,:55`) vs RTL four per-tile 8 KiB icaches with 8-line L0s (`cachepool_tile.sv:1469-1504`). Loop bodies ≤128 B thrash the model's 1-line L0 every iteration — per-iteration fetch stalls inside the measured region (~10–20% on tight loops). Plan: one `Hierarchical_cache` per tile, L0 = 8×16 B, L1 128 lines×4 sets, per-tile refill to wide_axi. Config-only.
- **J3. SPM partition (MEDIUM):** flat per-core 2 KiB at latency 0 (`snitch_cluster.py:379-381,:430-431`) vs RTL top-1KiB private 1-cycle SPM + bottom-1KiB hart-aliased slice routed THROUGH THE CACHE (`cachepool_cc.sv:679-695,:741-792`); VLSU access to the window is private in the model but shared-cached-DRAM in RTL. Plan: split at SPM_BASE+1KiB (latency=1 Memory above; hart-id bit-swap addr[10:7] + cache route below); drop the VLSU-lane SPM mapping.
- **J4. Remote response misses RspReg +1 (MEDIUM):** remote xbar charges hop latency on the request only (`insitu_cache_remote_xbar.cpp:83`); RTL has PipeReg=1 AND RspReg=1 (`cachepool_group.sv:405-406` → `reqrsp_xbar.sv:176-188`). ~75% of traffic cross-tile at offset 6 → ~2–5% optimistic on remote-heavy kernels. Plan: charge hop on both directions (hop=2) or add `rsp_latency_cycles`. Hours; needs a ≥2-tile RTL config to validate.
- **J5. Peripheral register timing (LOW):** CachePool register block charged +1 (`cluster_registers.cpp:169-173`) vs ~10–20 cy narrow-AXI round trip the rest of the map pays. Plan: charge the measured constant (+11) in `cachepool_access`. One line.
- **J6. CL_CLINT dead for CachePool binaries (LOW, latent):** offsets 0x8/0xC swallowed as perf scratch (`cluster_registers.cpp:264-268`); the working mechanism sits at 0x30/0x38; RTL CL_CLINT_SET/CLEAR are 0x8/0xC (`cachepool_peripheral_reg_pkg.sv:150-151`), MCI=19 matches. Zero CI impact today; silently no-ops for any future kernel using cluster software interrupts. Plan: intercept 0x8/0xC before the perf-scratch swallow. ~15 lines.
- **J7. HW barrier flat +11 (LOW):** single 16-core counter, +11 to everyone (`cluster_registers.cpp:154-166,:352-391`) vs RTL two-level tile+cluster barrier with ~2–4 cy tile-local release (`cachepool_tile_barrier.sv:60-148`, `cachepool_cluster_barrier.sv:80-133`). Per-barrier ±5 cy constant; CI barriers sit outside the mcycle window. Plan (deferred): two-level counters with proxy request.
- **J8. Boot offset ~1000 cy (LOW):** model starts cores at t≈0; RTL TB idles 1000 cycles (`tb_cachepool.sv:163-210`). Constant offset in absolute EOC totals only; kernel-reported mcycle unaffected. Plan: configurable start delay or document the offset.
- **J9. DMA enabled in model, disabled in RTL CI (LOW, latent):** `Xdma=4'h0` (`cachepool_cluster_wrapper.sv:90`) but the model instantiates SnitchDma with a cache-bypassing AXI (`snitch_cluster.py:250-276,:500-501`) — stale-line incoherence + contention-free timing if ever exercised. Plan: gate SnitchDma out for the cachepool target; reject dmcpy as illegal. Trivial.

### Theme K — Async (calib-path) FSM refinements — LOW (confined to the non-deployed path)

- **K1. Pseudo-dual-port WR_CONFLICT is dead code:** `bank_.read_conflict` checked (`insitu_cache_core.cpp:491-494`) but `begin_cycle` resets the scoreboard every tick (`:433`) and stage-1 does ≤1 bank op/tick → `cnt_bank_conflict_` structurally always 0; the Step-2 bank model is never exercised. RTL overlaps preread of N+1 with the FSM write of N (`insitu_cache_core.sv:905` vs `:1605/:2412`); ~50% of same-way write→read pairs pay +1. Plan: persist previous tick's commit_write for one extra cycle and check at stage0 latch time.
- **K2. 7-state stall enum collapsed to blind retry; refill install bypasses preread:** all stalls are bare `return false` (`:520-534`); install runs as a side-channel with strict priority in one tick, draining all readers instantly (`:456-477,:553-590`) vs RTL's same-cycle release-and-serve (`:2450-2570`) and refill-through-pipeline. ~1–2 cy per event; moves the per-miss constants the sync knobs were calibrated from.
- **K3. Multi-read-pend: verified NOT a gap** — MRP is `ifdef`'d out in the RTL build (`Bender.yml:18`); model's `enable_multi_read_pend=False` matches. No action; keep in lockstep.

### Theme L — Legacy flat-controller divergence (contained; not the deployed path)

- **L1. Knuth hash + invalid-way-first fill (MEDIUM):** `insitu_cache_controller.cpp:714-721` (Knuth multiplicative hash, invalid-way-first, full-assoc lookup) lives only in the legacy flat controller — the calib-DUT default — while the RTL hash mode always installs into (and evicts) the XOR hash way with no invalid-first fill (`insitu_cache_decoder.sv:112-118,:163-164,:246-258`). The deployed structural core uses the RTL-exact XOR hash (`insitu_cache_decode.hpp:61-67`) — verified bit-for-bit. Contained, but silently poisons any future flat-tile calibration comparison. Plan: in hash mode, call `CacheGeom::hash_way` (one source of truth) and probe only that way; ~20 lines; longer term retire the flat controller for CachePool work.
- **L2. Partition CSRs as no-ops are FAITHFUL for CachePool (LOW):** the RTL ties `bank_depth_for_SPM_i`/`cache_part_base_i` to zero and leaves `l1d_spm_size_o` unconnected (`cachepool_cache_ctrl.sv:520`, `cachepool_tile.sv:974`, `cachepool_cluster.sv:1041`). Document the no-op as intentional (cite those lines in `cluster_registers.cpp`); delete or hard-gate the flat controller's home-grown `enable_spm_` path (`insitu_cache_controller.cpp:103-113`) which matches no RTL module. Caveat per E3: `L1D_PRIVATE` *is* live in RTL and load-store uses it — the hash-partition-flush review's claim that no kernel calls `l1d_part` is **wrong**.

---

## 3. Prioritized implementation roadmap

Ordered by timing-impact ÷ effort. **Sequencing invariants:** A1 must land before B/C/D effects become visible on vector traffic; B1 and C1 must land *together* (serialization without merge swings 4× pessimistic on unit-stride streams); E1 must land before any miss-rate/cycle comparison vs RTL is trusted; G5's per-call latency only pays off after G1/G2 give it something to measure.

### Phase 1 — quick wins (hours to ~1 day each; ~1.5 weeks total)

| # | Gap | Plan (ref) | Expected gain | Dependencies |
|---|-----|-----------|---------------|--------------|
| P1.1 | A1 VLSU commit-at-issue | Port ara_vlsu delayed-commit queue into `spatz_vlsu.cpp` OK path (~1–2 d) | Unmasks the entire cache timing model for vector traffic; the single highest-leverage change | None. Re-run 8 CI kernels + calib TB |
| P1.2 | E1 rotation off (16× capacity collapse) | `enable_rotation=True` + refill/evict unrotation via `route.hpp::unrotate_addr` (~1–2 d) | Fixes first-order miss-rate corruption; prerequisite for trusting any cycle comparison | None |
| P1.3 | B1 per-cell accept token | `cell_busy_until` stamp shared by 5 ports (~1 d) | Restores 1-access/cycle service + emergent queueing | Pair with P2.1 (merge) before trusting throughput numbers |
| P1.4 | D1 PEND-line ready-cycle clamp | `line_ready_cycle` per way; followers `inc_latency(ready-now+drain)` (~½ d) | Fixes cold-line follower early hits (~6×/follower at ML=50) | None; first-order after P1.1 |
| P1.5 | D2 write-miss early ack | Ack at `write_hit_latency_cycles_`; keep WRITE_PEND w/ ready_cycle (~½ d) | Fixes scalar store-miss over-charge (ML+17 → ~8); vector after P1.1 | P1.4 (same machinery) |
| P1.6 | I1+I2+I3 AMO/SC timing + reservation clear | Transfer scratch latency to orig; SC fail-path RTT; one-line foreign-AMO clear (~50 lines total, ½ d) | Spin-lock retry rates and 16-core acquire schedules realistic; ~5× throughput over-prediction closed with P1.7 | None |
| P1.7 | B3 RMW lane occupancy | `rmw_busy_until_` accept-stall stamp (~30 lines + 1 knob) | Contended-atomic throughput per bank ≈ RTL's 1/15–20 cy shared | P1.6 (same file) |
| P1.8 | F1 stopgap flush | Fixed 21+num_sets stall + invalidate-all on any flush insn (hours) | Removes the warm-cache min-iteration bias on gemv/fft — the headline metric | None; superseded by P2.4 |
| P1.9 | G3 1 GHz clock | `frequency=1000000000` + audit + CI re-run (hours) | Un-silently-invalidates the DRAMSys path; 100× on future DRAM timing | None |
| P1.10 | G6 write-through backdoor | `funcwr_req_.set_debug(true)` (hours) | Removes fictitious store occupancy on the serialized memory | Verify HTIF coherence |
| P1.11 | G2 stopgap memory | `width_log2=6`, latency ~30, re-tune miss_penalty (hours) | Isolated-miss and peak-bandwidth behavior roughly right until P3.1 | Interacts with P1.10 |
| P1.12 | J4 remote RspReg | hop on both directions (hours) | ~2–5% on remote-heavy kernels | Validation needs ≥2-tile RTL config |
| P1.13 | J5+J6 peripheral constants + CLINT | +11 in `cachepool_access`; intercept 0x8/0xC (~½ d) | Tens of cycles/run; un-latents software IRQs | None |
| P1.14 | J9 DMA gate | Remove SnitchDma for cachepool target (trivial) | Matches `Xdma=0`; removes incoherence hazard | None |

### Phase 2 — structural (2–5 days each; ~4–6 weeks total)

| # | Gap | Plan (ref) | Expected gain | Dependencies |
|---|-----|-----------|---------------|--------------|
| P2.1 | C1+C2 coalescer merge | Re-key on 16 B part, write merge, PENDING window, CSHR watchdog; enable `cell_coalescer` (~3–5 d) | Recovers the 4-lanes→1-beat merge so P1.3 doesn't swing pessimistic; correct bank occupancy for cross-core traffic | P1.1, P1.3; validate on calib coal_warm/coal_cold |
| P2.2 | B2 xbar per-output arbitration | Grant tokens + RR in both xbar classes; re-calibrate on single-tile TB (~2–3 d) | 5–20% on streaming phases; correct lock-kernel serialization; always-optimistic bias removed | P1.3 |
| P2.3 | H1 dirty-eviction cost | Wire `folded_evict_penalty_cycles`, hit-blocking window, evict-burst occupancy (+async EVIC_STALL) (~2 d) | 4–8 cy per dirty miss on streaming kernels | P2.6 for the write-ack half |
| P2.4 | F1 full flush FSM | Wire `insitu_cache_sync_fsm.hpp`: drain gate, set walk, dirty evictions, FLUSH_STATUS, tile insn decode, remote gating (~2–3 d) | Real flush costs + writeback bursts; safe CSR reconfiguration | P1.8 stopgap; needed before P2.5 is safe with dirty lines |
| P2.5 | E2+E3 xbar CSRs | Runtime setters for dynamic_offset / num_private_cache / private_start on all lane xbars; flush-before-commit (~2 d shared) | fdotp/idotp/gemv/gemv-opt run the mapping the kernels program; load-store runs the right partition; unlocks partitioning studies | P1.2, P2.4 |
| P2.6 | G4 async refill + write-ack ordering | PENDING refill completion on MSHR; writeback-in-flight counter blocking next refill (~3–5 d) | Real refill overlap and eviction-stall costs under load | P3.1 (channel split) for full effect |
| P2.7 | G5 per-call refill latency | Stamp per-call full_latency; gate min-nominal behind calib flag (~½ d) | Refill cost tracks memory pressure — the scaling-projection fix | P3.1/P1.11 to be meaningful |
| P2.8 | A2 lane width 4 B + 32 outstanding | `spatz_lane_width=4`, vico bw=4, `nb_outstanding_reqs=32` (or burst split) (~1 d) | Removes the 2× pin-bandwidth floor on all vector throughput | P1.1; calib re-validation |
| P2.9 | H2 write-hit + fwd-buffer cheap path | Pass `write_hit_latency_cycles_`; per-way last-line register + fwd/streaming latencies (~1 d) | ~3 cy/read on high-locality phases (mildly pessimistic today) | None |
| P2.10 | J1 scalar LSU 16-entry scoreboard | `nb_outstanding=16` + scoreboard stall-on-use (medium, risky) | Removes full-core stalls under contention; restores MLP the calibration assumed | Cache sync-slave must tolerate pending scalar reqs |
| P2.11 | J2+J3 icache + SPM geometry | Per-tile icaches (config-only); SPM split at 1 KiB + hart-id swap (~1–2 d) | ~10–20% on tight loops; correct crt0/printf/team-setup costs | None |
| P2.12 | B4 retr/resp FIFO bounds | Bound resp_fifo at 4; retr counts lines (cap 2); pass depths to core (~1 d) | Correct refill throttling under multi-reader refills | P1.4 |
| P2.13 | E4 0xA0000000 through the cache | Fix M32768 eviction bug; delete bypass maps; extend cache_region (days; routing itself ~10 lines) | The dominant kernel data flow joins the calibrated machine — arguably P1-impact, P2-effort because of the bug fix | None for interim wide-AXI reroute |

### Phase 3 — large (1–2+ weeks)

| # | Gap | Plan (ref) | Expected gain | Dependencies |
|---|-----|-----------|---------------|--------------|
| P3.1 | G1+G2 channel demux + DDR4 model | `InsituCacheL2Demux` (reuse `insitu_cache_l2_addr.hpp`, interleave=16) + 4× per-channel DDR4-class timing model (~300 lines each-channel FSM) or fix DRAMSys segfault (2–4 d demux; 1–2 wk DDR4) | Channel parallelism, arbitration, row-bank-refresh effects; makes P2.6/P2.7 real | P1.9, P1.11 |
| P3.2 | K1+K2 async FSM refinements | Persist write scoreboard one cycle; same-tick stall release; refill through pipeline (~2–3 d) | 0–2 cy/event on the calib path; makes Step-2 bank model actually exercised | Only if the async path remains the calib vehicle |
| P3.3 | D3 MSHR cap | Cap `mshr_` at NumSubarray (~9) (½ d) | Correct >9-way pileup stalls (spin/broadcast) | P1.4 |
| P3.4 | L1 flat-controller hash parity | One-source `CacheGeom::hash_way`; probe hash way only (~20 lines) | De-poisons future flat-tile calibration | None; or retire the flat controller |
| P3.5 | J7+J8 barrier two-level + boot delay | Tile/cluster counters + proxy; configurable 1000-cycle start (few hundred lines) | Per-barrier ±5 cy; absolute EOC comparability | Low value for CI metrics |
| P3.6 | Full fwd buffer / structural Steps 5–7 | Wire FwdBuffer into stage1; par-coalescer/xbar structural path | Long-term structural-core fidelity | Defer until the sync path is validated |

**Suggested validation gate after each phase:** re-run the 8 CI kernels + the standalone calib TB; after P1, expect cycle counts to *rise* (the dominant biases are optimistic) and the miss counts on fdotp/gemv to drop (E1); after P2, per-phase agreement on load-store (partition) and the dot-product family (offset); after P3, miss-storm phases.

---

## 4. What is already good (do not re-litigate)

Verified during the adversarial pass; listed so the next phase builds on rather than re-opens these:

- **Calibrated sync-slave latency at isolated points.** Warm read-hit 10 cy isolated / 7 streaming, cold miss ML+17, write 8 / ~0.49 throughput, RAW forwarding 7 — matched against the standalone RTL calib TB (`prompt/insitu_cache_calib_report.md`). The knobs exist and are correctly plumbed for the *isolated-access* regime; the gaps are all load-dependent structure around them.
- **Hash-way decode.** `insitu_cache_decode.hpp:61-67` reproduces `insitu_cache_decoder.sv:112-118` bit-for-bit (low-tag XOR low-set), and the deployed structural core uses it for both hit classify and victim install. The divergence is only in the legacy flat controller (L1).
- **Single-outstanding refill gate.** Per-controller one-outstanding refill is RTL-faithful (`refill_read_outstanding`, `cachepool_cache_ctrl.sv:684`; model `refill_busy_`, `insitu_cache_controller.cpp:227-241`). MRP correctly absent (disabled in the RTL build, `Bender.yml:18`) — verified non-gap.
- **Xbar/hop structure.** The 5 per-port-class 6×6 lane xbars match `tcdm_cache_interco.sv:219-284` line-by-line (three-mode routing with modulo folding, remote-out slot = target%2, remote in-slot = source%2, response routing); request-path latency (input spill + PipeReg per remote hop = 3 cy end-to-end) is correct; remote slot pinning matches exactly. The rotation/CSR/arbitration gaps are *around* a correct skeleton, and `route.hpp` already implements the RTL mode table the CSR fixes will exercise.
- **AMO/LR-SC data path.** ALU ops, single per-bank reservation register, LR-overwrite and same-core-write rules match `spatz_cache_amo.sv` rule-for-rule; the in-call RMW is *more* atomic than the RTL. Cross-lane reservation clearing and the DMA-conflict detector are RTL-faithful non-gaps — do not "fix" them.
- **Topology and integration.** Composite-boundary port names resolve (the `input` vs `input_0` class of bug is documented and fixed); barrier wiring and MCI=19 IRQ number are correct; bootrom binary-patching is behaviorally equivalent for the executed path.
- **Data correctness.** All 8 CI kernel families reach `EOC: exit code 0` with zero FAIL at full 256-core scale (the fdotp/fmatmul livelock is fixed; `cachepool_v2_architecture.md` §13.1/13.2 is stale on that point). Everything in this document is a *timing* gap, not a functional one — except E4/J9, which are functional-fidelity hazards latent beyond the current CI.
- **Reuse inventory for the fixes.** Much of the work is wiring, not new structures: `ara_vlsu.cpp:226-238` (delayed commit), `route.hpp` (rotate/unrotate/mode table), `insitu_cache_sync_fsm.hpp` (7-state flush FSM), `insitu_cache_l2_addr.hpp` (scramble/NAPOT), `insitu_cache_amo.hpp:120-169` (cycle-level AMO FSM), `insitu_cache_coalesce.hpp` (wide-merge datapath), `line->ready_cycle` (`insitu_cache_controller.cpp:526`), and the `write_commit_busy_until_` accept-stamp idiom all already exist.