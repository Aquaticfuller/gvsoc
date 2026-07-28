# InSitu Cache -- RTL vs GVSoC Model Gap Analysis (2026-06-15)

## 1. Summary (how close the model is; the 3-4 biggest gaps)

The GVSoC model (`core/models/cache/insitu/`) is a deliberately **cycle-approximate** (<5% target) timing model that calibrates well against the *single-controller* RTL standalone testbench (warm read-hit 10/7, cold miss MemLatency+17, serialized miss throughput, single-port hit ceiling ~0.86 acc/cyc; see `insitu_cache_config.py` factory + calib factory). For the **per-controller datapath microbenchmarks the calib TB exercises, the model is faithful at the cycle level on the headline numbers.** Where it diverges is *structural* — it reproduces the right latencies via lumped knobs rather than the RTL's actual structures, and it models the **wrong overall topology** (v1, not v2).

The 3-4 biggest gaps, in order of severity:

1. **TOPOLOGY (ABSENT, closed-loop-only).** The model implements the OLD v1 topology: N independent narrow controllers + a hashed N→M crossbar (`insitu_cache_interco`) + N write-through coalescers + an L2 fan-in. The current RTL per-core controller (`cachepool_cache_ctrl`) is a **single wide 512b cache** behind a **N→1 `par_coalescer`** + a **2:1 reqrsp_xbar Snitch-scalar bypass** + a **refill burst/writeback FSM**. The model's `make_cachepool_512_config()` builds `num_controllers=4` — a fundamentally different shape. (gvsoc-model-side: absent[1]; `insitu_cache_config.py:426`).

2. **CROSS-TILE FULLY-SHARED L1 SUBSTRATE (ABSENT, closed-loop-only).** The verified active config is NumCores=16 / NumTiles=4 / 4 cores/tile, with **one controller per core but every CC reaching all banks via remote ports + an inter-tile group xbar**, **runtime-programmable bank interleaving** (`dynamic_offset` CSR), and **software-repartitionable tile-private vs shared banks** (`num_private_cache` + `private_start_addr` CSRs). The model has **no remote-port path, no inter-tile xbar, no private/shared partitioning, no address rotation** — only per-tile-local hashed N→M routing (`insitu_cache_interco.cpp:122-237`). (tile-cc; group-cluster-interco-amo-periph; gvsoc-model-side: absent[1]).

3. **STRUCTURAL par_coalescer (ABSENT/APPROX).** RTL `par_coalescer_equal_window` has a CSHR window FSM, per-port depth-4 FIFOs, hitmap/ofsts wide-line byte-strobe merge, round-robin next-tag arbitration, a multi-cycle response splitter, and ExtFactor virtual ports (par-coalescer map). The model has only an `enable_input_coalesce` latency-window trick in the interco (calib-only) — **no wide 512b merge, no hitmap, no rsp-splitter, misses are not coalesced** (`insitu_cache_interco.cpp:184-236`).

4. **SYNC/FLUSH CONTROL + SPM REMAP (ABSENT/GATED-PARTIAL).** RTL has a 7-state flush/sync FSM with a CHECK_PEND drain interlock (`CheckPendDrainCycles=20`), 4 `cache_sync_insn` opcodes, per-line writeback-on-flush, upstream gating, and arithmetic SPM tag/set division-remap in the `partitionable_flushable` wrapper. The model has only a behavioural drop-all `flush_all()` (invalidate) and a capacity-shrink SPM fold; `enable_flush` is read but never used in logic (`insitu_cache_controller.cpp:382-402`; gvsoc-model-side absent[4-6]).

The faithfully-modelled core (don't-touch list, §5) is the **single-controller line-state FSM, in-line MSHR merge/drain, refill/eviction datapath, and the calibrated latency/throughput knobs** — these are exactly the things the open-loop calib TB validates.

## 2. Architecture-level gaps

### 2.1 System hierarchy (Group → Tile → CC)
RTL: cluster instantiates a group (`NumTiles>1`) of 4 tiles; each tile = 4 CC + 4 per-core controllers + 5 per-port-class cache xbars + AMO shim + flush controller + tag/data SRAM banks (tile-cc; group-cluster-interco). The model collapses this to a **single tile of 4 controllers + 1 interco** (`insitu_cache_tile.py:56-136`); there is no Group, no cluster L2 fan-in to NumL2Channel=4 channels, no CC (Snitch+Spatz) complex. **Severity: ABSENT (closed-loop-only).**

### 2.2 Shared-L1 substrate (per-port-class de-interleaving)
RTL: the 5 TCDM ports of each core are de-interleaved into **5 independent `tcdm_cache_interco` instances, one per port-class j**, each a 5×5 crossbar (4 local cores + 1 remote-in → 4 local banks + 1 remote-out), so all 4 cores' lane-j ports contend for all 4 controllers — this is what makes the L1 fully shared (tile-cc mechanisms[1]; `cachepool_tile.sv:541-652`). The model's single `insitu_cache_interco` is one flat N→M (20→4) crossbar with no per-port-class structure and no per-bank rr_arb_tree contention. **Severity: ABSENT — sharing topology not represented.**

### 2.3 Programmable bank partitioning / interleaving
RTL: `BankSel = addr[dynamic_offset +: log2(NumCache)]` with a **runtime CSR `dynamic_offset`** (peripheral reset 14); `num_private_cache` (CSR `l1d_private`) repartitions the 4 banks into 5 private/shared modes with modulo folding; `private_start_addr` (CSR, reset 0xA000_0000) classifies each request private vs shared (group-cluster-interco mechanisms[2-3]; `tcdm_cache_interco.sv:139-267`). The model uses a **fixed** `dynamic_offset` (default 2 ⇒ 4B interleave) bit-slice with no partition modes, no private/shared classification (`insitu_cache_interco.cpp:165-168`). **Severity: ABSENT.**

### 2.4 Remote / inter-tile xbar
RTL: shared accesses whose `TileID != tile_id` route to a remote-out slot; the group xbar is 5 per-port-class `reqrsp_xbar` (4×4, PipeReg=1/RspReg=1, +1 req +1 rsp cycle) with `dst*N+src%N` request select mirrored on response so req/rsp share a master port; all traffic to one remote tile funnels through one pipeline (ordering invariant) (group-cluster-interco mechanisms[3-4]; `cachepool_group.sv:254-432`). The model has **no remote path at all** — remote bandwidth caps, the +2-cycle remote hop latency, and cross-tile ordering are unmodelled. **Severity: ABSENT (closed-loop-only).**

### 2.5 Address rotation + refill inverse-rotation
RTL: after the xbar, routing bits (BankSel, +TileID for shared) are rotated to the address MSB so the cache sees a dense tag/index; the refill path applies the exact inverse (`tcdm_cache_interco.sv:320-405`; `cachepool_tile.sv:1041-1110`). The model does plain tag/set bit-slicing with no rotation (`insitu_cache_controller.cpp:99-113`). **Severity: ABSENT** (functionally irrelevant to a single-controller cycle model, but absent for the shared config).

### 2.6 AMO / LR-SC
RTL: a `spatz_cache_amo` shim sits on the **scalar lane (j=4) only**; RMW AMOs serialize through a 4-state FSM (Idle→DoAMO→WriteBackAMO→Wait), blocking that port for a full read+compute+write+wait round-trip; LR/SC use a single-entry reservation table (tile-cc; group-cluster-interco; `spatz_cache_amo.sv:67-303`). The model has **no AMO/LR-SC datapath** — but the RTL controller shell (`cachepool_cache_ctrl`) also has none (AMO is upstream of the controller). **Severity: ABSENT, but consistent** — only matters if the shared-tile substrate is modelled; AMO is correctly out of scope for the per-controller calib.

### 2.7 Peripheral / cache_sync delivery
RTL: a memory-mapped CSR block (`cachepool_peripheral`) delivers `cache_sync`/flush/partition config to all tiles — `CFG_L1D_INSN` (2-bit), `CFG_L1D_TILE_SEL`, `L1D_PRIVATE`, `L1D_ADDR`, `XBAR_OFFSET`, lock/busy tracking, `FLUSH_STATUS` (group-cluster-interco; `cachepool_peripheral.sv:129-178`). The model exposes flush ports only in the multi-controller config and has a behavioural `flush_all()`; there is **no CSR block, no 4-opcode decode, no lock/busy gating, no tile_sel, no SPM/partition CSR delivery**. **Severity: ABSENT.**

### 2.8 Multi-tile scale
The model cannot scale beyond one tile (no Group/cluster). Performance effects of 16-core contention on 16 shared controllers, remote-tile latency tails, and L2 channel fan-in are **entirely absent**. **Severity: ABSENT (closed-loop-only).**

## 3. Microarchitecture-level gaps

### 3.1 Datapath pipeline
RTL core is a 2-stage read-then-decode pipeline + 7-state FSM: cycle1 issue SRAM read, cycle2 decode+push resp_fifo, gated by SRAM Latency=1; encoder/decoder are pure combinational (datapath-core; decoder-encoder-fwdbuf). The model has **no structural pre-read/decode/encode stages** — the ~10-cyc isolated / 7-cyc streaming warm read-hit is reproduced via `hit_latency_cycles` (factory 9) + a streaming warmth gradient (`insitu_cache_controller.cpp:457-469`). **Severity: APPROX** — open-loop calibratable (and calibrated to 10/7).

### 3.2 MSHR / outstanding model
RTL: the MSHR is **in the line itself** — a READ_PEND line's data payload becomes an `mshr_subarrays` list (~`MaxNumSubarray` = Line/InfoStoreWidth ≈ 8 sub-entries); same-line reads merge into the subarray list; MSHR_FULL_STALL when full; drain one beat/sub on refill via the Retrieve FIFO (datapath-core mechanisms[1-2]). The model uses a **per-set side-deque `mshr_`** of `MshrEntry`, save/restore-parked, with `mshr_drain_cycles_per_subarray` per later-cycle subarray (`insitu_cache_controller.cpp:520-541, 820-871`). Outstanding-miss bound: RTL = distinct (set,way) PEND lines, throttled by MissFifoDepth=4 + single-outstanding-refill gate; model = `defer_refills` install-pipe + FIFO-level counters. **Severity: APPROX** (behaviourally close; no per-way `link_ptr`/`is_prime` linked list for ENABLE_MULTI_READ_PEND).

### 3.3 Coalescer: merge vs latency-trick
RTL `par_coalescer` does a genuine **wide-line byte-strobe merge** (hitmap/ofsts, last-writer-wins on byte overlap), current-hit + next-hit dual acceptance, watchdog window release (credit = unoccupied ports), and a multi-cycle response splitter; ExtFactor virtual ports extend the window across time (par-coalescer). The model's interco `enable_input_coalesce` is **only a 1-cycle same-line read-hit latency window** — no hitmap, no wide merge, no splitter, **misses not coalesced**, calib-only (`insitu_cache_interco.cpp:184-236`). The model *also* carries a `write_through_merger`-style 3-state coalescer (`insitu_cache_coalescer.cpp`), but it is **dormant** (`write_through_mode=False`) and models the legacy seq/write-through style, not `par_coalescer`. **Severity: APPROX (the deployed `par_coalescer` is ABSENT structurally).**

### 3.4 Banking / bank-conflict
RTL: pseudo-dual-port banks (`NumPseudoDualBanks` = BankFactor=2) with a 6-state R/W FSM — WR_DIFF_BANK free, WR_SAME_ADDR forwarded, **WR_CONFLICT = 1-cycle read-retry penalty**; folded/skewed data banks (PartSplit=4) with a per-column write-priority grant (`l1_data_bank_gnt`) that **drops conflicting reads of other ways** (tcdm-wrapper-banking; tile-cc mechanisms[7]). The model collapses all of this into a **per-set `set_busy_until_` cyclestamp** + `bank_accept_cycles` (default 1) (`insitu_cache_controller.cpp:480-484`). Bank conflicts, the WR_CONFLICT penalty, and folded read-degrant are **not separately modelled**. **Severity: APPROX** (the WR_CONFLICT/data-bank contention that caps BurstLength=1 miss throughput at ~0.25/cyc is not represented; matters only if BurstLength=1 is calibrated).

### 3.5 Forwarding buffer
RTL `sram_forwarding_buffer` (1-entry, the active variant): combinational read-hit suppress (frees SRAM port — throughput win, registered 1-cyc latency to match SRAM), write absorb + lazy writeback, part-bitmap additive populate, RAW forwarding (`EnableRawForwarding=1`), in-flight populate fast path, speculative writeback (decoder-encoder-fwdbuf; tcdm-wrapper-banking). The model has only a **single `fwd_buffer_line_` tracker** giving `fwd_hit_latency_cycles` (factory 6) + skip-set-busy — **no buffer FSM, no dirty/WB, no part-validity, no write-absorption, no spec-WB, no multi-entry variant** (`insitu_cache_controller.cpp:452-456`). `use_forwarding_buffer` is largely informational. **Severity: GATED-PARTIAL** (perf folded into hit_latency; calibratable).

### 3.6 Victim policy
RTL: `UseHashWaySelect=0` default at ctrl is full-assoc, but CachePool forces hash-way ON when fwd-buffer/fold is enabled; hash way = `tag_low XOR set_low`; victim in full-assoc = first way with LRU credit==0 (or min-LRU under USE_ORIGINAL_LRU) (decoder-encoder-fwdbuf). The model's `pick_victim()` uses a **Knuth-style hash** `(tag*2654435761 ^ set*0x9E3779B1)%ways` (documented approximation, **not** the RTL polynomial) or full-LRU (`insitu_cache_controller.cpp:643-656`). Per-address way placement and exact conflict-miss pattern diverge. **Severity: APPROX.**

### 3.7 SPM / flush FSM
RTL: 7-state flush/sync FSM (IDLE→READ_BANK→CHECK_PEND→{FLUSH|INIT}→FINISH), set-walk with per-dirty-line writeback, `CheckPendDrainCycles=20` pre-flush bubble, `sync_block_upstream`/`sync_block_install` gating, 4 opcodes; SPM via arithmetic tag/set division-remap in `partitionable_flushable` (tcdm-wrapper-banking fsms; mechanisms). The model: behavioural `flush_all()` drop-all only; SPM = capacity-shrink fold (`enable_spm`/`bank_depth_for_spm`), **not** the RTL division-remap; **no CHECK_PEND drain, no per-line writeback, no upstream gating, no opcode decode** (`insitu_cache_controller.cpp:382-402, 101-109`). **Severity: ABSENT/GATED-PARTIAL.**

### 3.8 Refill / eviction timing
RTL: read miss = **single burst** (is_burst, burst_len=3) → 4×128b beats assembled LSB-first in a 3-state FSM (Idle→Partial→Refill, with a Refill→Partial fast path); **single-outstanding-read gate** (`refill_read_outstanding_q`); writeback = 4 **separate single** 128b writes (no burst), serialized (Read/Write req FSM), `write_strb_is_zero` drops empty beats; PartSplit>1 eviction adds +2 cycles for a full-line victim read (percore-ctrl-axi; datapath-core; calib-tb-refs). The model: `issue_refill` with `set_duration(beats)` for downstream bandwidth only (no beat iteration/reassembly FSM); single-outstanding reproduced via `defer_refills` + `refill_drain_cycles` + calib mem `mem_busy_until_`; eviction is fire-and-forget single-slot + flat `folded_evict_penalty_cycles` (`insitu_cache_controller.cpp:698-748`). Cold-miss = mem full_latency + `refill_bank_write_cycles` + `miss_penalty_cycles` calibrated to MemLatency+17. **Severity: APPROX — open-loop calibratable (and calibrated).**

## 4. Consolidated GAP MATRIX

Severity legend: **MODELED** = structurally present & faithful; **APPROX** = behaviour reproduced via lumped knobs, calibratable; **GATED-PARTIAL** = partial/flag-gated stub; **ABSENT** = not represented.

| Feature | RTL behaviour (cite) | GVSoC model today (cite) | Severity | Open-loop calibratable? | Closed-loop only? |
|---|---|---|---|---|---|
| Line-state FSM (INVALID/VALID/READ_PEND/WRITE_PEND) | 2-bit enum, decoder relies on exact encoding (`insitu_cache_pkg.sv:19`) | Real `LineState` enum, transitions on alloc/install (`insitu_cache_controller.cpp:32-49,570,799`) | MODELED | n/a | no |
| Address tag/set/offset split | `{tag,depth,ofst}` (`decoder.sv:110`) | Real bit-slicing (`controller.cpp:99-113`) | MODELED | n/a | no |
| Tag lookup / hit detect | full-assoc loop or hash SOP (`decoder.sv:195-239,163-176`) | linear way scan (`controller.cpp:628-639`) | MODELED | n/a | no |
| Hit-under-miss classification (hit_pend) | same-type pend merge (`decoder.sv:173-176,198-237`) | same-type pend-merge classified (`controller.cpp:404-624`) | MODELED | n/a | no |
| In-line MSHR merge + drain-on-refill | line payload = subarray list, ~8 subs, MSHR_FULL_STALL (`core.sv:1631-1762,2320-2355`) | per-set side-deque save/restore, `mshr_drain_cycles_per_subarray` (`controller.cpp:520-541,820-871`) | APPROX | yes | no |
| Refill issue + install datapath | miss FIFO + re-decode match (`core.sv` miss/refill) | `issue_refill`/`refill_resp_handler` re-decode set/tag (`controller.cpp:698-816`) | APPROX | yes | no |
| Refill burst reassembly (4×128b LSB-first, 3-state FSM) | Idle/Partial/Refill + fast path (`cachepool_cache_ctrl.sv:800-893`) | beats only as `set_duration` for bandwidth (gvsoc-model-side approx[6]) | APPROX | yes | no |
| Single-outstanding-read miss gate | `refill_read_outstanding_q` (`cachepool_cache_ctrl.sv:579,684`) | `defer_refills`+`refill_drain_cycles`+calib mem serialization (`controller.cpp:90-96`) | APPROX | yes | no |
| Cold-miss latency = MemLatency+17 | calib reference (CHARACTERIZATION.md) | `refill_lat` = mem + bank_write + miss_penalty (`config.py:404,447`) | APPROX (calibrated) | yes | no |
| Warm read-hit 10/7 | calib reference (CHARACTERIZATION.md) | `hit_latency_cycles`=9 + streaming gradient (`config.py:404,495`) | APPROX (calibrated) | yes | no |
| Dirty-victim eviction / writeback | 4 single 128b writes, serialized (`cachepool_cache_ctrl.sv:695-786`) | fire-and-forget single-slot + `folded_evict_penalty` (`controller.cpp:552-568,722-748`) | APPROX | yes | no |
| 7-state stall FSM (RESP/MISS/EVIC/ALL_PEND/MSHR_FULL/WR_CONFLICT) | `core.sv:422-430` | IO_REQ_DENIED on FIFO/commit checks; states not explicit (gvsoc approx[9]) | APPROX | partial | no |
| FIFO depth gating (miss/evic/retr) | depth-4 FIFOs → stall states (`core.sv`) | real gating counters (`controller.cpp:531-547`), bind under defer_refills | GATED-PARTIAL | yes | no |
| Hash-WAY victim select | `tag_low XOR set_low` (`decoder.sv:112-118`) | Knuth-style hash, not RTL polynomial (`controller.cpp:649-655`) | APPROX | yes | no |
| LRU victim (full-assoc) | first-LRU0 or min-LRU (`decoder.sv:267-282`) | per-set MRU-front order list (`controller.cpp:491-497`) | APPROX | yes | no |
| LRU credit transition table | encoder MRU promote/decrement (`encoder.sv:112-167`) | simple MRU promote, no credit table (`controller.cpp:491-497`) | APPROX | yes | no |
| Pseudo-dual-port banking + WR_CONFLICT 1-cyc penalty | 6-state R/W FSM (`tcdm_wrapper.sv:2049-2268`) | per-set `set_busy_until_`+`bank_accept_cycles` (`controller.cpp:480-484`) | APPROX | partial | no |
| Folded/skewed data banks + write-priority read-degrant | `l1_data_bank_gnt`, PartSplit=4 (`cachepool_tile.sv:1136-1340`) | flat `folded_evict_penalty`+`refill_bank_write` (gvsoc approx[5]) | APPROX | partial | no |
| 1-entry forwarding buffer (suppress/absorb/RAW/spec-WB) | full FSM (`sram_forwarding_buffer.sv`) | single `fwd_buffer_line_` tracker, latency only (`controller.cpp:452-456`) | GATED-PARTIAL | yes | no |
| Multi-entry forwarding buffer | `sram_forwarding_buffer_multi`, PLRU (not default) | absent (gvsoc absent[12]) | ABSENT | n/a | no (RTL off too) |
| RAW bank hazard hold | 1-cyc hold unless buf full-cov (`core.sv:862-936`) | not modelled (folded into latency) | ABSENT | partial | no |
| Structural par_coalescer (CSHR, FIFOs, hitmap, rsp-splitter, ExtFactor) | `par_coalescer_equal_window.sv` | `enable_input_coalesce` latency window only (`interco.cpp:184-236`) | APPROX (structure ABSENT) | yes | no |
| Wide 512b write-data/wmask merge (last-writer-wins) | `gen_down_req_data` (`par_coalescer_equal_window.sv:269-304`) | no wide merge (gvsoc absent) | ABSENT | n/a | partial |
| Coalescer watchdog window release | credit=unoccupied ports (`req_coalescer_v2.sv:184-206`) | coalescer `watchdog_cycles`=4 (dormant WT path) (`coalescer.cpp:203-218`) | GATED-PARTIAL | yes | no |
| Response splitter multi-beat under backpressure | `rsp_spliter_v2.sv:77-137` | absent (gvsoc absent[11]) | ABSENT | n/a | partial |
| Snitch scalar bypass (2:1 reqrsp_xbar, word pad/extract) | `cachepool_cache_ctrl.sv:419-493` | latency knob `scalar_bypass_port`/`scalar_hit_latency` only (`controller.cpp:412-451`) | GATED-PARTIAL | yes | no |
| seq_coalescer family / non_coalescer | alternate styles (seq-coalescer-wtmerger) | absent (gvsoc absent[14]) | ABSENT | n/a | no (RTL unused) |
| write_through_merger (byte-RMW, read-monitor flush) | only if WriteThroughMode=1 (`write_through_merger.sv`) | `InsituCacheCoalescer` 3-state FSM, dormant (`coalescer.cpp`) | GATED-PARTIAL | yes | no (RTL off too) |
| Write early-ack + write-commit serialization | winfo FIFO, wresp=~empty (calib-tb-refs) | `write_hit_latency`+`write_commit_cycles` busy-until (`controller.cpp:417-433`) | APPROX (calibrated) | yes | no |
| Per-set dirty register file (meta-write elision, flush source) | `dirty_rf` true 1R/1W (`tcdm_wrapper.sv:1558-1612`) | per-line dirty bool only (gvsoc approx[12]) | APPROX | partial | no |
| Flush/sync 7-state FSM + CHECK_PEND drain (20cyc) | `tcdm_wrapper.sv:750-1098` | behavioural `flush_all()` drop-all (`controller.cpp:382-402`) | GATED-PARTIAL | partial | yes |
| 4-opcode cache_sync_insn (flush/inval/flush+inval/init) | `tcdm_wrapper.sv:799-801` | `enable_flush` read but never used (gvsoc absent[4]) | ABSENT | n/a | yes |
| SPM tag/set division-remap (partitionable_flushable) | arithmetic divide/modulo (`partitionable_flushable.sv:200-218`) | capacity-shrink fold only (`controller.cpp:101-109,298-302`) | GATED-PARTIAL | partial | yes |
| Address set-index hashing (AddrHashLength) | XOR-fold (disabled in prod, AddrHashLength=0) | absent (gvsoc absent[7]) | ABSENT | n/a | no (RTL off) |
| Per-port-class shared cache xbar (5×5×5) | `cachepool_tile.sv:541-652` | flat 20→4 interco, no per-class (`interco.cpp:122-237`) | ABSENT | n/a | yes |
| Programmable bank mapping (dynamic_offset CSR) | runtime CSR (`tcdm_cache_interco.sv:229`) | fixed `dynamic_offset`=2 (`config.py interco`) | ABSENT | n/a | yes |
| Runtime private/shared repartition (num_private_cache) | 5 modes + modulo fold (`tcdm_cache_interco.sv:219-267`) | absent (gvsoc absent[1,8]) | ABSENT | n/a | yes |
| Remote/inter-tile xbar + routing/ordering | group `reqrsp_xbar` (`cachepool_group.sv:399-432`) | absent (gvsoc absent[1]) | ABSENT | n/a | yes |
| Address rotation + refill inverse-rotation | `tcdm_cache_interco.sv:320-405` | plain bit-slice, no rotation | ABSENT | n/a | yes |
| AMO / LR-SC (scalar lane FSM) | `spatz_cache_amo.sv:67-303` | absent (RTL has it upstream of ctrl) | ABSENT (consistent) | n/a | yes |
| Cluster L2 fan-in xbar (20→4 channels, burst affinity) | `cachepool_cluster.sv:626-723` | composite `l2` master only (`insitu_cache_tile.py`) | ABSENT | n/a | yes |
| Peripheral CSR block (flush/partition delivery, lock/busy) | `cachepool_peripheral.sv:129-178` | absent | ABSENT | n/a | yes |
| Per-port requester outstanding budget (32) | NumSpatzOutstandingLoads=32 (calib-tb-refs) | not modelled in controller (CC-level) | ABSENT | yes | partial |
| Spatz per-lane response reorder FIFO (depth 32) | `cachepool_cc.sv:347-369` | absent (no CC) | ABSENT | n/a | yes |
| Per-output rr_arb_tree bank arbitration | `reqrsp_xbar` round-robin | accept arbitration via busy-until / per-cycle (`interco.cpp:198-220`) | APPROX | yes | no |
| Interco accept-bandwidth (accumulate vs per-cycle) | coalescer+wide-datapath accept BW | `output_busy_until_` or `per_cycle_output_arb` (`interco.cpp:198-220`) | APPROX | yes | no |
| Functional data path (closed-loop coherence) | n/a (RTL inherent) | `carry_data_`/`functional_writethrough` backdoor (`controller.cpp:117-130,660-675`) | MODELED (model-only aid) | n/a | yes |
| Reset / INIT requirement | SRAM undefined, needs sync INIT op | model starts all-INVALID, no INIT op (gvsoc approx[15]) | APPROX | n/a | no |

## 5. What is already faithful (don't-touch list) and why

These are structurally present and validated by the open-loop calib TB; changing them risks regressing the calibrated numbers without improving fidelity:

1. **Single-controller line-state machinery** — the `LineState` enum and INVALID/VALID/READ_PEND/WRITE_PEND transitions mirror the RTL `cache_status_t` bit-semantics exactly (`insitu_cache_controller.cpp:32-49,570,799`). The decoder's pending/read-write split is the load-bearing contract and the model honours it.

2. **In-line MSHR merge + drain** — the per-set MSHR with same-cycle reader coalescing and per-later-subarray drain cost reproduces the RTL's in-situ hit-under-miss and the "K-sub read = K serialized response beats" behaviour (`controller.cpp:520-541,820-871`). It is the right *behaviour* even though the storage (side-deque vs line payload) differs.

3. **Calibrated latency stack** — warm read-hit 10 isolated / 7 streaming, warm write 8, RAW-forward 7, cold miss MemLatency+17, single-port hit ceiling ~0.86 acc/cyc, write throughput ~0.49 acc/cyc — all match the RTL standalone TB reference numbers (`config.py:404,408,409,411,447,495`; calib-tb-refs latencies). These knobs are the deliverable of the calibration effort; they are MemLatency-independent where the RTL is, and track the gap-sweep gradient.

4. **Serialized miss throughput model** — `defer_refills` + `refill_drain_cycles` + the serializing calib `MemLatency`/`mem_busy_until_` responder faithfully reproduce the single-outstanding-line-refill behaviour (~1/(MemLatency+17), *not* divided by accept depth) that is the #1 RTL miss-throughput characteristic for the shipping BurstLength=4 config (`controller.cpp:90-96`; calib-tb-refs mechanisms[3]).

5. **Refill/eviction datapath functional correctness** — the re-decode-on-refill matching (no CAM), dirty-victim writeback emission, and the closed-loop `inline_sync_miss`/`functional_writethrough` coherence path are what let closed-loop Spatz runs terminate; these are model-only correctness aids with no RTL counterpart and should be left intact (`controller.cpp:574-624,660-675`).

6. **FIFO-level gating counters** (miss/evic/retr, depth 4/4/16) — real backpressure counters returning IO_REQ_DENIED, matching the RTL depth-4 flow-FIFO knees, active under `defer_refills` (`controller.cpp:531-547`).

**Why not touch:** every item above is exercised by the per-controller calib TB whose reference numbers (`reports/cache_calib/`) the model is diffed against. The genuine fidelity work (per §1) is **additive structural modelling** of the v2 topology, the par_coalescer, the shared-tile substrate, and the flush/sync FSM — not rework of the calibrated single-controller core. Note that AMO and `sram_forwarding_buffer_multi` are ABSENT on *both* sides for the active config (RTL multi-entry buffer off by default; AMO upstream of the controller), so they are not fidelity gaps for the calibrated DUT.
