# InSitu Cache — RTL-Faithful Structural Model: Master Build Plan (2026-06-16)

> **Review resolutions (adversarial review = SOUND-WITH-FIXES; folded in 2026-06-16):**
> 1. **[must-fix] Synchronous-slave mode is mandatory for the structural core (Step-0 gate).** The per-cycle FSM parks IoReq and would `resp()` later, but the Spatz v1-ISS LSU only accepts a synchronous `IO_REQ_OK`. So the structural core MUST run its per-cycle FSM *internally to completion* within the request and return OK with the emergent latency (inline), for the cluster path — exactly what `inline_sync_miss` does today. The async park+resp mode is for the open-loop calib driver only.
> 2. **[must-fix] Validation gate = diff per-access DATA + latency vs the RTL *reference dataset* (`rtl_ref_1t_2026-06-16` / `replay_batch`), NOT the RTL-internal SV scoreboard** (which isn't runnable here).
> 3. **[should-fix] Step 4 reuses `insitu_calib_mem`** (the existing serializing refill responder) as its refill source for the micro-driver.
> 4. **[should-fix] Resolve FIFO depths (core.sv 16 vs top.sv 4), ENABLE_MULTI_READ_PEND, NumPseudoDualBanks/BankFactor from `cachepool_cache_ctrl.sv` BEFORE Step 4** — they set stall frequency, the whole point of the structural model.
> 5. **[should-fix] The structural/fallback switch lives ONLY at the cluster integration boundary** (`snitch_cluster.py`: i_INPUT / o_L2 / i_FLUSH), not threaded through every component.
> 6. The `refill-evict-fsm` component spec must be re-extracted from `cachepool_cache_ctrl.sv` (its reader hit a transient API error) before Step 4.



## 1. Methodology & guardrails

The existing model under `core/models/cache/insitu/` is a **cycle-approximate** performance overlay: flat latency knobs (`hit_latency_cycles_`, `miss_penalty_cycles_`), cyclestamp occupancy (`set_busy_until_`, `refill_drain_busy_until_`), a Knuth-hash victim picker (`pick_victim()`, `controller.cpp:643-656`) that is *not* the RTL hash, and an `inc1`-style coalescer skeleton. It works (vfadd 15/15, `cycles=58001`; open-loop `coal_cold` wide @ML50 = 0.4961, `fmatmul M32` mean Δ = 3.9 cy) but it mirrors none of the RTL micro-architecture. This plan **replaces the timing engine with the real structure** while keeping the approximate model alive as a fallback.

**Guardrails (binding for every step):**

1. **Real logic, not approximations.** Each new component transcribes the RTL FSM/datapath (the `case(cache_status_q)` switch, the CSHR FSM, the pseudo-dual-port conflict decode, the 7-state sync FSM, the AMO RMW FSM). Latency must **emerge** from cycles spent in states/stalls, not from a knob applied up front. Knobs survive only as per-tick step counts tuned in the final calibration phase.

2. **Functional-correctness gate during build, not after.** Every step ends with a data-correctness check, not a cycle-count match: (a) `examples/spatz/test-riscvTests-vfadd` with `use_insitu_cache=True` PASSES all 15 cases (`retval=0`); (b) the calib traces under `ManyRVData_rebase/reports/cache_calib/traces/` *replay without error* and produce per-port data byte-identical to the RTL scoreboard (`equal_window.sv:446-490`); (c) every store value equals the subsequent load value (the WR==RD invariant already verified for the current model). **Cycle counts WILL change** as we swap the Knuth hash for the RTL XOR-fold and the latency-window coalescer for the real CSHR — that is expected and acceptable.

3. **Calibrate last.** No per-step cycle tuning. The structural model's timing constants (bank read latency=1, spill latency=1, `CheckPendDrainCycles`=20, beat-issue cost) are set to their RTL nominal values during build and left there. A single dedicated calibration phase (§6) is the only place we diff cycle counts against `rtl_ref_1t_2026-06-16` and the closed-loop `region_cyc` table.

4. **Parallel fallback selectable by one top-level flag.** Add `structural_mode` (bool, default `False`) to `InsituCacheTileConfig` / `SnitchArchProperties`. `structural_mode=False` → the current `insitu_cache_controller`/`interco`/`par_coalescer` (untouched, the calibrated path). `structural_mode=True` → the new `cachepool_tile` composite of structural components. The two trees are wired behind the *same* tile/cluster input/refill/evict/flush ports so `snitch_cluster.py` chooses at elaboration. We do **not** delete or edit the approximate components until the structural model is functionally correct AND calibrated; until then `False` remains the default so `make test` / closed-loop CI stays green.

5. **vfadd must keep passing — on both paths.** Every commit runs vfadd on the *fallback* path (must stay 15/15) and, once the structural path is wired, on `structural_mode=True` too. A structural regression never blocks the fallback.

6. **RTL is read-only.** Never modify anything under `ManyRVData_rebase/working_dir/insitu-cache/` or `ManyRVData_rebase/hardware/`. Re-read per the CLAUDE.md "Tracking new RTL revisions" procedure. Append a `prompt/WORKLOG.md` entry at every commit; write a new dated structure map whenever a structural item lands (do not overwrite prior ones).

---

## 2. Component inventory

| Component | New GVSoC file(s) | RTL source | Replaces | Depends on | Effort |
|---|---|---|---|---|---|
| **Decoder/Encoder datapath** (hit/miss decode, hash XOR-fold, LRU 4-case, masked merge) | `insitu_cache_decode.{hpp,cpp}` (inline `classify()`/`apply_meta_write()`); also surfaced as `insitu_cache_decoder.hpp` + `insitu_cache_encoder.hpp` | `insitu_cache_decoder.sv`, `insitu_cache_encoder.sv`, `insitu_cache_pkg.sv:19` | `pick_victim()` Knuth hash (`controller.cpp:643-656`) + scattered hit/miss decode | core component (caller); GeomConst from config | **medium** |
| **SRAM banking subsystem** (pseudo-dual-port conflict, folded per-way, access-ctrl FSM) | `insitu_cache_bank_array.{hpp,cpp}` (owned by the core) | `insitu_cache_tcdm_wrapper.sv:1983-2883`, `pseudo_dual_port_bank.sv`, `folded_data_bank.sv`, `pseudo_dual_port_way.sv` | `set_busy_until_` + `bank_accept_cycles_` (`controller.cpp:192,476-482`) | core (owns it); fwd-buffer; config knobs (`num_pseudo_banks`, `part_split`) | **medium-high** |
| **SRAM forwarding buffer** (1-entry + N-entry register-cache, partial-validity bitmap, RAW/inflight fwd, lazy WB) | `insitu_cache_fwd_buffer.{hpp,cpp}`, `insitu_cache_fwd_buffer_config.py` | `sram_forwarding_buffer.sv`, `sram_forwarding_buffer_multi.sv` | single `int64_t fwd_buffer_line_` + `fwd_hit_latency_cycles_` (`controller.cpp:194-197`) | bank access-ctrl (owner); bank SRAM (1-cyc rdata); per-cycle ClockEvent | **medium-high** |
| **Cache core** (2-stage pipeline, 7-state FSM, in-situ MSHR, single-outstanding refill gate) | `insitu_cache_core.{cpp,py}` (`cache.insitu.core`) | `insitu_cache_core.sv`, `insitu_cache_top.sv` (front-end), `insitu_cache_pkg.sv` | the entire hit/miss/latency engine of `insitu_cache_controller.cpp` | decoder/encoder; bank array; fwd buffer; refill responder | **highest (~900-1200 LOC)** |
| **par_coalescer** (N→1 CSHR coalescer + wide last-writer-wins merge + 1→N splitter + non_coalescer) | `insitu_cache_par_coalescer.{cpp,py}` (REWRITE), `insitu_cache_non_coalescer.cpp`, `insitu_cache_coalescer_types.hpp` | `par_coalescer_top.sv`, `par_coalescer_equal_window.sv`, `req_coalescer_v2.sv`, `rsp_spliter_v2.sv`, `non_coalescer.sv` | the `inc1` coalescer skeleton (`insitu_cache_par_coalescer.cpp:41-148`) | core (wide downstream iface); tile; interco (port index order) | **high** |
| **Programmable xbar + SPM remap + sync FSM + bypass xbar** | `insitu_cache_xbar.{cpp,py}`, `insitu_cache_bypass_xbar.{cpp,py}`, `insitu_cache_sync_fsm.{cpp,h}`, `insitu_cache_spm_remap.h`; config: `InsituCacheXbarConfig`/`InsituCacheSpmConfig`/`InsituCacheSyncConfig` | `tcdm_cache_interco.sv`, `reqrsp_xbar.sv`, `insitu_cache_tcdm_wrapper_partitionable_flushable.sv`, `insitu_cache_tcdm_wrapper.sv` (sync branch), `cachepool_cache_ctrl.sv` | `insitu_cache_interco.{cpp,py}` (hashed N→M approximation); adds SPM remap + flush FSM (no current equiv) | core (tag/dirty arrays); coalescer; refill/evict master | **high** |
| **System composition** (TILE/GROUP/CLUSTER composites, remote xbar, AMO/LR-SC, peripheral, L2 xbar) | `struct/cachepool_{tile,group,cluster}.py`, `struct/cachepool_remote_xbar.{cpp,py}`, `struct/spatz_cache_amo.{cpp,py}`, `struct/cachepool_peripheral.{cpp,py}`, `struct/cachepool_l2_xbar.{cpp,py}` | `cachepool_{tile,group,cluster}.sv`, `spatz_cache_amo.sv`, `cachepool_peripheral.sv`, `cachepool_pkg.sv` | `insitu_cache_tile.py` (flat single-tile) | core, xbar, coalescer, DRAMSys DDR4, IoReq user metadata | **high** |

All RTL paths are read-only references under `ManyRVData_rebase/working_dir/insitu-cache/src/` and `ManyRVData_rebase/hardware/src/`.

---

## 3. The structural data model

### 3.1 Shared state (the `CacheCore` owns the SRAM; everything else is sub-state or a sibling)

The faithful structure mirrors the RTL nesting `partitionable_flushable → tcdm_wrapper(core + banks + fwd-buffer + sync-FSM) → core(decoder/encoder + MSHR)`, with `tcdm_cache_interco`/`reqrsp_xbar`/`par_coalescer` as siblings.

The **single source of truth** is the per-way bank array, owned by `insitu_cache_core.cpp`:

```
struct CacheLine {                 // mirrors cache_line_t (core.sv:307-314)
  LineState status;                // INVALID=0/VALID=1/READ_PEND=2/WRITE_PEND=3 (pkg.sv:19; s1=pend, s0=low)
  bool      dirty;
  uint64_t  tag;
  uint64_t  mask;                  // per-8B byte-mask bits
  uint8_t  *data;                  // line_bytes, functional payload
  MissMeta  meta;                  // {is_full,is_prime,link_enable,link_ptr} (decoder.sv:53)
  uint8_t   lru;
};
std::vector<CacheLine> lines_[num_sets * num_ways];   // folded per-way (folded_data_bank.sv:53 → ways never conflict)
```

The decoder/encoder are **pure combinational helpers** (no port, no event) operating on a `BankArrays` SoA view of one set. The bank array, forwarding buffer, and sync FSM are **sub-state held by the core/wrapper** (shared clock + tag arrays). The xbar, bypass-xbar, coalescer, remote-xbar, AMO shim, peripheral, and L2 xbar are **standalone `vp::Component`s** wired in the composites.

### 3.2 In-situ MSHR (the load-bearing structural idea)

There is **no address-CAM MSHR**. A pending line *is* the MSHR: its `data` field is repurposed as a reader list. In C++ we hold `std::vector<vp::IoReq*> pending_readers_` per pending line, with `subarray_cnt = pending_readers_.size()` driving the number of response beats — exactly the RTL `num_subarray` count (`core.sv:301-304,388-394,1083-1094`). Refills match back to pending lines by **re-decoding addr → set/tag and scanning for the READ_PEND/WRITE_PEND way** (already the pattern at `controller.cpp:222`), not by a side-table. Single-outstanding refill: one `refill_pending_` flag + a `refill_spill_` slot.

### 3.3 IoReq flow through the structure

```
core/VLSU narrow req
  → tcdm_cache_interco (route any-core→any-bank by addr; forward MSB rotation; +1 spill)
  → [tile lane 4 only] spatz_cache_amo (LR/SC reservation; AMO RMW FSM)
  → reqrsp 2:1 bypass_xbar (coalescer-aggregate | scalar-bypass → 1 cache port)
  → par_coalescer (CSHR window; N narrow → 1 wide 512b last-writer-wins beat)
  → insitu_cache_core (2-stage pipeline: stage-0 pre-read/bank-read; stage-1 decode+FSM+encode+bank-write)
      ├─ HIT  → resp_fifo → split back through coalescer to originating ports
      ├─ MISS → miss_fifo → refill_itf → [tile inverse rotation] → cluster L2 xbar (NAPOT) → DRAMSys DDR4
      │         (refill resp re-decodes set/tag → installs line → replays one resp per pending_reader)
      └─ dirty victim → evict_itf → same L2 path
  sync_fsm (flush/invalidate/init) gates upstream while walking sets, evicts dirty via evict_itf
```

A parked read returns `IO_REQ_PENDING`; its real `resp()` fires on the tick its resp/retr-fifo beat drains. Per-request context lives in a side structure keyed off the parked `IoReq*` (never co-using `get_args()`/`save()` slots, per CLAUDE.md).

### 3.4 Per-cycle ClockEvent FSM vs cyclestamp — the boundary

**Genuinely per-cycle (ClockEvent `tick`):**
- **Cache core** — the 2-stage registered pipeline + 7-state FSM. Stage-0 grants ONE of {request, refill} to the single bank port; stage-1 decodes/runs the switch/refill block, one bank write, one beat per output FIFO. Work-driven: scheduled on admit / non-`REQ_PROC` state / refill-in-spill / non-empty output FIFO; self-disarms when idle.
- **Bank array** — the WR_CONFLICT decision is fundamentally same-cycle. A per-cycle `wrote_this_cycle[way,bank_select]` scoreboard (cleared at tick top) + `retry_q` reproduces read-retry (+1). Event enabled only while `retry_q` non-empty or a way is in ACCESS_STALL/wb_active.
- **Forwarding buffer** — 1-cycle registered read response, `sram_rd_pend_q`, `wb_active` overlay. Double-buffered `_q`/`_d` swapped at the cycle edge to reproduce nonblocking read-before-write.
- **CSHR coalescer** — a window stays open across cycles accumulating same-line ports; emits on new-line/watchdog. The splitter takes multiple cycles under per-port backpressure.
- **Sync FSM** — the 20-cycle *consecutive*-stable drain interlock and the per-set walk are intrinsically cycle-counted.
- **AMO RMW FSM** — IDLE→DOAMO(read)→WBAMO(write)→WAIT→IDLE with input back-pressured for atomicity.

**Cyclestamp / `inc_latency` (synchronous-OK):**
- The SRAM read itself (Latency=1, deterministic once arbitration is won).
- The xbar 1-cycle req spill / 0-cycle rsp fall-through.
- The bypass xbar (combinational, `PipeReg=0`).
- Remote/L2 xbar PipeReg/RspReg (1 cyc) + per-output RR arbitration.
- The downstream **L2 refill/eviction latency** (MemLatency via the existing serializing responder / DRAMSys) — multi-cycle AXI, not a single flop.
- Peripheral flush as a handshake (issue flush reqs, count ready pulses) — `l1d_busy` is a boolean gate.

Cyclestamp (`clock.get_cycles()`) is used inside the core only for telemetry/idle-gap detection, never to compute per-request latency.

---

## 4. Dependency-ordered build sequence (bottom-up)

Each step lands behind `structural_mode` and ends with its own functional gate. The approximate path stays default-selected throughout.

### Step 0 — Scaffolding & the fallback switch (0.5 day)
Add `structural_mode` to `InsituCacheTileConfig` and `SnitchArchProperties`; make `snitch_cluster.py` instantiate either `InsituCacheTile` (fallback) or the new `cachepool_tile` composite (initially an empty stub that just forwards to the fallback). Add the new `core/models/cache/insitu/insitu_cache_decode.hpp` and `struct/` dirs to `CMakeLists.txt`. **Gate:** fallback build unchanged, vfadd 15/15.

### Step 1 — Decoder/Encoder datapath (`insitu_cache_decode.{hpp,cpp}`) — *medium* (1-2 days)
**Unblocks: everything** (the core can't classify without it). Pure combinational; no port, no event. Implement the **exact RTL XOR-fold** `hash_way = (addr>>tag_lo & wmask) ^ (addr>>depth_lo & wmask)` (`decoder.sv:112-118`, `core.sv:986-994`) — *this is the load-bearing fix vs the Knuth hash*. Implement `decode_request()` (hash-mode SOP + full-assoc loop, `decoder.sv:163-239`), the default first-`lru==0` victim search (`decoder.sv:266-283`), `max_lru_credit()`, the 4-case `lru_array_update()` (`encoder.sv:112-158`), and byte-masked `encode_write()` (`encoder.sv:185-203`). Keep `LineState` bit-encoding fixed (`pkg.sv:19`). MRP link bookkeeping behind a flag, stubbed to single-READ_PEND first.
**Validation:** unit micro-driver — feed known addrs, assert `way`/`is_hit`/`is_hit_pend`/`is_all_pend` and victim choice match a hand-computed RTL trace; assert `tag_lo = depth_lo + log2(num_sets)`, `depth_lo = log2(line_bytes)`.

### Step 2 — SRAM bank array (`insitu_cache_bank_array.{hpp,cpp}`) — *medium-high* (1.5 days)
**Unblocks: faithful conflict timing + the core's bank-port arbitration.** Implement `bank_select()` (low `log2(num_pseudo_banks)` bits, `tcdm_wrapper.sv:2176`), the 6-state `classify()` (`tcdm_wrapper.sv:2189-2208`), `read_conflict()`+`retry_q` (`pseudo_dual_port_bank.sv:224`), unconditional write-priority (`tcdm_wrapper.sv:2224`), WR_SAME_ADDR forwarding (no penalty), the ACCESS_THROUGH/ACCESS_STALL + `wb_active` overlay FSM (`tcdm_wrapper.sv:2619-2782`), and the global read-ready AND across active ways (`tcdm_wrapper.sv:1860`). `bank_gnt` stubbed always-1 (single-tile). Enforce **writes-mark-first, reads-classify-after** ordering within a tick.
**Validation:** micro-driver issuing same-cycle R+W to same/different rows → assert WR_DIFF_BANK/WR_SAME_ADDR free, WR_CONFLICT +1. Data correctness on tight RAW to the same line.

### Step 3 — SRAM forwarding buffer (`insitu_cache_fwd_buffer.{hpp,cpp}`) — *medium-high* (1.5-2 days)
**Unblocks: bank access-ctrl completeness.** Implement the single-entry FSM with **double-buffered `_q`/`_d`** state (the #1 correctness trap — populate reads `parts_valid_q` while writing `_d`), the partial-validity bitmap, the four populate paths (A/B/D-gated/REPLACE), three write-hit classes, `wr_full_coverage`, RAW (`buf_data_post_write`), and the registered 1-cycle read hit. `(D)` concurrent-merge gated by `wr_target_valid` (tie to 1 initially, document the ACCUMULATE-anywhere caveat). Multi-entry path with single `part_idx`+`all_parts` per entry (distinct struct, *not* the bitmap), 4-priority allocation, N=2 pseudo-LRU. `wb_done=wb_active|spec_wb_fire` *ungated* on grant. Optional C1/C3/C5 asserts under `INSITU_FWD_ASSERTS`.
**Validation:** directed micro-driver (read/write/refill sequences) asserting hit/miss/dirty/wb outputs vs the RTL FSM in isolation — this is the buffer's first verification step, before it's wired into the core.

### Step 4 — Cache core (`insitu_cache_core.{cpp,py}`) — *highest* (3-5 days)
**Unblocks: the whole structural tile.** This is the bulk. ClockEvent scaffolding + IoReq parking/response plumbing (~1 day) → the `case(cache_status_q)` switch + decoder/encoder wiring + in-situ MSHR reader-list (~2 days) → functional bring-up / data correctness (~1 day) → tile wiring + green (~1 day).
- 7-state FSM as a near-line-for-line transcription of `core.sv:1542-2312` + the parallel refill block (`core.sv:2320-2831`).
- `preread_task_q` as the literal stage register; 1-deep `req_buf_q`; single bank-port arbiter (refill priority via retr-room gate, `core.sv:894-903,835-838`).
- In-situ MSHR: pending line holds `pending_readers_`; refill replays one `resp()` per reader (count = `num_subarray`). Handle `one_more`/`extra_subarray` (MSHR_FULL exit, `core.sv:2337-2351`) correctly — wrong count hangs cores.
- Same-line bank-write/read hazard (`core.sv:864-871`) — hold req_buf one cycle (functional, not just timing).
- Structural FIFOs (resp/retr/miss/evic) as capacity-bounded `std::deque`. Single-outstanding refill gate.
- **Deliberately stub (behind flags, documented):** PartSplit>1 (`deferred_bank_write`, EVIC_STALL full-line read), MRP linked-list (`ENABLE_MULTI_READ_PEND`), aggressive forwarding-buffer bypass — all inactive in the canonical 512b/PartSplit=1 config.
- Wire decoder (Step 1), bank array (Step 2), fwd buffer (Step 3) into the tick.
**Validation:** drive via a minimal SoC (the `insitu_cache_tb.py` pattern) and the calib trace replayer: per-access data byte-correct; calib traces replay without error; per-FSM-state cycle counters (`fsmcnt_*` twins, `core.sv:741-756`) sane (ratio checks). **NOT** a cycle match yet.

### Step 5 — par_coalescer rewrite (`insitu_cache_par_coalescer.{cpp,py}`) — *high* (2-3 days)
**Unblocks: the wide cache interface + multi-port grouping.** Implement the CSHR FSM (`req_coalescer_v2.sv:113-432`: `current_hit`/`next_hit`/`update_CSHR`/watchdog, IDLE/VALID, open-window-accumulate-then-emit), the 3 depth-4 per-port FIFOs folded into one lockstep deque, `write_mixed_addr` (write-bit in key MSB so R/W never co-merge), the wide last-writer-wins merge (`equal_window.sv:269-304`, ascending port index, higher wins), and `rsp_spliter_v2` (multi-cycle, `handshake_mask`, snapshot). Carry hitmap/ofsts/member-tokens/512b data in a **side-map keyed by IoReq\*** (not scratch args). `non_coalescer` baseline behind `coalesce_enable=False`. ExtFactor>1 demux stubbed (off in CachePool default).
**Validation:** scoreboard-equivalent per-port data (expected word = `data[ofst*32 +: 32]`, `equal_window.sv:459`); calib replay; no deadlock (watchdog credit == unoccupied-port count exactly).

### Step 6 — Programmable xbar + bypass xbar + SPM remap + sync FSM — *high* (2-3 days)
**Unblocks: any-core→any-bank routing + flush + SPM.** `insitu_cache_xbar` replaces `insitu_cache_interco`: per-port-class private/shared/remote routing + modulo folding (`tcdm_cache_interco.sv:219-284`), MSB address rotation (`:363-405`), 1-cycle req spill + combinational rsp. `insitu_cache_bypass_xbar` (2:1, response demux on `bypass_coalescer` bit). `spm_remap.h` — exact integer div/mod by `cache_partition_set_for_cache` (NOT masks, `partitionable_flushable.sv:188-218`). `insitu_cache_sync_fsm` folded into the core/wrapper (shares tag/dirty arrays): 7 states, 4 opcodes, dirty-`rf` scan + evict-then-invalidate, whole-set clear, INIT walk, the 20-cycle drain interlock, `sync_block_upstream` gating. Support both the plain wrapper (`cache_part_base_i='0`, common) and the partitionable variant.
**Validation:** a targeted flush microbench (flush-then-reread returns memory, not stale lines); SPM-region addresses never index `[0..cache_base_for_SPM)`; vfadd still green (it issues no `cache_sync`, so flush is validated separately).

### Step 7 — System composition — *high* (3-4 days)
**Unblocks: the integrated 16-core topology + closed-loop on real geometry.** `cachepool_tile.py` (5 per-port-class xbars + 4 cores + spill regs + AMO on lane 4 + tile flush tracking), `cachepool_group.py` (4 tiles + 5 remote xbars, source-tile-mod-N selection), `cachepool_cluster.py` (group + NAPOT L2 xbar + peripheral + DRAMSys DDR4 on 4 channels). `spatz_cache_amo` RMW/LR-SC shim. `cachepool_peripheral` (CSRs + tile-granular flush controller + `l1d_busy` gating). IoReq must carry `user` fields (core_id, tile_id, bank_id, req_id, is_amo, burst) in a side-deque. Provide a fixed-latency serializing responder fallback so DRAMSys (40-min build) is optional for fast functional runs.
**Validation:** data correct end-to-end on the 16-core config; AMO/LR-SC atomicity micro-test; flush ordering under `l1d_busy`.

---

## 5. Integration & topology

The structural composites reproduce the RTL nesting exactly (`cachepool_pkg.sv:29-67`): **Cluster → Group(4 tiles) → Tile(4 cores × 5 TCDM ports, 4 per-core caches) → core internals**. Key faithfulness points:

- **Per-port-class xbars.** Each tile has `NrTCDMPortsPerCore=5` independent `tcdm_cache_interco` instances (one per port-class j), each routing that port-class across the 4 banks (`cachepool_tile.sv:604-652`). Structurally faithful = 5 `InsituCacheXbar` instances per tile; the current model merges them. The L1 is **shared, not private** — any core reaches any bank by address (intra-tile via the 5 xbars, cross-tile via the remote xbars). Keep the structure map right on this.
- **Remote xbar.** 5 `cachepool_remote_xbar` instances per group (`cachepool_group.sv:399-432`), `NumInp=NumOut=NumTiles*NumRemotePortCore=4`. Request lands in the dst slot indexed by **SOURCE tile mod N**; response leaves on the same slot (`:285-295`). With `NumRemotePortCore=1` the mod is trivial (slot 0) so the 4-tile default is safe — but do not hardcode it.
- **AMO/LR-SC.** `spatz_cache_amo` instanced on lane j=4 only (`cachepool_tile.sv:658`). Reservation table updated on *every* accepted req; SC success = reservation addr match and not cleared by a cross-core write between LR/SC. The RMW FSM holds input back-pressured for the whole read-modify-write.
- **Peripheral.** CSR set (`dynamic_offset` def 14, `l1d_private`, `private_start_addr` def 0xA000_0000) + tile-granular flush controller (lock / ready-pulse / `l1d_busy`). `l1d_busy` gates ALL TCDM (q_valid AND q_ready) during a flush — modeled as request reject/re-enqueue, not leaked latency.
- **DRAMSys DDR4 on refill.** Per-controller refill → tile inverse address rotation + `bank_id=cb+1` stamp → group slice → cluster `scrambleAddr` + NAPOT channel decode (`cachepool_cluster.sv:626-724`) → 4 channels → DRAMSys DDR4 (`dram-type=ddr4`). The address must be un-scrambled inside the DRAM model (or DRAMSys config matched) or refills corrupt. A fixed-latency serializing responder is the default fast-functional fallback; DRAMSys is enabled for the calibration pass.

---

## 6. Validation strategy

**During build (every step, functional only):**
- vfadd 15/15 (`retval=0`) on the fallback path always; on the structural path once Step 7 wires it.
- Calib traces (`ManyRVData_rebase/reports/cache_calib/traces/sample.trace`) replay without error; per-port response data byte-identical to the RTL scoreboard (`equal_window.sv:446-490`).
- WR==RD invariant (every store value == subsequent load value).
- Per-component micro-drivers (decoder hand-trace, bank conflict R+W, fwd-buffer hit/miss/wb, coalescer scoreboard, AMO atomicity, flush-then-reread).
- Per-FSM-state cycle counters (`fsmcnt_*` twins) as a silent-miscount tripwire.

**Final calibration phase (the only place cycle counts are tuned):**
1. **Open-loop vs `rtl_ref_1t_2026-06-16`.** Run the *same* calib traces through the structural core + the serializing memory model; diff the per-access `latency` column against the RTL reference CSVs. Reference anchors to re-confirm (config 512): warm read-hit = 10 cyc isolated / 7 cyc streaming; cold read-miss = MemLatency + 17; miss throughput serialized ≈ 1/(MemLatency+17); single-port hit ceiling ≈ 0.86 acc/cyc (current model hits 0.877). Tune *only* the per-tick step counts (bank read latency, spill latency, install rate) — never re-introduce up-front latency knobs.
2. **Closed-loop `region_cyc` table.** Run real Spatz kernels on the 16-core `cachepool_fpu_256` config with DRAMSys DDR4; diff per-region cycle counts against the RTL `region_cyc` reference. Target the <5% band the approximate model already meets on four kernels (`fmatmul M32` mean Δ 3.9; `fdotp` is the known inherent miss-path outlier).
3. **Promotion gate.** Only when (a) structural vfadd 15/15, (b) calib per-access diff within the open-loop band, AND (c) closed-loop `region_cyc` within target, flip `structural_mode` default to `True`. The approximate components stay in-tree as the `structural_mode=False` fallback until at least one full release cycle confirms no regression; only then consider removal.

---

## 7. Risks, open questions, and what to build FIRST

### Build FIRST: the Decoder/Encoder datapath (`insitu_cache_decode.{hpp,cpp}`, Step 1)

**Why:** it is the one piece every other structural component transitively needs (the core can't classify a request, the bank can't pick a way, the coalescer/xbar can't agree on geometry without it), yet it is the *cheapest to verify in isolation* (pure functions, a hand-computed RTL trace is enough) and it carries the single highest-leverage correctness fix — replacing the Knuth multiplicative hash (`controller.cpp:650`) with the exact RTL XOR-fold. Getting the hash field positions right (`tag_lo = depth_lo + log2(num_sets)`) is a prerequisite for *every* downstream conflict/eviction behavior; getting it wrong silently mis-routes lines everywhere. It is medium effort, zero new event/port surface, and unblocks the entire bottom-up chain.

### Top risks
- **IoReq parking & arg aliasing.** The per-cycle FSM holds `IoReq*` across cycles and `resp()`s later; `get_args()`/`save()`/`restore()` slots are shared (CLAUDE.md). Keep all per-request context (MSHR reader lists, coalescer member tokens, AMO state, user metadata) in side structures keyed off the parked `IoReq*`, never scratch args.
- **In-situ MSHR count accounting.** Wrong `num_subarray`/`one_more`/`extra_subarray` (MSHR_FULL exit) hangs cores (RTL warns the same, `core.sv:241-251`). Replay exactly one `resp()` per reader.
- **Single bank-port arbitration & same-line hazard.** Exactly ONE stage-0 grant/cycle; the same-line write/read hazard (`core.sv:864-871`) is a *functional* bug if omitted (stale data on tight RAW), not just timing.
- **Forwarding-buffer read-before-write ordering.** Must snapshot all `_q` at cycle start and write only `_d`, then swap; in-place mutation silently diverges (the biggest fwd-buffer trap).
- **Bank within-cycle phase.** WR_CONFLICT needs writes to mark `wrote_this_cycle[]` *before* reads classify — enforce writes-first ordering in the tick.
- **DRAMSys address scramble.** Refill un-scramble must match or data corrupts; DRAMSys is heavy (40-min build) so keep the fixed-latency fallback.
- **Cycle counts will shift.** The XOR-fold hash and the real CSHR change which lines collide and when beats emit. This is by design — the gate is functional, calibration is deferred.

### Open questions to resolve from `cachepool_cache_ctrl.sv` / build defines (not in the assigned RTL files)
1. **FIFO depths** — `core.sv` defaults 16, `top.sv` 4; CLAUDE.md says track the *CachePool ctrl* defaults. These drive STALL frequency hence timing — confirm from `cachepool_cache_ctrl.sv`.
2. **`ENABLE_MULTI_READ_PEND`** — if defined in the CachePool build, the secondary-read linked-list MSHR must be modeled; if not, the simple subarray-append path suffices. Build the simple path first.
3. **`USE_ORIGINAL_LRU`** — forks victim choice on the LRU path; default build uses first-`lru==0`. Confirm from ctrl defines.
4. **`NumPseudoDualBanks` (BankFactor)** — `cache_top` default 1, integration likely 2. With 1, *every* same-cycle R+W to different rows is a WR_CONFLICT — materially changes conflict timing.
5. **`DataPartSplit`** — =1 (canonical) keeps PartSplit>1 paths stubbed; >1 puts part-gating/skewed-fold on the critical path.
6. **Canonical geometry** — 4-way/128-set (`make_cachepool_512_config`) vs 4-way/256-set (calib DUT); hash field widths depend on it.
7. **Sync/CSR delivery** — whether flush is delivered as Io requests to an `i_FLUSH` slave or an out-of-band wire-vector (more faithful); and whether `dynamic_offset`/`num_private_cache`/`private_start_addr` are mmapped CSRs or compile-time constants (`cachepool_cache_ctrl` hardwires `cache_part_base_i='0`).
8. **Upstream consumer protocol** — whether the Spatz VLSU/TCDM initiators can accept async `resp()`/`IO_REQ_PENDING` (the current closed-loop uses `inline_sync_miss` because v1 ISS is synchronous-only). If still synchronous, the coalescer's multi-cycle splitter is timing-only (approach B), and the structural core must keep an `inline_sync_miss`-style synchronous-slave mode for the cluster path. The newer async Spatz model (noted in memory) would let the structural park+resp path run natively with a one-flag change.

Relevant existing files: `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_GVSoC/gvsoc/core/models/cache/insitu/insitu_cache_controller.cpp`, `insitu_cache_interco.cpp`, `insitu_cache_par_coalescer.cpp`, `insitu_cache_tile.py`, `insitu_cache_config.py`; integration site `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_GVSoC/gvsoc/pulp/pulp/snitch/snitch_cluster/snitch_cluster.py:285-345`.
