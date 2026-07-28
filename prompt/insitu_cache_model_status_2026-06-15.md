# InSitu Cache GVSoC Model — Status Report (2026-06-15)

## 1. Executive summary

- The InSitu cache GVSoC model is a **cycle-approximate** (<5% timing-error target, not cycle-exact) performance model of the CachePool InSitu L1 data cache, implemented as three compiled C++ components — controller, hashed N→M interco, write-through coalescer — plus a Python config layer and composite tile, living under `core/models/cache/insitu/`.
- **Open-loop calibration** (the cache driven by a deterministic trace replayer against a fixed-latency serializing memory) is well-aligned to the RTL: all headline latency/throughput anchors match within ~7% at MemLatency 50, and the real-kernel per-access latency gap was closed to **+2.6..+6.4 cy mean on four kernels** (only `fdotp` still misses badly at +21.1, an inherent miss-path effect). The flagship synthetic number `coal_cold` wide @ML50 = **0.4961** acc/cyc and `fmatmul M32` mean Δ = **3.9 cy**.
- **Closed-loop integration** (the cache wired into a real Spatz cluster behind real cores) now runs a real Spatz kernel end-to-end for the first time: `examples/spatz/test-riscvTests-vfadd` with `use_insitu_cache=True` **PASSES all 15 test cases (retval=0, cycles=58001)** — it previously hung at boot.
- The open-loop **regression that briefly blocked the commit** (two driver flags leaking into the shared base config factory and bypassing the calibrated occupancy path, pushing `fmatmul M32` 3.9→7.5 and `coal_cold` 0.4961→0.6531) **is fixed** via the "Option-B" design: the two flags are treated as driver/integration flags, removed from the base factory, and set only at the closed-loop cluster site. A clean full build restores both the open-loop targets and the closed-loop pass.
- **Push state:** all four submodule commits (core `6362b3da`, `3d712809`; pulp `f0706bc`, `d8abb08`) are on `origin/insitu-cache`. The parent `main` is 19 commits ahead of `origin/main` and is intentionally kept local (submodules-only-push preference).
- **Largest open item:** the model still implements the *v1* topology (4 address-interleaved controllers + hashed crossbar) rather than the integrated RTL's structure — one single-wide-line cache **per core** (4 per tile, 4 tiles per group = 16 cores), each fronted by an N→1 `par_coalescer` + scalar bypass_xbar, with a cross-tile remote-access crossbar. This Phase-B refactor is documented but not done (see §9.2 for the corrected RTL hierarchy).

---

## 2. What the model is

### 2.1 Purpose & fidelity

The model is a **cycle-approximate** GVSoC performance model of the CachePool InSitu L1 data cache. The explicit fidelity target is **<5% cycle error** on streaming and random-access workloads, *not* cycle-exactness (`core/models/cache/insitu/README.md:1-4`; `prompt/insitu_cache_gvsoc_plan.md:20`). It reproduces RTL timing behaviour through calibrated latency/throughput knobs and a small number of structural mechanisms, rather than by mirroring the RTL micro-architecture gate-for-gate.

Two distinct usage modes exist, and the distinction matters throughout this report:

- **Open-loop** — the cache is driven by a deterministic *trace replayer* (`insitu_cache_calib`) that injects `port,rw,addr,size,delay` records and a fixed-latency *serializing* memory model answers refills. No real CPU. This is the mode the model is calibrated against the RTL standalone testbench in. In this mode the cache is a **pure timing model**: no data bytes are carried, so the per-access `latency` column is byte-identical to the calibration.
- **Closed-loop** — the cache is inserted into a real Spatz cluster between the cores/VLSU and the TCDM, driven by real RISC-V cores. This mode requires functional data movement (real loads must return real bytes) and a synchronous-slave protocol; both are enabled by two driver flags set only at the cluster site (see §2.4, §5).

### 2.2 Component architecture

The tile composite assembles one interco, N controllers, N coalescers (one per controller), and a fan-in to a single composite L2 master:

```
            TCDM/core ports  (i_INPUT 0..num_tcdm_ports-1)
                    |
                    v
        +-----------------------------+
        |     InsituCacheInterco      |   hashed N->M crossbar
        |  out_id = (addr>>off)&mask  |   (addr bits select controller)
        +-----------------------------+
          |        |        |        |
          v        v        v        v
       +------+ +------+ +------+ +------+
       |Ctrl0 | |Ctrl1 | |Ctrl2 | |Ctrl3 |  InsituCacheController x N
       +------+ +------+ +------+ +------+   (tag array, MSHR, hit/miss)
        | | |    | | |    | | |    | | |
   o_WRITE_THROUGH  refill  evict ...
        |                |        |
        v                |        |
     +-------+           |        |
     |Coal 0 | (x N)     |        |   InsituCacheCoalescer x N
     +-------+           |        |   (3-state write-through FSM)
        |                |        |
        +-------+--------+--------+
                |  (coal 'out' + ctrl 'refill' + ctrl 'evict' all fan in)
                v
         single composite 'l2' master  -->  o_L2(itf)
```

Source: tile wiring at `core/models/cache/insitu/insitu_cache_tile.py:85-101`, ports at `:112-135`.

**Controller** (`insitu_cache_controller.cpp`). One `InsituCacheController` serves an address-interleaved subset of lines. State is three parallel arrays sized `[num_sets * num_ways]`: `lines_` (`CacheLine{tag, state, dirty, ready_cycle}`), `line_data_` (a flat functional byte store), plus per-set `lru_order_`, `mshr_` (a `std::deque<MshrEntry>`), `refill_in_flight_`, and `set_busy_until_`. Line states are `INVALID/VALID/READ_PEND/WRITE_PEND` (`controller.cpp:33-39`), mirroring RTL §7.6. The **MSHR is not a dedicated structure** — pending requests are parked in a per-set side-deque of `MshrEntry{req, arrival_cycle}` (`controller.cpp:53-57`); the explicit `arrival_cycle` is kept so latency bookkeeping survives `save()/restore()` (the `IoReq` arg stack is shared with `save()`). `handle_request()` (`controller.cpp:404`) decodes tag/set/is_write, applies write-commit backpressure, does a linear `lookup()` over the set's ways (`controller.cpp:628`), then branches into VALID-hit / pend-merge / miss. `pick_victim()` (`controller.cpp:643`) returns any INVALID way first, else a hash-derived victim `h = (tag*2654435761) ^ (set*0x9E3779B1) % num_ways` when `use_hash_way_select_`, else the LRU `back()`. LRU order is only maintained on hits when `!use_hash_way_select_` (`controller.cpp:491-497`).

**Interco** (`insitu_cache_interco.cpp`). A hashed N-to-M crossbar. The controller-select is `out_id = (num_outputs>1) ? (addr >> dynamic_offset) & output_mask : 0` (`interco.cpp:165-168`); `output_mask_ = num_outputs-1` (`interco.cpp:95`). `forward_initiator_` tags `req->set_initiator(input_id)` so the controller can recognize the scalar-bypass port (`interco.cpp:178-180`). It carries the **wide-access split** path (§2.4) and the two-mode output arbitration (§2.3).

**Coalescer** (`insitu_cache_coalescer.cpp`). A 3-state write-through merger FSM `IDLE/WRITE_COAL/FLUSH` (`coalescer.cpp:26`) with a per-cycle watchdog. The first write moves `IDLE→WRITE_COAL` capturing the line; same-line writes merge (counter only); a different-line write or any read/matching-read-snoop forces a flush; the watchdog (`coalescer.cpp:203`) flushes after `watchdog_cycles_` idle. `flush_line()` emits one wide full-line write downstream (`coalescer.cpp:222-249`). Byte values are not tracked — merge masks are counters only — and writes ack with +1 latency. **In the production write-back config this FSM is dormant** (nothing drives it) and its `read_snoop` port is never bound by the tile.

**Tile** (`insitu_cache_tile.py`). `InsituCacheTile` (`:42-136`) assembles 1 interco + N controllers + N coalescers + a fan-in to a single composite `l2` master. In `__init__` it re-syncs `config.interco.num_inputs/num_outputs` from the tile topology (`:68-69`), so a caller setting only the tile counts gets a consistent interco. Per controller: `interco.o_OUTPUT(i) → ctrl.i_INPUT()`, `ctrl.o_WRITE_THROUGH → coal.i_INPUT()`, and the coalescer `out`, the controller `refill`, and the controller `evict` all fan into the single composite `l2` master (`:93-101`). Ports: `i_INPUT(port)` (range-checked), `o_L2(itf)`, `i_FLUSH(ctrl)`.

**Config layer** (`insitu_cache_config.py`). Three `config_tree.Config` subclasses map 1:1 to the C++ components — `InsituCacheControllerConfig` (`:48-257`), `InsituCacheCoalescerConfig` (`:260-268`), `InsituCacheIntercoConfig` (`:271-328`) — plus a plain `@dataclass` bundle `InsituCacheTileConfig` (`:331-353`, `num_controllers=4`, `num_cores=4`, `tcdm_ports_per_core=5`, with a `num_tcdm_ports` property). Factory functions produce the divergent presets: `make_cachepool_512_config()` (production, `:356-429`), `make_cachepool_512_conventional_config()` (`:432-448`), `make_cachepool_512_calib_config()` (`:451-509`), `make_cachepool_512_legacy_config()` (`:512-526`).

**Calib mem** (`insitu_calib_mem.{cpp,py}`). The GVSoC twin of the RTL `refill_mem_model.sv`: a fixed-latency, **serializing** refill/writeback responder. Occupancy = `mem_latency + (beats-1)*(1+beat_gap)` with `beats = ceil(size/refill_beat_bytes)` (`insitu_calib_mem.cpp:147-149`); serialization is via a single `mem_busy_until_` cyclestamp — a request runs concurrently only if it is a writeback with `writeback_overlap_` or a read with `!serialize_refills_`, else `service_start = max(now, mem_busy_until_)` and `mem_busy_until_ = max(completion, service_start + accept_every_)` (`:158-174`). Python defaults: `mem_latency=50`, `beat_gap=0`, `accept_every=1`, `refill_beat_bytes=16`, `serialize_refills=True`, `max_outstanding=8` (`insitu_calib_mem.py:58-67`).

### 2.3 The timing model

Key knobs (production `cachepool_512` values where they differ from the field default):

| Knob | Default (field / production) | Meaning |
|---|---|---|
| `cache_line_bytes` | 64 | Cache line size; `line_bits_ = log2` (`config.py:52`) |
| `num_ways` | 4 | Associativity per controller (`config.py:55`) |
| `num_sets` | 128 (256 calib) | Sets per controller (`config.py:58`) |
| `refill_beat_bytes` | 16 | Refill beat width; sets beat count (`config.py:64`) |
| `use_hash_way_select` | True | Hash victim (vs LRU); LRU maintained only when False (`config.py:71`) |
| `use_forwarding_buffer` | True | 1-entry fwd-buffer read-forward fast path (`config.py:114`) |
| `write_through_mode` | False | Write-back default; True drives the coalescer (`config.py:81`) |
| `hit_latency_cycles` | 4 / **9** | Isolated read-hit latency; base for derived latencies (`config.py:145`) |
| `streaming_hit_latency_cycles` | -1 (OFF) / 6 calib | Steady-state hit latency once pipeline full (`config.py:149`) |
| `bank_accept_cycles` | 1 | Per-set bank accept interval (pipelined) (`config.py:160`) |
| `scalar_bypass_port` | -1 (4 calib/Spatz) | Input port that bypasses coalescer/bank (`config.py:170`) |
| `scalar_hit_latency_cycles` | -1 (3 calib) | Read-hit latency on the scalar bypass port (`config.py:176`) |
| `write_hit_latency_cycles` | -1 / **7** | Write-hit acceptance→resp latency (`config.py:180`) |
| `write_commit_cycles` | 1 / **2** | Min cycles between accepted write hits (`config.py:186`) |
| `fwd_hit_latency_cycles` | -1 / **6** | Read-hit latency on a fwd-buffer-resident line (`config.py:192`) |
| `miss_penalty_cycles` | 0 / **7** (8 conv) | Fixed cache-pipeline overhead on a refill (`config.py:204`) |
| `refill_bank_write_cycles` | 1 / **2** | Settling cycles after refill before MSHR serves (`config.py:199`) |
| `folded_evict_penalty_cycles` | 0 / **3** | Folded-SRAM full-line eviction read penalty (`config.py:211`) |
| `defer_refills` | False | Enable deferred-completion occupancy serialization (`config.py:228`) |
| `refill_drain_cycles` | 0 | Min cycles between refill/WB completions (only when defer) (`config.py:234`) |
| `retr_fifo_depth` / `miss_fifo_depth` / `evic_fifo_depth` | 16 / 4 / 4 | MSHR / miss / eviction gate depths (`config.py:246-252`) |
| `interco_latency_cycles` | 1 | Fixed forward latency through the interco (`config.py:284`) |
| `dynamic_offset` | 2 | Bit offset of the controller-select bits; granule `1<<offset` (`config.py:280`) |
| `enable_input_coalesce` | False (True calib) | Same-cycle same-line read-hits merge into one lookup (`config.py:287`) |
| `per_cycle_output_arb` | False | Output arbitration mode (accumulate vs per-cycle) — see below (`config.py:314`) |
| `watchdog_cycles` | 4 | Coalescer idle cycles before forced flush (`config.py:266`) |

On a VALID hit, the latency is selected by priority (`controller.cpp:443-469`): write → `write_hit_latency_cycles_`; else scalar bypass (forwarded, no bank contention) → `scalar_hit_latency_cycles_`; else fwd-buffer hit (forwarded) → `fwd_hit_latency_cycles_`; else streaming-hit gradient → `streaming + min(fill_max, gap)`; else flat `hit_latency_cycles_`. The per-set bank is **pipelined, not serialized**: non-forwarded hits pay `queue-wait = max(set_busy_until_[set]-now, 0)` and advance `set_busy_until_` by `bank_accept_cycles_` (default 1), not by the full latency (`controller.cpp:480-484`). Forwarded reads skip bank contention entirely.

Two subtle mechanisms are worth spelling out:

**(a) Per-cycle vs accumulate output arbitration** (`interco.cpp:198-220`). The interco arbitration has two modes. With `per_cycle_output_arb_ = False` (the **default**, used for closed-loop and synthetic phases), the interco uses a *monotonic* `output_busy_until_` cyclestamp that adds `(busy_until - now)` so sustained 1/cyc backpressure carries **across cycles**. This is correct for closed-loop Spatz, where the core stalls on the returned latency. With `per_cycle_output_arb_ = True` (used for *open-loop real-kernel replay*), the accept counter **resets each cycle** (`out_cycle_stamp_`/`out_accepts_in_cycle_`) and the k-th same-cycle accept pays `interco_latency + k/output_accept_width` — there is **no cross-cycle accumulation**. The reason both modes exist: in open-loop replay the trace's `t_issue` *already encodes* the RTL backpressure, so an accumulate stamp double-counts it (≈+33 cy of phantom hit inflation). This is the heart of "fix #5" (§3, §6).

**(b) The `defer_refills` occupancy / install-pipe model.** This is the load-dependent miss serialization, active **only** when `defer_refills_` is True (default False) and `refill_drain_cycles_ > 0`. `reserve_install_pipe(step, floor)` (`controller.cpp:90-96`) is a monotonic cyclestamp: `c = max(refill_drain_busy_until_ + step, floor); refill_drain_busy_until_ = c; return c`. Both the refill-response path *and* the dirty-writeback path consume this **same shared resource**, so refills and writebacks serialize on one near-serial install pipe. In `refill_resp_handler` (`controller.cpp:794-798`) refill completions serialize `refill_drain_cycles_` apart, pushing out a queued miss's completion cycle (and thus `t_resp`) under load — turning a flat plateau into the RTL ramp + install-rate-bound throughput. In `issue_eviction` (`controller.cpp:743-747`) a dirty writeback reserves `step = refill_drain_cycles_ + folded_evict_penalty_cycles_`, which makes a dirty-evict stream run at ~half the read-miss rate. An isolated (head-of-line) miss is unaffected because the cyclestamp is in the past. **When `defer_refills_` is False the miss resolves inline and these counters never accumulate** — the closed-loop Spatz default.

### 2.4 The data path (added for closed-loop)

The functional data path was added so the cache can run closed-loop. It is gated by a derived flag: `carry_data_ = inline_sync_miss_ || functional_writethrough_` (`controller.cpp:263`). **When `carry_data_` is off (every open-loop DUT), the cache moves no bytes and the per-access latency is byte-identical to the calibration.** When on (the Spatz cluster), the full data path is active. Pieces:

- `line_data_` — a flat byte store sized to the line/set/way array. `exchange_line_data()` (`controller.cpp:118-130`) memcpys req↔line at the access offset (clamped, no line straddle) on hits and on refill install.
- `functional_writethrough` — `functional_write_mem()` (`controller.cpp:660-667`) pushes real write bytes straight to backing memory via the **evict** port for backdoor coherence (so the ISS/HTIF syscall reader sees them). This is distinct from `issue_write_through` (the `wt_itf_` path), which is separately gated by `write_through_mode_` (default False).
- `inline_sync_miss` inline-completion (`controller.cpp:574-607`) — on a miss, `issue_refill`; if it returns `IO_REQ_OK` synchronously, complete **inline**: set VALID, `ready_cycle = now + refill_lat`, install line data, exchange/functional-write, `inc_latency`, return OK. It never re-entrantly calls `resp()` (a real core LSU faults on that). The async fallback parks on the MSHR. The default-off path (`controller.cpp:613-623`) parks first then issues the refill, draining synchronously via `refill_resp_handler`.
- `carry_data_` gating — gates *all* data movement (`exchange_line_data`, `functional_write_mem`, line install on refill, and the refill-resp address source at `controller.cpp:763`).
- `pending_refill_addr_` (`controller.cpp:222`, set in `issue_refill` at `:701`) — stashes the pre-routing refill line address so `refill_resp_handler` can re-decode set/tag even after a downstream router rewrites `req->get_addr()` in place. This fixed a real closed-loop deadlock (§5).
- **Wide-access split** (`interco.cpp:134-163`) — gated on `num_outputs_ > 1`. When `(addr & (gran-1)) + size > gran` with `gran = 1<<dynamic_offset`, an access crosses the interleave granule and spans multiple controllers; the interco splits it into per-owning-controller byte chunks (via `split_subreq_`), each forwarded to its owning output; the user req gets the MAX of the sub-latencies and returns OK. With `num_outputs==1` (the calib DUT) this whole path is skipped, so calib stays byte-identical.
- **Flush infrastructure** — `flush_all()`/`flush_req_handler()` and the `i_FLUSH` port (`controller.cpp:382-402`) invalidate every valid line + clear the fwd buffer + reset `set_busy_until_`, modelling a software `cache_sync` flush+invalidate (it is a *simplified* invalidate-all, not the full RTL set-walk dirty-writeback FSM). It is wired whenever the flush port is bound, which the tile only does when `n_ctrl > 1` (`insitu_cache_tile.py:107-108`).

**What is gated to the cluster vs always active.** Always active (any config): the timing model, the interco, the coalescer FSM, the flush mechanism (when bound). Gated to the closed-loop cluster (via `carry_data_`): all functional byte movement, inline miss completion, functional write-through, and the wide-access split (gated separately on `num_outputs>1`, which is true for the cluster's 4-controller tile but false for the 1-controller calib DUT). The two source flags `inline_sync_miss` and `functional_writethrough` both default **False** in the field (`config.py:88, 98`) and are explicitly left at default in the base factory `make_cachepool_512_config()` with an explanatory comment (`config.py:385-392`); they are flipped True **only** at the Spatz cluster site (`snitch_cluster.py:300-301`).

---

## 3. Calibration status (open-loop)

The `insitu_cache_calib` target is a CPU-less GVSoC twin of the RTL standalone cache-calibration testbench (`ManyRVData_rebase/reports/cache_calib/`). Topology (`pulp/insitu_cache_calib/__init__.py:21-26,195-198`): a trace-replay driver drives 5 TCDM ports of a single-controller `InsituCacheTile`, whose L2 refill port is answered by `InsituCalibMem`. The point of the harness is that **GVSoC and RTL run the SAME `port,rw,addr,size,delay` trace through the SAME memory-timing knobs and are diffed on the per-access `latency` column**.

The driver (`calib_driver.cpp`) parses the trace and enforces the RTL injection semantics: within a port, accesses run in file order and access k+1 is offered only after k is accepted plus its own `delay` idle cycles (`eligible_cycle = (last_accept_cycle+1) + delay`, `calib_driver.cpp:255`); across ports, ports are independent/concurrent. The handshake mapping is `IO_REQ_OK` = synchronous hit (latency on the req), `IO_REQ_PENDING` = accepted now / response later, `IO_REQ_DENIED` = backpressure / retry next cycle (`:275-282`). A per-port outstanding budget (default **32** = RTL `NumSpatzOutstandingLoads`) is held from issue until the response cycle and freed **deferred** in `fsm_handler` (`:333-341`), which is what makes the 32-budget genuinely bind. Output is a per-access CSV plus an aggregate CSV plus a `[CALIB_REPORT]` stderr line.

**Env-var selection.** `INSITU_CALIB_TRACE`/`_TRACE_FILE` pick the trace; `INSITU_CALIB_OUTDIR` the output dir; `INSITU_CALIB_MEMLAT` (default 50), `INSITU_CALIB_BEATGAP`, `INSITU_CALIB_ACCEPTEVERY` set the memory model (`__init__.py:126-128`). `INSITU_CALIB_WIDE_REFILL=1` switches to the wide single-beat experiment (beat = full line, `serialize_refills=False`, mem `max_outstanding` 8→64, `miss_penalty` 7→9 i.e. cold miss +17→+13, and turns on `defer_refills`+`refill_drain_cycles=3`) (`__init__.py:132-184`). `INSITU_CALIB_PER_CYCLE_ARB=1` flips the interco to per-cycle arbitration for real-kernel replay (`__init__.py:153-157`). All of these default **off**, so the synthetic calib numbers are untouched. The calib config itself (`make_cachepool_512_calib_config`) collapses the tile to 1 controller / 5 ports / 4-way × 256-set × 64B = 64 KiB (RTL `NumCacheEntry=1024`), enables `enable_input_coalesce`, sets `coalesce_max_latency = hit+7 = 16`, `streaming_hit_latency_cycles = hit-3 = 6`, `scalar_bypass_port=4`, `scalar_hit_latency_cycles=3`, and leaves `per_cycle_output_arb` at default False.

**RTL reference vs GVSoC** (config 512; `prompt/insitu_cache_calib_report.md` §3, §9.1, §10–§14):

| Metric | RTL reference | GVSoC | Notes |
|---|---|---|---|
| Warm read-hit, isolated | 10 cyc | **10 cyc** | `interco(1)+hit_latency(9)`; MemLatency-independent |
| Warm read-hit, streaming | 7 cyc | **7 cyc** | `streaming_hit_latency=6` → `interco(1)+6` |
| bw_hit gap gradient (gap 0/1/2/3/7) | 7/8/–/10/10 | 7/8/9/10/10 | gap2=9 is an unvalidated interpolation |
| Cold read-miss, isolated (serialized BL4) | MemLatency+17 | **27/67/117/217** @ ML 10/50/100/200 | exact across sweep |
| Cold read-miss, isolated (wide BL1) | MemLatency+13 | **23/63/113/213** | exact across sweep |
| Cold-miss-stream throughput @ML50 (BL4) | 0.0181 acc/cyc | 0.0188 | within 4% |
| `coal_cold_4port` wide throughput @ML50 | 0.467 (RTL ref) | **0.4961** (≈ 0.494–0.496 across run) | +6.2% vs RTL; `mem_rd=32` preserved |
| `coal_cold` wide throughput, ML 10/50/100/200 | 0.618/0.467/0.431/0.322 | 0.585/0.494/0.414/0.313 | ≤6.2% across sweep |
| `cold_stream` wide throughput, ML 10/50/100/200 | 0.243/0.243/0.183/0.118 | 0.302/0.254/0.201/0.123 | ≤10% for ML≥50; +24% @ML10 |
| `evict_dirty_fill` throughput @ML50 | 0.177/0.178 | 0.166 | within 6–7% (was 2.8× over before occupancy model) |
| Single-port hit ceiling | ~0.86 acc/cyc | 0.877 (0.909 gap0) | within ~2%; ~5.7% saturation over-predict residual |
| `coal_warm_4port` throughput @ML50 | 3.282 | 3.37 | +2.6% (was 0.06 before par-coalescer approximation) |
| Warm write latency / stream throughput | 8 / 0.489 | 8 / 0.478 | `write_hit_latency=7`, `write_commit=2` |
| RAW same-word read latency | 7 | 7 | 1-entry forwarding buffer (`fwd_hit_latency=6`) |
| Memory traffic (`coal_cold` mem_rd) | 32 | 32 | MSHR-merge collapses 128 same-line → 32 refills |

**The fix #5 real-kernel alignment results.** Replaying 5 real CachePool kernel traces through the calib model with the per-cycle arbitration fix (`prompt/insitu_cache_realkernel_alignment_2026-06-12.md`) collapsed the per-access mean-Δ-vs-RTL:

| Kernel | mean Δ before | mean Δ after | hit Δ after |
|---|---|---|---|
| fmatmul M32 | 26.5 | **3.9** | 3.3 |
| fft M1024 | 34.6 | **3.2** | — |
| fmatmul M128 | 62.7 | **6.4** | — |
| gemv M512 | 76.1 | **2.6** | — |
| fdotp M8192 | 75.0 | **21.1** | +0.3 |

The hit-Δ collapsed to **+0.3..+4.5 cy on every kernel**. `gemv→+2.6` overturned an earlier "inherent cascade" attribution (it was a model defect). `fdotp`'s remaining +21.1 is **entirely miss-path** (+62.7, unchanged) — the genuine open-loop memory-latency cascade, not a cache-path artifact.

**Calibrated vs remaining gaps.** Calibrated: warm hit (10/7), cold miss (ML+17 / ML+13 wide), miss serialization, single-port hit ceiling, write latency/throughput, RAW forward, `coal_warm`, and all memory-traffic structure — within ~7% at ML50, confirmed unchanged after the 2026-06-08 upstream pull (report §14). Remaining gaps (documented, several proven non-convergent): `coal_cold` per-resource `max_outstanding` (128 vs RTL ~56) and per-access latency (ML+96.5 vs RTL ML+28 ~82) — a coupled, proven-NO-GO RTL-specific shape metric (report §13), where throughput already matches; `evict` outstanding 32 vs RTL 4 and write-allocate latency inflation; `cold_stream` +24% @ML10 (a single fixed drain rate can't reproduce the flat hard install-pipe cap below ML50); saturation single-port ceiling slightly over (~0.91 vs 0.865).

---

## 4. Tile-level integration

`InsituCacheTile` (`insitu_cache_tile.py:42-136`) is the composite that real integration sites instantiate. It builds 1 `InsituCacheInterco` + N `InsituCacheController` + N `InsituCacheCoalescer` (one coalescer per controller) and fans the controller `refill`, controller `evict`, and coalescer `out` ports into a single composite `l2` master (`:93-101`). It re-syncs `config.interco.num_inputs/num_outputs` from the tile topology in `__init__` (`:68-69`). Public ports: `i_INPUT(port)` (range-checked 0..num_tcdm_ports-1, `:112-118`), `o_L2(itf)` (`:128-135`), `i_FLUSH(ctrl)` (`:124-126`), and `num_flush_ports()` (`:120-122`).

The **standalone testbench** `pulp/insitu_cache_tb.py` brings up a minimal SoC for focused microbenchmarks without the full Spatz cluster: one RV32 timed host (`isa='rv32imafdc'`, `:73`) → a single `InsituCacheTile` → one backing memory `l2` (latency=20, `:61`). It clones `make_cachepool_512_config()` and shrinks it to a single port (`num_cores=1`, `tcdm_ports_per_core=1`, `interco.num_inputs=1`, `interco.num_outputs=num_controllers` — still 4 controllers, `:63-68`). A `router.Router` maps the cached region `0x1000_0000` (256 KB) to `cache_tile.i_INPUT(0)` with `rm_base=False` and binds `cache_tile.o_L2(l2.i_INPUT())` (`:78-82`). It does **not** set the closed-loop driver flags — it relies on the cache's default open-loop behaviour with an RV32 host that drives the cache directly. Build via `make all TARGETS=insitu_cache_tb`.

**Flush ports are dormant and gated `n_ctrl > 1`.** The per-controller `flush_<i>` composite slave is bound only when there is more than one controller (`insitu_cache_tile.py:107-108`), so the single-controller open-loop calib DUT has no flush driver (binding an externally-undriven port is skipped). Even on a multi-controller tile, the flush surface is **not wired to a cluster L1D peripheral** today — it is implemented cache-side but dormant, kept for future cache-aware DMA-staging kernels.

---

## 5. Cluster-level integration (Spatz)

The InSitu cache is an **opt-in insert** between the cores and the cluster TCDM. The default datapath is unchanged: with `use_insitu_cache=False` (the default) the cluster wires cores directly to TCDM and there is no behaviour or performance change.

**Full enable path (end-to-end).** The user runs `gvsoc --target=spatz --target-property use_insitu_cache=True --binary <elf> run`. The `spatz` target (`pulp/spatz.py:19-28`) builds `SpatzBoard = SnitchBoard(spatz=True)` (`snitch.py:497-500`), which constructs `SnitchArch(spatz=True)` (`:480`) → `SnitchArchProperties(spatz=spatz)` (`:92-93`). `SnitchArchProperties.__init__` sets `use_insitu_cache=False` as the default (`:52`) and `declare_target_properties` exposes it as a user property `use_insitu_cache` with `cast=bool` (`:82-85`) — that is the property the `--target-property` flag flips. The `Soc` arch constructs each cluster's `ClusterArch(..., use_insitu_cache=getattr(properties,'use_insitu_cache',False))` (`:132-134`); `ClusterArch.__init__` stores `self.use_insitu_cache`/`self.insitu_cache_cfg` (`snitch_cluster.py:75-76`); and `SnitchCluster`'s `if arch.use_insitu_cache:` block (`snitch_cluster.py:285`) instantiates the `InsituCacheTile` and re-wires the ports.

**Where the cache sits.** Each core has a per-core router `cores_ico[core_id]` (`snitch_cluster.py:235`). The scalar data port always feeds that router (`cores[core_id].o_DATA(cores_ico[core_id].i_INPUT())`, `:306`). With the cache enabled the router's TCDM-range map points at the cache: `cores_ico[core_id].o_MAP(insitu_cache.i_INPUT(tcdm_port), base=arch.tcdm.area.base, size=arch.tcdm.area.size, rm_base=False)` (`:311-312`) — `rm_base=False` preserves absolute TCDM addresses into the cache. Each Spatz vector LSU port is likewise routed in: `cores[core_id].o_VLSU(port, insitu_cache.i_INPUT(tcdm_port))` (`:320-321`). The `tcdm_port` counter advances 1 (scalar) + `spatz_nb_lanes` (VLSU) per core (`:304-324`). On the disabled path these same ports bind directly to `tcdm.i_INPUT(...)` with `rm_base=True` (`:314-315, 323`).

**The L2 refill path.** The cache's miss side fans into the cluster's wide AXI: `insitu_cache.o_L2(wide_axi.i_INPUT())` (`:337-338`). The pre-existing `wide_axi.o_MAP(tcdm.i_DMA_INPUT(), base=..., size=..., rm_base=True)` (`:268`) already routes TCDM-range addresses to the SPM's DMA input — so cache refills/evictions for TCDM addresses land back in the SPM by default. Pointing refills at DDR instead is a matter of changing the `wide_axi` map at SoC level.

**The driver-flag design and why.** Because this is a closed-loop run (real cores, not a trace driver), the cluster site forces two flags on the controller config (`snitch_cluster.py:300-301`): `cache_cfg.controller.inline_sync_miss = True` and `cache_cfg.controller.functional_writethrough = True`. The comment at `:294-299` explains why: the real core LSU is the **snitch v1 ISS with NB_OUTSTANDING off**, which only accepts a synchronous `IO_REQ_OK` — so a miss must complete **inline** rather than parking on the MSHR and re-entrantly calling `resp()` (which would deadlock/abort the core); and write-back dirty data must actually reach backing memory so the ISS/HTIF backdoor reader sees it (`functional_writethrough`), else the program hangs in a bogus syscall. These are *data-path/protocol* flags, not cache geometry — which is exactly why the base factory `make_cachepool_512_config()` leaves both at field-default False (`config.py:385-392`), so open-loop calib/microbench numbers are untouched, and only the closed-loop cluster turns them on. Both are genuinely consumed C++-side: read via `get_child_bool` (`controller.cpp:259-260`), combined into `carry_data_` (`:263`), and gated at `:419` (inline completion), `:574`, and `:662-667` (functional write-through push).

**Topology actually built (spatz).** `SnitchArchProperties(spatz=True)` sets `nb_core_per_cluster=2` and `spatz_nb_lanes=4` (`snitch.py:41,47`). At the cache site (`snitch_cluster.py:290-293`) the config is overwritten to match: `num_cores = arch.nb_core` (=2), `tcdm_ports_per_core = 1 + spatz_nb_lanes` (=5), `interco.num_inputs = 2×5 = 10`, `interco.num_outputs = num_controllers`. `num_controllers` is **not** overwritten, so it stays at the `make_cachepool_512_config()` default of **4** (`config.py:426-428`). So the Spatz cluster builds a tile with num_cores=2, 5 ports/core, 10 interco inputs, 4 controllers, 4 coalescers, 4-way × 128-set × 64B lines.

**The closed-loop bring-up story.** Previously `--target=spatz --target-property use_insitu_cache=True` hung at boot. The hang was a **4-bug cascade**, all fixed and gated to the cluster config:

1. **No data modelling** — the cache was a pure timing overlay, so every load returned garbage and the program derailed into a bogus HTIF syscall. Fixed by adding `line_data_` + `exchange_line_data()`, gated behind `carry_data_`.
2. **Write-back invisible to the HTIF backdoor** — fixed by `functional_writethrough`, which pushes every write's real bytes to backing memory via the evict port.
3. **Refill-address rewrite deadlock** — `wide_axi` rewrites the refill req addr in place (subtract `remove_offset`), so the resp handler re-decoded set/tag from the *mutated* addr and never matched the pending line → the MSHR never drained. Fixed by stashing `pending_refill_addr_`.
4. **LSU synchronous-slave protocol** — the v1 ISS LSU accepts only synchronous `IO_REQ_OK` (PENDING/DENIED are fatal), so `inline_sync_miss` makes synchronously-resolved misses complete inline and turns write-commit backpressure into *added latency* instead of *denial*.

On top of the cascade, the actual **data bug** (not DMA/flush) was **wide-access spanning**: the interco interleaves controllers at 4-byte granularity (`dynamic_offset=2`, bits[3:2] within the line), so an 8-byte memcpy store routed wholesale to ctrl0 left ctrl1's upper-word copy stale. The fix: the interco now **splits** an access crossing the granule and routes each byte-range to its owning controller, gated `num_outputs_>1` (so calib with `num_outputs=1` stays byte-identical).

**Current status:** `examples/spatz/test-riscvTests-vfadd` with `use_insitu_cache=True` **PASSES all 15 test cases (retval=0, cycles=58001)**.

**Forward-compatible with a future async-capable Spatz model.** `inline_sync_miss` is a workaround for the *current* Spatz model's synchronous-slave LSU (v1 ISS, NB_OUTSTANDING off), which only accepts a synchronous `IO_REQ_OK`. There is an ongoing newer Spatz model expected to support a proper outstanding/grant handshake (accept `IO_REQ_PENDING` and a later `resp()`). **The integration is designed to drop that in with a one-line change** and *no cache rework*, because:

- `inline_sync_miss` is a **gated config flag set only at the cluster site** (`snitch_cluster.py:300-301`), not hardwired in the cache. Swapping in an async-capable core means setting `inline_sync_miss=False` there (or making it track a core-model capability flag).
- With `inline_sync_miss=False` the cache falls back to its **general park + MSHR + deferred-`resp()` path** — the *same* path the open-loop calib harness exercises — which is verified to carry data correctly when `carry_data_` is on: `refill_resp_handler` installs the fetched line (`controller.cpp:803`) and `fsm_drain_mshr` does the deferred read/write `exchange_line_data` before `resp()` (`controller.cpp:857-869`). That path *also* honours the `defer_refills` occupancy model, so it is arguably the more faithful timing path once the core can tolerate it.
- `functional_writethrough` is **orthogonal** to the sync/async question (it is about write-back data reaching memory for the HTIF backdoor reader) and would stay on as long as the cache is write-back.

**Caveat:** the async closed-loop path is exercised today only by the open-loop calib driver (which tolerates deferred/re-entrant `resp`), **not** end-to-end behind a real async core — so it should be re-validated when the new Spatz model lands. No structural blocker is known.

---

## 6. Recent work timeline

Three chronological phases, all part of making the model a faithful per-access predictor and then making it run closed-loop on Spatz.

**Phase 1 — fix #5: per-cycle output arbitration (open-loop hit-latency lever).** The real-kernel alignment study replayed 5 CachePool kernel traces and found GVSoC over-predicted per-access latency by ~+60..+85 cy mean on every kernel despite making the same refills — right contents, wrong timing. A latency-component discriminator pinned the dominant residual on the interco **output arbitration**, not the per-set bank (removing the bank wait moved fft 0.1 cy; removing the output wait collapsed it +36.7→+3.9). Root cause: `output_busy_until_` was a monotonic accumulate stamp (correct for closed-loop where the core stalls, wrong for open-loop replay where `t_issue` already encodes RTL backpressure → ~+33 cy phantom inflation). The fix added the second `per_cycle_output_arb` mode, opt-in via `INSITU_CALIB_PER_CYCLE_ARB=1`. Results in §3. No regression (accumulate else-branch byte-identical). Committed:
- core **`6362b3da`** "insitu-cache: per-cycle output arbitration (open-loop replay hit-latency fix)"
- pulp **`f0706bc`** "insitu_cache_calib: INSITU_CALIB_PER_CYCLE_ARB env knob (real-kernel replay)"
- parent pointer bump **`18298b8`** (local only)

(Earlier supporting fixes: core `37982db9` pipelined-bank, core `49c377d9` scalar bypass + same-cycle MSHR-drain coalescing.)

**Phase 2 — closed-loop Spatz bring-up.** Fixed the 4-bug hang cascade + the wide-access split (all detailed in §5): `line_data_`/`exchange_line_data()` behind `carry_data_`, `functional_writethrough` evict push, `pending_refill_addr_` stash, `inline_sync_miss` inline-completion, and the interco wide-access split gated `num_outputs_>1`. Result: `vfadd` all 15 TCs PASS, cycles=58001. The flush/invalidate path is implemented cache-side but dormant.

**Phase 3 — open-loop regression + Option-B fix (the commit blocker).** The uncommitted Phase-2 work deterministically regressed calib (`fmatmul M32` +3.9→+7.5, `coal_cold` 0.4961→0.6531). Root cause: the shared base factory `make_cachepool_512_config()` had been set with `inline_sync_miss=True`/`functional_writethrough=True`, and the calib config derives from it, inheriting the flags; with `inline_sync_miss=True` the calib miss path took the inline-completion branch that never calls `reserve_install_pipe`, bypassing the `defer_refills` occupancy serialization → inflated miss throughput/latency. (The bisect was initially blind because quick `.so`-only rebuilds never refresh the installed `.py` under `install/generators/`, so runs saw stale True flags — a clean full build is required to validate config-flag changes.) The **Option-B** fix treats the two as driver/integration flags: removed from the base factory (left at field default False so calib/conventional/legacy inherit the calibrated path), set explicitly at the closed-loop cluster site. Verified on a clean full build: open-loop `fmatmul M32` mean Δ 3.9 / `coal_cold` wide @ML50 0.4961 (exactly the fix #5 targets), and closed-loop `vfadd` all 15 TCs PASS. **A step-by-step walkthrough of this regression — the inherited flag, the two distinct miss code-paths, and why Option-B was chosen over Option-A — is in §9.1.** Phase 2 + Phase 3 shipped together:
- core **`3d712809`** "insitu-cache: closed-loop Spatz data path + open-loop regression fix"
- pulp **`d8abb08`** "snitch_cluster: set closed-loop cache driver flags at the cluster site"
- parent pointer bump **`b2eb076`** (local only)

**Push status (verified via `branch -r --contains`).** All four submodule commits are on **`origin/insitu-cache`** (PUSHED): core `6362b3da` + `3d712809`, pulp `f0706bc` + `d8abb08`. The parent `main` is **19 commits ahead of `origin/main`** (LOCAL only, NOT pushed); the relevant pointer-bump commits are `b2eb076` and `18298b8`, per the submodules-only-push preference.

---

## 7. Known gaps & next steps

**Phase-B / unmodelled (structural) items** — the model still implements the v1 topology; these are documented in `prompt/insitu_cache_rtl_coverage_matrix.md` (12 MODELED / 15 APPROXIMATED / 10 GATED-PARTIAL / 15 ABSENT of 52 features) and `prompt/insitu_cache_architecture_v2.md:408-434`:

- **Topology refactor (largest open item):** the integrated RTL is a **Group(4 tiles) → Tile(4 Spatz CC + 4 per-core L1 cache controllers) → CC** hierarchy — one cache controller *per core* (`NumL1CacheCtrl = NumCores`, `cachepool_pkg.sv:121`), 16 cores / 16 caches per group — and **each** per-core controller is internally a single wide-line cache fronted by its own N→1 `par_coalescer` + 2:1 scalar `bypass_xbar` (the v1 "4 sub-controllers + interco" was collapsed *inside* one controller). The GVSoC model instead builds `num_controllers=4` with a hashed N→M address-interleave interco for `num_cores=2`, with no per-core mapping, no par_coalescer/bypass structure, and no Tile/Group/remote-xbar hierarchy (`config.py:340, 368-372`). Phase B = one wide-line cache per core, a structural par-coalescer (hitmap/offset wide-merge + per-port response split), a scalar bypass_xbar mode, and a Tile/Group composite with a remote-access crossbar. Today the par-coalescer **input merge** is only approximated by the interco's `enable_input_coalesce` latency-window trick, not a real wide-request merge. **Expanded — the corrected RTL hierarchy vs the model, and exactly what the `enable_input_coalesce` approximation does — in §9.2.**
- **Per-resource outstanding caps:** the coal_cold / evict per-resource `max_outstanding` distributions (128 vs RTL ~56; 32 vs RTL 4) are RTL-specific shape metrics, proven non-convergent without a Phase-B controller same-line MSHR-collapse + concurrent-install cap; throughput already matches, so this is a tracked follow-up, not implemented (regression risk to the exactly-matched cold_stream/evict).
- **Cache partitioning / SPM (entirely unmodeled beyond a capacity fold).** The integrated RTL is a *fully-shared* L1 whose bank address-mapping is **programmable in the xbar registers**, so software can (a) re-point xbars to make some banks **tile-private** (partition the shared pool) and (b) carve cache capacity into **SPM** via the `_partitionable_flushable` wrapper. The GVSoC model supports **neither**: the interco routing is *static at elaboration* (no register-reconfigurable mapping, `insitu_cache_interco.cpp` has no reg/remap path), and there is no shared-L1 / remote-xbar substrate for a partition to operate on. The only partition-adjacent knob is `enable_spm`/`bank_depth_for_spm`, which is a crude **capacity-shrink fold** — `effective_num_sets_ = num_sets_ − bank_depth_for_spm_` (`insitu_cache_controller.cpp:103-108,298-299`), i.e. it pretends the cache is smaller — *not* a real partition with a separate SPM access path, and *not* a shared-vs-private bank remap. This is downstream of the topology refactor: the model needs the shared-L1 substrate first before reconfigurable partitioning is even expressible.
- **Dormant flush-to-L1D-peripheral wiring:** `flush_all()`/`i_FLUSH` is a simplified invalidate-all (not the full RTL `cache_sync` 4-op set-walk dirty-writeback FSM + sync↔install drain interlock); it is implemented cache-side but **not wired to a cluster L1D peripheral**, and the tile only binds the flush ports when `n_ctrl > 1`.
- **Dormant write-through coalescer:** the 3-state coalescer is fully modeled but never driven in the production write-back config, and its `read_snoop` port is never bound by the tile.

**Topology-mismatch caveat for closed-loop cycle comparison.** The `vfadd cycles=58001` figure is **not yet diffable against an RTL reference**. The GVSoC Spatz cluster built here is a single flat tile of 2 cores behind 4 address-interleaved controllers; the integrated RTL the replay traces come from is **16 cores = 4 tiles × 4 cores, one cache per core, with a cross-tile remote-access crossbar** (see §9.2). So the gap is not just a core-count scale factor — it is structural (per-core caches + coalescer/bypass + remote xbar vs hashed-interleave controllers). Closed-loop cycle validation against RTL needs that topology reconciliation (open follow-up in `WORKLOG.md`). Separately, `fdotp`'s +62.7 miss-path residual is the genuine open-loop memory-latency cascade — not closable by a cache-model fix; it would need a closed-loop injection model.

(Note: the coverage matrix is dated 2026-06-08 while the controller/config were edited 2026-06-15, so two of its ABSENT entries — the simplified flush_all() and the scalar-bypass latency path — are now partially addressed in the tree and the matrix should be refreshed.)

---

## 8. Where things live

**Model files** (`core/models/cache/insitu/`):

| File | Role |
|---|---|
| `insitu_cache_controller.{cpp,py}` | One v1 controller: tag array, MSHR side-deque, hit/miss/merge, hash/LRU victim, refill/evict, write-through hook, occupancy install-pipe, data path |
| `insitu_cache_interco.{cpp,py}` | Hashed N→M crossbar, wide-access split, two-mode output arbitration, input coalesce |
| `insitu_cache_coalescer.{cpp,py}` | 3-state write-through merger FSM + watchdog (dormant in production) |
| `insitu_cache_tile.py` | Composite: 1 interco + N controllers + N coalescers + L2 fan-in; `i_INPUT`/`o_L2`/`i_FLUSH` |
| `insitu_cache_config.py` | Config single-source-of-truth + factory presets (`make_cachepool_512_config` @ `:356`, `_calib_` @ `:451`, `_conventional_` @ `:432`, `_legacy_` @ `:512`) |
| `insitu_calib_mem.{cpp,py}` | Fixed-latency serializing refill responder (RTL `refill_mem_model.sv` twin) |
| `README.md` | Full user-facing model documentation |

**Calib harness** (`pulp/insitu_cache_calib/`): `calib_driver.{cpp,py}` (trace-replay driver + monitor), `__init__.py` (target wiring + all env-var gating), `gen_traces.py` (trace generator), `traces/` (incl. `sample.trace` + `sample_trace_out.rtl.csv` for diffing).

**Integration sites:** `pulp/pulp/snitch/snitch_cluster/snitch_cluster.py` (the `if arch.use_insitu_cache:` block at `:285`, topology overwrite `:290-293`, driver flags `:300-301`, port wiring `:304-324`, L2 fan-in `:337-338`); `pulp/pulp/chips/snitch/snitch.py` (`use_insitu_cache` property `:82-85`, spatz defaults `:41,47`); `pulp/spatz.py` (the `spatz` target); `pulp/insitu_cache_tb.py` (standalone testbench).

**Key docs** (`prompt/`): `insitu_cache_architecture_v2.md` (current RTL spec — read first), `insitu_cache_architecture.md` (legacy v1 RTL), `insitu_cache_rtl_coverage_matrix.md` (RTL-vs-model gap map, dated 2026-06-08), `insitu_cache_calib_report.md` (calibration methodology + results + NO-GO proofs), `insitu_cache_realkernel_alignment_2026-06-12.md` (fix #5 study), `insitu_cache_gvsoc_plan.md` (7-phase plan), `WORKLOG.md` (running dev log).

**Current commits / branches:**

| Repo | Branch | Commits (this arc) | Pushed? |
|---|---|---|---|
| `core` (gvsoc-core) | `insitu-cache` | `6362b3da` (fix #5), `3d712809` (closed-loop + regression fix) | **Yes** → `origin/insitu-cache` |
| `pulp` (gvsoc-pulp) | `insitu-cache` | `f0706bc` (calib env knob), `d8abb08` (cluster driver flags) | **Yes** → `origin/insitu-cache` |
| parent (SDK) | `main` | `18298b8` (fix #5 pointer bump), `b2eb076` (closed-loop pointer bump) | **No** — 19 ahead of `origin/main`, local only |

---

## 9. Deep dives — two claims explained

This section unpacks two passages elsewhere in the report that are dense on first read: the open-loop regression (§6 Phase 3) and the topology-refactor gap (§7).

### 9.1 The open-loop regression and the "Option-B" fix

**The setup — two harnesses.** The cache runs in two completely different environments:

- **Open-loop** — no CPU. A trace replayer feeds the cache `addr,rw,size,delay` records and a fake fixed-latency memory answers refills. This is the mode the model was *calibrated* against the RTL, so its cycle numbers (`fmatmul` mean Δ 3.9, `coal_cold` 0.4961) are the gold targets.
- **Closed-loop** — the cache sits inside a real Spatz cluster behind real cores running a real binary.

**The two flags.** Closed-loop needs two flags that open-loop does not:

- `functional_writethrough` — actually move real bytes to memory, so loads return real data instead of garbage.
- `inline_sync_miss` — complete a miss *inline* (return `IO_REQ_OK` in the same call) instead of parking it and responding later, because the Spatz core's LSU (snitch v1 ISS, NB_OUTSTANDING off) only accepts a synchronous OK and faults on a deferred/re-entrant response.

**The mistake.** Those two flags were set inside `make_cachepool_512_config()` — the *shared base config factory*. But the calibration config is built by calling that factory and then tweaking geometry:

```python
def make_cachepool_512_calib_config():
    cfg = make_cachepool_512_config()   # <-- inherits inline_sync_miss=True !
    cfg.num_controllers = 1
    ...
```

So the open-loop calibration DUT silently inherited `inline_sync_miss=True`.

**Why that broke the numbers.** The two miss paths are genuinely different code (`insitu_cache_controller.cpp:574-624`):

| Path | What it does |
|---|---|
| **Calibrated (park) path** — `inline_sync_miss=False` | `req->save()` → park on the MSHR → on refill, `refill_resp_handler` runs and calls **`reserve_install_pipe()`** — the throttle that serializes refill completions `refill_drain_cycles` (=3) apart. *This is the `defer_refills` occupancy model that was calibrated to match RTL miss throughput (§2.3b).* |
| **Inline path** — `inline_sync_miss=True` | `req->inc_latency(refill_lat); return IO_REQ_OK;` — completes immediately; **never parks, never calls `refill_resp_handler`, never calls `reserve_install_pipe`**. |

With the flag inherited, calib misses took the inline branch and **skipped the calibrated occupancy throttle entirely**. With the throttle gone, miss throughput shot up (`coal_cold` 0.4961→0.6531) and the real-kernel per-access latencies drifted off their RTL-matched values (`fmatmul` mean Δ 3.9→7.5). Nothing was structurally "broken" — the calib run was just quietly using the closed-loop miss path.

**Why "Option-B".** There were two ways to fix it:

- **Option A:** keep the flags in the base factory, but override them back to `False` in every open-loop config that derives from it (calib, conventional, legacy).
- **Option B (chosen):** recognize that these flags describe *how the cache is driven* (the integration environment), not the cache hardware geometry — so they do not belong in a shared geometry factory at all. Remove them from the base factory (they default `False`), and set them `True` only at the one site that needs them: the Spatz cluster instantiation (`snitch_cluster.py:300-301`).

Option B is cleaner because no future config derived from the factory can ever re-inherit them by accident.

**Why "a clean full build restores both".** Two reasons: (1) the bug was masked during bisecting because GVSoC loads model `.py` from `install/generators/`, not from source — quick `.so`-only rebuilds never refresh it, so only a *full* build+install actually exercises a config-flag change (an important gotcha for anyone validating config edits); (2) "both" means the open-loop targets (3.9 / 0.4961) **and** the closed-loop `vfadd` pass (cycles=58001) — the fix had to preserve both at once.

### 9.2 The topology refactor (model vs current RTL)

This is a **structural** gap: the model reproduces RTL *timing* via calibration, but its internal *shape* does not match the RTL system. **(Correction, 2026-06-15: an earlier draft of this report described the RTL as "one wide cache per cluster, not four." That was wrong — it confused two different "fours." The accurate hierarchy, read directly from the RTL, is below.)**

**The RTL has two setups.** ⑴ A **standalone calibration testbench** (`hardware/tb/cache_calib/tb_cachepool_cache_ctrl_perf.sv`) that exercises **one** `cachepool_cache_ctrl` (one core's worth of cache) against a fixed-latency refill responder — this is exactly what the open-loop `insitu_cache_calib` GVSoC target mirrors 1:1. ⑵ The **integrated system**, a Group → Tile → CC hierarchy.

**The integrated RTL hierarchy** (grounded in `config/cachepool_128.mk`: `num_tiles=4`, `num_cores=16`, `num_cores_per_tile=4`; and `cachepool_pkg.sv`):

- **Group = 4 tiles** (`NumTiles=4`).
- **Tile = 4 Spatz CC + 4 L1 cache controllers** — one cache controller **per core**: `NumL1CacheCtrl = NumCores` (`cachepool_pkg.sv:121`) and `NumL1CtrlTile = NumL1CacheCtrl / NumTiles` (`:122`) = 4. The tile instantiates them in a `gen_l1_cache_ctrl` loop over `NumL1CtrlTile` (`cachepool_tile.sv:938`). So a group has **16 cores and 16 cache controllers** (4 per tile × 4 tiles) — which is the "16-core CachePool" the replay traces come from.
- **CC** has `NrTCDMPortsPerCore = 5` ports (1 Snitch scalar + 4 Spatz-VLSU lanes, `cachepool_pkg.sv:64`). Each core's 5 ports feed **its own** cache controller through a per-core **`par_coalescer`** (merges same-cycle/same-line accesses into one wide cache access — hitmap + per-port offsets, then splits the wide response back out) plus a 2:1 scalar **`bypass_xbar`**.
- Each per-core cache controller **is itself a single wide-line cache**, internally banked (`NumDataBankPerCtrl` data banks, `NumTagBankPerCtrl` tag banks, `L1BankFactor=2`). **This** is what `insitu_cache_architecture_v2.md` means by "single wide cache, collapsed from four": the *v1 internal* structure of one controller used to be 4 sub-controllers + an interco *inside one cache*, and the v2 RTL collapsed that into one wide-line array. It is **not** a cluster-wide single cache.
- The L1 is **fully shared, no private cache**: every CC in a tile reaches **all** banks in its tile, and banks in *other* tiles through the remote ports + an **inter-tile crossbar** (`tile_remote_*` in `cachepool_group.sv`) — a NUMA-style shared L1 across the 16-core group. The address mapping / interleaving across banks is **programmable via register config in the xbars** (not a fixed hash).
- **Reconfigurable cache partitioning:** because the bank mapping is register-driven, software can re-point some xbars so that a subset of a tile's banks become **tile-private** (carved out of the global shared pool) — a runtime partition feature distinct from the cache↔SPM `_partitionable_flushable` split.

So the two "fours" are: (a) **4 cache controllers per tile** (one per core — the system composition the user described), and (b) the **4 internal sub-controllers** that the v2 RTL collapsed *within* each controller. My earlier "one cache per cluster" sentence wrongly merged them.

**What the GVSoC model builds** (the `spatz` target):

- **4 controllers + a hashed N→M crossbar** (`num_controllers=4`, `insitu_cache_config.py:340,427`), routing each request to one controller by **address-interleave** bits.
- For the `spatz` target this serves `num_cores=2` (`nb_core_per_cluster=2`) — so the model's 4 controllers are **not** a one-cache-per-core mapping; they are address-interleaved slices, structurally the *old v1 internal* layout applied at tile scope.
- There is **no Group/Tile hierarchy, no per-core par_coalescer/bypass_xbar structure, and no remote-access xbar** in the model.

So relative to the integrated RTL, the model differs on **three** axes: per-controller internals (address-interleaved set-assoc vs single wide-line + coalescer/bypass), per-core mapping (hashed-interleave vs one-cache-per-core), and system scale (a single flat tile vs 4 tiles × 4 cores with a remote xbar).

**The `enable_input_coalesce` caveat.** The model *approximates* the par-coalescer's same-cycle merging with a latency trick rather than a real merge. Its docstring (`insitu_cache_config.py:287-290`) states it plainly: when same-cycle, same-line read-hits arrive across ports, the first forwards normally and the **followers "inherit its" latency**. No actual wide request is formed and there is no response-split — the followers are simply handed a cheaper latency number. That suffices to match the *timing* of the calibrated case (`coal_warm`), but it is not the RTL's structural behaviour.

**What Phase B would be.** Refactor the model to mirror the RTL: a single wide-line cache controller (one per core), a *real* structural par-coalescer (wide-merge with hitmap/offsets + per-port response split), a scalar bypass_xbar mode, and — for whole-system cycle comparison — a Tile/Group composite (4 caches/tile, 4 tiles) with a remote-access crossbar. It is the largest open item because it is a structural rewrite, not a knob tweak — and the current calibrated model is accurate enough on per-access *timing* that it has not yet been forced.

**Bottom line for both.** The model is **timing-faithful but structurally simplified**. §9.1 was a bug where a closed-loop behaviour leaked into the timing-calibrated path; §9.2 is the known, intended simplification that Phase B would eventually close.