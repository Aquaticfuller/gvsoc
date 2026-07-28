# InSitu Cache GVSoC Model — Calibration Progress (for slides) — 2026-06-15

## Part A — Narrative report

### A1. What "calibration" means here

Calibration means making the cycle-approximate GVSoC timing model of the CachePool InSitu L1 data cache agree with the CachePool RTL. There are two regimes:

- **Open-loop (trace-replay)** — the RTL ships a standalone perf-calibration testbench around **one** `cachepool_cache_ctrl` driven by a deterministic, **serializing** fixed-latency refill responder (`refill_mem_model.sv`), plus a documented `port,rw,addr,size,delay` trace + per-access result-CSV interchange format and reference numbers (`ManyRVData_rebase/reports/cache_calib/`). The GVSoC side reproduces this **exactly**: `insitu_calib_mem.{cpp,py}` is the serializing twin (`mem_busy_until` cyclestamp → one outstanding line-refill; `service_start = max(now, mem_busy_until)`, `occupancy = MemLatency + (beats-1)*(1+BeatGap)`), `pulp/insitu_cache_calib/calib_driver.{cpp,py}` is a trace-replay driver (per-port file-order + concurrent-port semantics, stamps `t_issue`/`t_resp`, `t_resp = t_issue + get_full_latency()`), and `make_cachepool_512_calib_config()` sets the DUT geometry (5 ports, 4-way × 256-set = 64 KiB). **Both engines run the SAME trace through the SAME memory-timing model; calibration = diffing the per-access `latency` column.** Two run modes: default serialized Burst=4 (cold miss = `ML+17`) and `INSITU_CALIB_WIDE_REFILL=1` Burst=1 (cold miss = `ML+13`, misses pipeline, 32-outstanding requester budget binds).

- **Closed-loop (integration)** — the cache wired into a real Spatz cluster (`--target=spatz --target-property use_insitu_cache=True`) running a real kernel end-to-end. Validates correctness + boot, but cycle counts are **not yet diffable** against RTL (topology mismatch, see A5/A6).

The model target is cycle-approximate (<5%). It matches all headline single-controller latency/throughput points and memory-traffic structure (coalescing 128→32 refills; eviction ~1024 writebacks).

### A2. Open-loop calibration status (RTL-reference vs GVSoC)

| Metric | RTL reference | GVSoC | Within-% / status |
|---|---|---|---|
| Warm read-hit (isolated) | 10 cy | 10 | exact |
| Warm read-hit (streaming) | 7 cy | 7 | exact |
| Cold read-miss (serialized) | `ML+17` (27/67/117/217) | `ML+17` | exact |
| Cold read-miss (wide Burst=1) | `ML+13` (23/63/113/213) | `ML+13` | exact |
| Serialized miss throughput | 0.0181 acc/cyc | 0.0188 | within target |
| Single-port hit ceiling | ~0.86 acc/cyc | 0.877 | within target |
| Warm write-hit latency | 8 cy | 8 | exact |
| Write throughput | 0.489 acc/cyc | 0.478 | within target |
| RAW (same-word) latency | 7 cy | 7 | exact |
| Eviction (writeback) throughput | 0.018 acc/cyc | 0.0189 | within target |
| `coal_warm` throughput | 3.28 acc/cyc | 3.37 | +2.7% |
| Wide cold-stream thr @ML50 | 0.243 acc/cyc | 0.254 | ≤7% |
| `coal_cold` wide thr @ML50 | 0.467 acc/cyc | 0.496 | +6.2% |
| `coal_cold` refill count (`mem_rd`) | 32 | 32 | exact |
| Eviction writebacks (`mem_wr`) | 1024 | 1024 | exact |

Status: **ALIGNED-CONFIRMED** vs RTL `run_2026-06-12` (DUT `93d1c11`) — the post-rebase RTL run is cycle-identical to the Jun-3 `char_bl1` baseline, so the reference is unchanged and calibration held byte-identical (`calib_report §14`).

#### A2.1 What each metric means (read this before the table)

Each row above is one **micro-benchmark phase** — a hand-written access trace (`pulp/insitu_cache_calib/gen_traces.py`) that isolates one behaviour. "Latency" rows are **cycles from request to data for one access**; "throughput" rows are **sustained accesses per cycle** under continuous load; "count" rows are **how many L2 transactions** the access pattern generates. `ML` = MemLatency, the configured round-trip to the next memory level (swept 10/50/100/200).

- **Warm read-hit (isolated)** — one read that hits a resident line *with nothing else in flight*. The hit pipeline starts **empty**, so this access pays the **full pipeline depth** → **10 cy**. ("Warm" = the line is already cached; "isolated" = no neighbouring traffic.)
- **Warm read-hit (streaming)** — the **steady-state** hit latency when **back-to-back** read-hits keep the hit pipeline **full**. Pipelining overlaps successive hits, so each one completes in **7 cy** instead of 10. *The 10-vs-7 gap is purely pipeline fill:* the first hit of a burst pays 10, every later hit in the stream settles to 7. (There is a gradient in between — gap 0/1/2/3 reads cost 7/8/9/10 — `bw_hit`.)
- **Cold read-miss (serialized, Burst=4)** — a read that **misses** and must refill a line from L2, in the **shipping** single-outstanding 4-beat-burst config. Latency = **`ML + 17`** (17 = fixed cache pipeline + 4-beat assembly overhead).
- **Cold read-miss (wide, Burst=1)** — same miss but in the **experimental** single-wide-beat refill mode = **`ML + 13`** (no multi-beat assembly).
- **Serialized miss throughput** — sustained misses/cyc when misses **cannot overlap** (one outstanding refill at a time) ≈ `1/(ML+17)` ≈ 0.018 @ML50. This is the worst-case miss bandwidth.
- **Single-port hit ceiling** — the **maximum** accesses/cyc one port can sustain when **everything hits** (≈0.86). The hit-path bandwidth limit of a single controller port.
- **Warm write-hit latency / Write throughput** — latency (8 cy) and sustained rate (≈0.49 acc/cyc, about half the read-hit rate) of writes that hit a resident line.
- **RAW (same-word) latency** — **read-after-write to the same word**. The 1-entry **forwarding buffer** returns the just-written value in **7 cy** without re-reading the SRAM (and with **zero** memory traffic) — faster than a normal hit.
- **Eviction (writeback) throughput** — sustained rate of **dirty-line writebacks** when a miss-stream keeps evicting dirty victims.
- **`coal_warm`** — 4 VLSU ports reading **the same line in the same cycle**; the input **par-coalescer merges them into one lookup**, so the *effective* rate is ≈4× a single port (≈3.3 acc/cyc). Measures coalescing of **hits**.
- **Wide cold-stream throughput** — one port streaming **cold misses** (distinct lines) in wide-refill mode; the sustained miss rate once refills can pipeline.
- **`coal_cold`** — 4 ports each missing on **different cold lines** (they **cannot** coalesce); stresses the MSHR/refill path. The companion **`coal_cold` refill count** shows the MSHR merge: 128 same-line accesses collapse to **32** actual L2 refills.
- **Eviction writebacks (`mem_wr`)** — number of dirty writebacks to L2 in the eviction phase (structural traffic check, not timing).

"Within-% / status": **exact** = cycle-identical to RTL; **within target** / **≤7%** / **+x%** = the relative error vs the RTL reference (all within the model's calibration tolerance).

### A3. Improvements to the open-loop calibration (timeline, before→after)

1. **Harness + 4 headline metrics** — built the GVSoC twin (serializing mem, trace-replay driver, 512 calib config); calibrated `hit_latency_cycles=9` / `miss_penalty_cycles=8`. baseline → warm hit 10, cold miss `ML+17`, miss thr 0.0188 vs 0.0181, hit ceiling 0.877 vs ~0.86. (core `233850f4` / pulp `3d15e5d`)
2. **Write-path + forwarding + writeback-overlap** — warm write 10→8 (RTL 8); write thr 0.877→0.478 (RTL 0.489); RAW 13→7 (RTL 7); evict thr 0.0126→0.0189 (RTL 0.018). (folded into core `233850f4`)
3. **Wide single-beat refill (Burst=1)** — cold miss = `ML+13` exact; serialized→wide jump cold_stream 0.0188→0.41 (~22×). (core `6347ea65` / pulp `f80254b`)
4. **OCCUPANCY MODEL — miss-heavy throughput** — `defer_refills` + `refill_drain_cycles=3` serialize refill completion via a monotonic cyclestamp. cold_stream 0.41→0.254 (RTL 0.243); `coal_cold` 0.65→0.494 (RTL 0.467); evict 0.49→0.166 (RTL 0.177); **all ≤7% @ML50, was 1.4–2.8× over**. (core `6347ea65` / pulp `f80254b`)
5. **PAR-COALESCER — `coal_warm`** — `enable_input_coalesce` lets same-cycle same-line read followers inherit the leader's latency with no extra accept slot. `coal_warm` **0.06→3.122 acc/cyc** (RTL 3.282); `coal_cold` held 0.494, `mem_rd`=32. (core `edfc99d2` series)
6. **STREAMING read-hit pipelining (10→7)** — `streaming_hit_latency_cycles` with a warmth gradient. warm_stream 10→7; `coal_warm` latency 10→7 and thr 3.122→3.37 (RTL 3.28, +2.7%); gap-latency gradient 7/8/9/10/10 exact. (core `edfc99d2` / pulp `2282baa`)
7. **Real-kernel fixes #1, #4, #2, and #5** — see A4 (the headline). (core `37982db9` → `49c377d9` → `6362b3da` / pulp `f0706bc`)

### A4. The fix #5 real-kernel alignment result (HEADLINE)

**What "Mean Δ" means.** Unlike the synthetic phases (one number per micro-benchmark), here we replay a **real kernel's actual access trace** — every load/store the kernel issued, recorded from an RTL run with its real arrival times — and compare, **per access**, the latency GVSoC's cache model returns against the latency the RTL recorded. **Mean Δ = the average, over *all* accesses in the trace, of (GVSoC per-access latency − RTL per-access latency), in cycles.** `+3.9` means "on average GVSoC says each access takes 3.9 cycles longer than the RTL did." "Hit Δ" / "miss Δ" split that average over accesses RTL served as hits vs misses. (`n` = 43k–334k accesses/kernel, so these are well-averaged.)

| Kernel | accesses | RTL avg lat | GVSoC avg lat | Mean Δ before | Mean Δ after fix #5 | Hit Δ after |
|---|---|---|---|---|---|---|
| fmatmul M32 | 42.8k | 10.2 cy | 14.0 cy | +61.5 (→ +26.5 after #1/#4/#2) | **+3.9** | +3.3 |
| fft M1024 | 107k | 10.4 cy | 13.6 cy | +72.9 (→ +34.6) | **+3.2** | +4.1 |
| fmatmul M128 | 334k | 13.2 cy | 19.6 cy | +84.9 (→ +62.7) | **+6.4** | +4.5 |
| gemv M512 | 205k | 35.7 cy | 38.2 cy | +77.4 (→ +76.1) | **+2.6** | +0.9 |
| fdotp M8192 | 49.6k | 109.5 cy | 130.6 cy | +70.6 (→ +75.0) | **+21.1** (miss-path) | +0.3 |

Result: **+2.6..+6.4 cy on 4 of 5 kernels; hit Δ +0.3..+4.5 everywhere.** Only fdotp retains a large residual, and it is **entirely miss-path** (+62.7 unchanged; hit path is exact at +0.3). gemv collapsing to +2.6 disproved the earlier "inherent cascade" attribution for the others. (core `6362b3da` / pulp `f0706bc`)

#### A4.1 As a percentage — and what we do *not* yet have

We can express the same result as a **per-access latency error %** = `Mean Δ / RTL avg latency` (= how much GVSoC over-states the average access latency). After fix #5:

| Kernel | Mean Δ after | RTL avg | **per-access latency error** | GVSoC/RTL ratio |
|---|---|---|---|---|
| gemv M512 | +2.6 | 35.7 | **+7.3 %** | 1.07× |
| fdotp M8192 | +21.1 | 109.5 | **+19.3 %** | 1.19× |
| fft M1024 | +3.2 | 10.4 | **+30.8 %** | 1.31× |
| fmatmul M32 | +3.9 | 10.2 | **+38.2 %** | 1.37× |
| fmatmul M128 | +6.4 | 13.2 | **+48.5 %** | 1.48× |

**Two important caveats on this percentage** (so it isn't misread):

1. **It is *per-access latency* error, NOT end-to-end kernel-runtime error.** Open-loop replay stamps each access's latency against a pre-recorded trace; it does **not** simulate the whole kernel's pipeline or how accesses **overlap** (memory-level parallelism). A +3.9 cy mean per-access delta does **not** translate to +38% kernel runtime — most of those cycles hide under overlap. So this % is closer to an *upper bound* on the cache's contribution to runtime error than to a runtime prediction.
2. **The percentages look large because the denominator is tiny.** For the hit-dominated kernels the RTL average access is only ~10 cy (a warm hit), so even a few cycles is a big fraction. This is *not* in tension with the "warm hit = exactly 10 cy" synthetic calibration: the synthetic phase isolates a *clean* hit, whereas a real kernel mixes gap-dependent hits (the 7→10 gradient), misses, and contention, leaving the small +0.3..+4.5 cy hit residual that dominates these ratios.

**Do we have an end-to-end cycle-count % difference? Not yet, open-loop.** The traces are *per-access records*, not a runtime model, so open-loop produces per-access latency only — there is no total-kernel-cycle number to compare. A true "kernel ran in X cycles, RTL took Y, error = (X−Y)/Y" requires **closed-loop** simulation, which is currently **topology-blocked** (GVSoC flat 2-core/4-controller tile vs the RTL 16-core 4-tile shared-L1 — see A5/A6). Producing that number is exactly what the Phase-B structural refactor + Tile/Group composite in the dev plan unlock.

### A5. Closed-loop status

- **First end-to-end real Spatz kernel run.** `examples/spatz/test-riscvTests-vfadd` with `use_insitu_cache=True` now **PASSES all 15 test cases (retval=0, cycles=58001)** — it previously **hung at boot**.
- **Bring-up = a 4-bug hang cascade + a wide-access data bug**, all fixed and gated to the cluster behind `carry_data_ = inline_sync_miss_ || functional_writethrough_` (`controller.cpp:263`): (1) no data modelling → garbage loads → bogus HTIF syscall livelock (added `line_data_` byte store + `exchange_line_data()`); (2) writeback invisible to the HTIF backdoor (`functional_writethrough` → `functional_write_mem()`); (3) refill-address rewrite deadlock — `wide_axi` mutated the refill addr so the MSHR never matched (stash `pending_refill_addr_`); (4) snitch v1 ISS LSUs accept only synchronous `IO_REQ_OK` (`inline_sync_miss` completes synchronously-resolved misses INLINE). The actual data bug: the interco interleaves controllers at 4-byte granularity, so an 8-byte store routed wholesale left a stale upper word — fixed by **splitting accesses that cross the granule** (`interco.cpp:134-163`, gated `num_outputs_>1` so calib stays byte-identical).
- **The open-loop regression we caught and fixed.** Phase-2 work had leaked the two driver flags (`inline_sync_miss` / `functional_writethrough`) into the **base** factory `make_cachepool_512_config()`, which the calib config derives from. The inline-miss branch never calls `reserve_install_pipe`, bypassing the calibrated `defer_refills` occupancy throttle → calib regressed **fmatmul M32 3.9→7.5** and **coal_cold @ML50 0.4961→0.6531**. **Option-B fix:** the flags describe how the cache is *driven* (not geometry), so they were removed from the base factory and set True only at the Spatz cluster site (`snitch_cluster.py:300-301`). A clean full build restored both open-loop targets (**3.9 / 0.4961**) AND the closed-loop pass (**58001**). (core `6362b3da`+`3d712809`, pulp `f0706bc`+`d8abb08` — all PUSHED to `origin/insitu-cache`; parent pointer-bumps `18298b8`/`b2eb076` are local only.)
- **CAVEAT.** `cycles=58001` is **NOT yet diffable against an RTL reference**: the GVSoC Spatz cluster is a single flat tile of ~2 cores behind 4 address-interleaved controllers, whereas the integrated RTL is **16 cores = 4 tiles × 4 cores, one cache per core, plus a cross-tile remote-access crossbar**. The gap is **structural, not a scale factor.**

### A6. What remains

**Open-loop residuals (calibration):**
- **fdotp inherent miss cascade** — miss Δ +62.7 (mean +21.1), unchanged by any cache-model fix; hit path is exact (+0.3). Open-loop replay can't reproduce the core's data-dependency stall (RTL core stalled on the miss; replayed hit runs ahead). Needs a closed-loop injection model or the heavy deferred-completion path (repeatedly **NO-GO**).
- **`coal_cold` / evict distributions** — throughput matches, but max-outstanding and latency *distributions* differ (coal_cold out ~128 vs RTL 56; evict out 32 vs RTL 4). Proven coupled to one knob (D=3 joint optimum); any gated refactor is NO-GO without regression risk to the exactly-matched cold_stream/evict.
- **Saturation hit ceiling** ~0.91 vs RTL 0.865 (~5.7% over); **low-ML cold_stream plateau** +24% @ML10 (a single drain rate can't reproduce RTL's hard install-pipeline cap). Both ≤10% for ML≥50.
- **Coverage gaps (no GVSoC trace yet, not model defects):** `bw_hit_{1,2,3}port` port-scaling and `mshr_depth_1p`.

**Closed-loop / structural topology gap:**
- The model still implements the **v1 topology** (N=4 narrow controllers + hashed N→M interco + N write-through coalescers + L2 fan-in). The current RTL is a **single wide 512b per-core cache + N→1 par_coalescer + scalar bypass_xbar + Tile/Group composite with remote xbar**. `enable_input_coalesce` only *approximates* the par-coalescer (followers inherit latency; no real wide request, hitmap, or response split). The structural Phase-B refactor (largest open item) and closed-loop cycle validation both depend on this reconciliation.
- The async closed-loop path (`inline_sync_miss=False`, park+MSHR+deferred-resp) is exercised today only by the open-loop calib driver, not behind a real async core; re-validate when the async-capable Spatz model lands (designed to drop in with a one-line change).

---

## Part B — Suggested 4-slide deck

### Slide 1 — What we built & how we calibrate it
**Bullets:**
- Cycle-approximate GVSoC timing model of the CachePool InSitu L1 data cache (<5% target).
- **Open-loop calibration** = replay the *same* `port,rw,addr,size,delay` trace through the *same* fixed-latency serializing memory model in both RTL and GVSoC, then **diff the per-access `latency` column**.
- GVSoC twin reproduces the RTL standalone TB exactly: serializing refill mem (`insitu_calib_mem`), trace-replay driver, 512 config (5 ports, 4-way × 256-set = 64 KiB).
- **Closed-loop** = the cache wired into a real Spatz cluster running a real kernel end-to-end (boot + correctness).
- Two open-loop run modes: serialized Burst=4 (cold miss `ML+17`) and wide Burst=1 (cold miss `ML+13`).

**Suggested visual:** a simple block diagram — `trace → {RTL DUT, GVSoC twin} → per-access latency CSVs → diff`, with an inset listing the two regimes (open-loop trace-replay vs closed-loop Spatz integration).

### Slide 2 — Open-loop results + the improvement timeline
**Bullets:**
- All headline single-controller points calibrated: warm hit 10, streaming hit 7, cold miss `ML+17`, write hit 8, RAW 7 — **exact**.
- Throughputs within target: serialized miss 0.0188 vs 0.0181; hit ceiling 0.877 vs ~0.86; write 0.478 vs 0.489; evict 0.0189 vs 0.018.
- Memory-traffic structure exact: coalescing `mem_rd`=32, eviction `mem_wr`=1024.
- **Occupancy model** (`defer_refills`, `refill_drain_cycles=3`) closed wide miss-heavy throughput from **1.4–2.8× over to ≤7%** (cold_stream 0.254 vs 0.243; coal_cold 0.496 vs 0.467; evict 0.166 vs 0.177).
- **Par-coalescer + streaming pipelining** closed `coal_warm` **0.06 → 3.37 acc/cyc** (RTL 3.28, +2.7%) and the 10→7 streaming hit.
- **ALIGNED-CONFIRMED** post-rebase vs RTL `run_2026-06-12`.

**Suggested visual:** the **RTL-vs-GVSoC reference table** (A2) — color the "exact" and "≤7%" rows green; optionally a small before→after bar for the occupancy-model wins (coal_cold 0.65→0.494, evict 0.49→0.166).

### Slide 3 — Headline: fix #5 real-kernel per-access alignment
**Bullets:**
- Real-kernel trace replay initially **over-predicted per-access latency by +61.5..+84.9 cy mean** across 5 kernels.
- Root cause: the interco **output arbitration** (`output_busy_until_`) double-counted RTL cross-cycle backpressure that the trace's `t_issue` already encodes.
- **Fix #5 — per-cycle output arbitration**: reset the accept counter each cycle, serialize only same-cycle requests (`core 6362b3da`).
- Result: **+2.6..+6.4 cy on 4 of 5 kernels; hit Δ +0.3..+4.5 everywhere.**
- fmatmul M32 +3.9, fft +3.2, fmatmul M128 +6.4, gemv +2.6; **only fdotp residual +21.1 — entirely miss-path** (hit path exact at +0.3).
- gemv collapsing to +2.6 disproved the "inherent cascade" attribution for the other kernels.
- *(If asked "what %?")* as per-access latency error that's +7% (gemv) to +49% (fmatmul M128) — large only because the denominator is a ~10-cy hit; it is **per-access latency, not kernel runtime** (accesses overlap), and an end-to-end runtime % needs closed-loop (topology-blocked). See A4.1.

**Suggested visual:** the **5-kernel before→after grouped bar chart** (mean Δ before vs after fix #5), with fdotp annotated "miss-path residual." This is the headline graphic. *(Keep the chart in absolute cycles — it's the honest, overlap-agnostic metric; reserve the % for the speaker's Q&A answer above.)*

### Slide 4 — Closed-loop bring-up + what's next
**Bullets:**
- **First real Spatz kernel end-to-end:** `vfadd` PASSES all **15/15 TCs (retval=0, cycles=58001)** — previously hung at boot.
- Bring-up fixed a **4-bug hang cascade + a wide-access data bug**, all gated to the cluster (`carry_data_`); open-loop stays byte-identical.
- Caught & fixed an **open-loop regression** (flags leaked into the base factory: fmatmul 3.9→7.5, coal_cold 0.4961→0.6531) via **Option-B** — clean build restored 3.9 / 0.4961 **and** kept vfadd 15/15.
- **Caveat:** `cycles=58001` is **not yet diffable vs RTL** — GVSoC flat 2-core/4-controller tile vs RTL 16-core 4-tile per-core caches + remote xbar (**structural, not a scale factor**).
- Open items: fdotp miss-path cascade (needs closed-loop injection); coal_cold/evict distributions (coupled, NO-GO); **Phase-B structural refactor** (single-wide per-core cache + real par-coalescer + scalar bypass + remote xbar) for closed-loop cycle validation.

**Suggested visual:** a status callout box — "vfadd 15/15 PASS, cycles=58001" with a green check — beside a small topology-mismatch sketch (GVSoC flat tile vs RTL 4-tile × 4-core), captioned "cycle diff blocked on Phase-B structural reconciliation."
