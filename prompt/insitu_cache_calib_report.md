# InSitu Cache — GVSoC ⇄ RTL Calibration (harness + first results)

**Date:** 2026-06-01
**Author:** GVSoC perf-model work (this repo)
**RTL reference:** `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/reports/cache_calib/`
(`PLAN.md`, `TRACE_SPEC.md`, `CALIB_IMPLEMENTATION.md`, `REPORT.md`,
`results_memlat{10,50,100,200}.csv`, `traces/sample.trace`).

## 1. What this is

The RTL side ships a standalone performance-calibration testbench around **one**
`cachepool_cache_ctrl` driven by a deterministic fixed-latency refill responder
(`refill_mem_model.sv`), with a documented trace + result-CSV interchange format
and reference numbers. This report documents the **GVSoC-side twin** built to the
same spec, so both engines run the *same* `port,rw,addr,size,delay` trace through
the *same* memory-timing model and we diff the per-access `latency` column.

GVSoC-side pieces (this repo):

| Piece | File |
|---|---|
| Serializing fixed-latency refill memory (twin of `refill_mem_model.sv`) | `core/models/cache/insitu/insitu_calib_mem.{cpp,py}` |
| Trace-replay driver + per-access monitor (twin of the RTL harness) | `pulp/insitu_cache_calib/calib_driver.{cpp,py}` |
| Calibration target (driver → 1-ctrl tile → calib mem) | `pulp/insitu_cache_calib/__init__.py` |
| Single-controller DUT geometry (5 ports, 4-way×256-set = 64 KiB) | `make_cachepool_512_calib_config()` in `insitu_cache_config.py` |
| Trace suite generator (warm-hit, cold-miss, streams) | `pulp/insitu_cache_calib/gen_traces.py` |
| Shared sample trace + RTL reference output | `pulp/insitu_cache_calib/traces/sample.trace`, `…_trace_out.rtl.csv` |

### Run it

```bash
make all TARGETS=insitu_cache_calib
python3 pulp/insitu_cache_calib/gen_traces.py              # (re)generate the trace suite
INSITU_CALIB_TRACE=cold_miss_isolated INSITU_CALIB_MEMLAT=50 \
    gvsoc --target=insitu_cache_calib run
# CSVs land in $INSITU_CALIB_OUTDIR (default /tmp/insitu_calib): per-access + aggregate.
```

Env knobs: `INSITU_CALIB_TRACE` (trace name), `INSITU_CALIB_TRACE_FILE` (abs path),
`INSITU_CALIB_MEMLAT` / `INSITU_CALIB_BEATGAP` / `INSITU_CALIB_ACCEPTEVERY`
(memory-model knobs), `INSITU_CALIB_OUTDIR` (output dir).

## 2. The memory model (the calibration linchpin)

`insitu_calib_mem` reproduces `refill_mem_model.sv` (CALIB_IMPLEMENTATION.md §2)
but as a **synchronous-OK, serializing** responder rather than an async FIFO,
because the InSitu controller resolves refills on the synchronous-OK path
(`issue_refill → refill_resp_handler` inline, reading `get_full_latency()`).
Serialization — the single most important behaviour (the RTL keeps **one**
outstanding line-refill) — is modelled with a `mem_busy_until` cyclestamp:

```
service_start = max(now, mem_busy_until)
occupancy     = MemLatency + (beats-1)*(1+BeatGap)          # beats = 4 for a 64B line
completion    = service_start + occupancy
latency_added = completion - now                            # carried on the IoReq
mem_busy_until = max(completion, service_start + AcceptEvery)
```

This makes back-to-back distinct-line misses serialize even though the controller
issues them on consecutive cycles, reproducing the RTL's memory-latency-bound,
non-pipelined miss throughput.

## 3. Calibration result — primary metrics (config 512, the four RTL headline points)

| Metric | RTL reference | GVSoC (calibrated) | Status |
|---|---|---|---|
| **Warm read-hit, isolated** | 10 cyc, MemLatency-independent | **10 cyc** (ML 10/50/100) | ✅ exact |
| **Cold read-miss, isolated** | MemLatency + 17 cyc | **MemLatency + 17** (27/67/117/217 @ ML 10/50/100/200) | ✅ exact across the sweep |
| **Miss throughput (1-port stream, serialized)** | ≈ 1/(MemLatency+overhead); refills do **not** pipeline | 64 acc / 3406 cyc = **0.0188 acc/cyc** @ ML50 (RTL 0.0181) | ✅ within 4% |
| **Single-port hit-throughput ceiling** | ≈ 0.86 acc/cyc | **0.877 acc/cyc** (steady-state tail) | ✅ within 2% |

### How the latency calibration was done

The model's intrinsic per-access composition is `interco(1) + cache_pipeline +
memory`. Two latency knobs on `InsituCacheController` close the gap to RTL
(applied in `make_cachepool_512_config`, so the spatz integration inherits them):

- `hit_latency_cycles = 9` → warm hit = interco(1) + 9 = **10** (RTL 10).
- `miss_penalty_cycles` (**new knob**, default 0 — no change for other configs)
  → cold miss = MemLatency + 17. The +17 = memory burst tail (3) + interco (1) +
  refill_bank_write + drain + the fixed cache-pipeline penalty. Verified
  MemLatency-independent at ML ∈ {10,50,100,200}. The penalty tracks the folded
  bank-write cost: **production** (folded) uses `refill_bank_write_cycles=2` +
  `miss_penalty_cycles=7`; the **conventional** (unfolded) config uses `1 + 8` —
  same total. (As of 2026-06-01 the calib config inherits the production
  folded+hash+fwd default, matching the RTL DUT banner `PartSplit=4, Folded=1,
  Hash=1`; see `prompt/insitu_cache_rtl_update_2026-06-01.md`.)

### Cold-miss-stream throughput vs MemLatency

| MemLatency | GVSoC cyc / thr | RTL cyc / thr |
|---|---|---|
| 10  | 846  / 0.0757 | 970  / 0.0660 |
| 50  | 3406 / 0.0188 | 3530 / 0.0181 |
| 100 | 6606 / 0.0097 | (sweep: ML+overhead trend) |
| 200 | 13006 / 0.0049 | (sweep: ML+overhead trend) |

GVSoC serialized per-miss ≈ MemLatency + ~3.2; RTL ≈ MemLatency + ~5.2 — i.e.
GVSoC is ~2 cyc/miss faster (most visible at low MemLatency: 13% at ML=10, 4% at
ML=50). A finer match would add ~2 cyc to the memory occupancy; deferred as it is
within the <5% target at the canonical ML=50.

## 4. Sample-trace per-access diff (mixed workload, ML=50)

`traces/sample.trace`, GVSoC vs RTL `latency` (cyc):

| idx | access | GVSoC | RTL | note |
|---|---|---|---|---|
| 0 | R line A (cold) | 67 | 117 | RTL idx0 queues behind concurrent port-1/4 refills; GVSoC clean |
| 1 | R line A+1 (cold) | 227 | 225 | ✅ |
| 2 | R line A+2 (cold) | 279 | 279 | ✅ exact |
| 3 | R line A+3 (cold) | 331 | 332 | ✅ |
| 4 | R line A (re-read) | 74 | 110 | merge/hit timing |
| 5 | R line A+1 (re-read) | 232 | 216 | ✅ close |
| 6 | **W** line (alloc) | 435 | 113 | **write early-ack not modelled** (gap) |
| 7 | R same word | 439 | 385 | follows the write |
| 8 | R port 1 | 121 | 171 | cross-port ordering |
| 9 | R port 1 | 383 | 438 | ✅ close |
| 10 | R port 1 | 536 | 442 | queue-order sensitive |
| 11 | **R port 4 (scalar)** | 175 | 60 | **scalar bypass not modelled** (gap) |
| 12 | R port 4 | 484 | 378 | scalar path |

Clean read-misses match nearly exactly (idx 1/2/3). The divergences are the known
gaps below (writes, scalar bypass, accept-depth ordering).

## 5. Gaps — closed (2026-06-02) and remaining

A round of model development (see §8) closed the write-path, forwarding, and
writeback gaps. Status:

**✅ Closed (2026-06-02):**
1. **Write early-ack / write latency.** Added `write_hit_latency_cycles` — a write
   hit acks faster than a read returns. Warm write isolated **8** (was 10) = RTL 8.
2. **Write throughput.** Added `write_commit_cycles` (controller-wide write-commit
   backpressure: a write accepts at most once per N cyc). Sustained 1-port writes
   **0.478 acc/cyc** (was 0.877) = RTL 0.489.
3. **Read-after-write forwarding.** Added a 1-entry forwarding-buffer model
   (`fwd_hit_latency_cycles`, gated on `use_forwarding_buffer`): a read on the
   just-touched line forwards combinationally, bypassing the bank (no `set_busy`
   stall). RAW same-word **7** (was 13) = RTL 7. Warm-hit isolated stays **10** (a
   cold-miss preload does not populate the buffer, so the isolated read is a normal
   bank hit — matches RTL).
4. **Writeback / refill overlap.** Added `writeback_overlap` to the calib memory:
   a dirty-victim writeback no longer serializes on the refill port (it overlaps,
   as in the RTL). Eviction-stream throughput **0.0189** (was 0.0126) = RTL 0.018,
   with `mem_wr` still counted (1024).

**◻ Remaining (need the Phase-B topology refactor or a full occupancy model):**
5. **Scalar bypass port.** RTL port 4 bypasses the coalescer (≈60 cyc); GVSoC
   routes all 5 ports identically through the one controller (sample idx11: 175 vs
   60). Needs the bypass-xbar (Phase-B topology).
6. **Input par-coalescer warm throughput.** RTL warm coalesced 4-port = 3.28
   acc/cyc (4 same-line ports collapse to one lookup); GVSoC has no input-side
   coalescer so the interco serializes the ports (~1/cyc). *Memory traffic already
   matches* (mem_rd=32 via MSHR-merge); only the warm-hit throughput differs.
   Needs the input par-coalescer (Phase-B topology).
7. **Bounded miss accept-depth / hit pipelining / multi-port hit ceiling.** GVSoC
   resolves refills inline, so `max_outstanding` reads 1 and a miss-heavy stream's
   *average* latency over-predicts (queue inflation; throughput is unaffected).
   RTL streaming hit settles to 7 (pipeline) vs GVSoC's 10; 4-port hit ceiling
   ≈0.86. These need a true occupancy model (return PENDING with a real completion
   event + bounded outstanding) — a deeper refactor deferred so as not to perturb
   the spatz integration.

Items 5–6 are the same topology items tracked in
`prompt/insitu_cache_architecture_v2.md` §11.

## 6. Bottom line

The harness matches the RTL on **all the primary latency/throughput points** —
warm hit (10), cold miss (MemLatency+17, exact across the sweep), miss
serialization (≈4%), single-port hit ceiling (≈2%) — and, after the 2026-06-02
development round, on **write latency (8), write throughput (0.48 vs 0.49), RAW
forwarding (7), and eviction throughput (0.019 vs 0.018)**. The memory-traffic
structure (coalescing → 32 refills, eviction → 1024 writebacks) also matches.
Remaining divergences are confined to the **topology** items (scalar bypass,
input coalescer warm throughput) and the **inline-resolution** items (bounded
accept-depth / hit pipelining / multi-port ceiling) — all documented above.

## 7. New RTL phases mirrored (2026-06-02)

The RTL TB grew seven phases beyond the original 4-metric suite (RTL
`CHARACTERIZATION.md`, 2026-06-01): warm write (latency + throughput), read-after-write
same-word (forwarding-buffer), cold/warm coalesced 4-port, and dirty-fill /
writeback-miss eviction. Its aggregate CSV also gained `mem_rd` / `mem_wr` columns.

Mirrored on the GVSoC side: matching traces added to `gen_traces.py`
(`warm_write_isolated`, `warm_write_stream_1p`, `raw_same_word`, `coal_cold_4port`,
`coal_warm_4port`, `evict_dirty_fill`, `evict_wb_miss_stream`), and the memory model
(`insitu_calib_mem`) now emits `[CALIB_MEM] mem_rd=… mem_wr=…` at end-of-sim (via
the `stop()` hook): refills = `mem_rd`, dirty evictions = `mem_wr`. (Counts are
cumulative over the single-trace run, so for *warm* phases the measured-phase memory
traffic is `total − preload_lines`.)

Comparison @ MemLatency=50 (GVSoC column = **after** the 2026-06-02 development round, §8):

| Phase | metric | GVSoC | RTL | verdict |
|---|---|---|---|---|
| `warm_write_isolated` | latency | **8** | 8 | ✅ (was 10; `write_hit_latency_cycles`) |
| `warm_write_stream_1p` | throughput (tail) | **0.478** | 0.489 | ✅ (was 0.877; `write_commit_cycles`) |
| `raw_same_word` | RAW read latency | **7** | 7 | ✅ (was 13; forwarding-buffer model) |
| `coal_cold_4port` | **mem_rd** | **32** | **32** | ✅ exact — controller MSHR-merge = input-coalescer's traffic reduction |
| `coal_cold_4port` | throughput | 0.025 | 0.067 | gap (no same-cycle input merge; interco serializes the 4 ports) |
| `coal_warm_4port` | mem_rd (warm = total−preload) | 0 | 0 | ✅ (all hits, no memory) |
| `coal_warm_4port` | throughput | ~0.06 agg | 3.28 | gap — no input coalescer; interco caps multi-port at ~1/cyc (Phase-B topology) |
| `evict_dirty_fill` (2× cap) | **mem_wr** | **1024** | 1051 | ✅ close — dirty-victim writebacks fire + counted |
| `evict_wb_miss_stream` | mem_rd / mem_wr | 2048 / 1024 | 2054 / 1029 | ✅ close |
| `evict_*` | throughput | **0.0189** | 0.018 | ✅ (was 0.0126; `writeback_overlap`) |

## 8. Model development round (2026-06-02) — closing the gaps

New controller knobs (defaults are no-op; the production `cachepool_512` config opts in):
- `write_hit_latency_cycles` (7) — a write hit acks faster than a read returns
  (RTL write-info-FIFO push). Warm write 10 → **8**.
- `write_commit_cycles` (2) — controller-wide write-commit backpressure: a write
  hit is `IO_REQ_DENIED` if it arrives while the previous write's commit slot is
  still busy; the upstream retries next cycle. Sustained write throughput
  0.877 → **0.478** (RTL 0.489).
- `fwd_hit_latency_cycles` (6) + the existing `use_forwarding_buffer` — a 1-entry
  forwarding buffer (`fwd_buffer_line_`): a read on the just-touched line forwards
  combinationally, **bypassing the bank** (no `set_busy` stall). RAW same-word
  13 → **7**. Populated on hits only (a cold-miss preload doesn't populate it), so
  isolated warm-hit stays 10 — matching RTL.

New calib-memory knob:
- `writeback_overlap` (on for the calib target) — dirty-victim writebacks don't
  consume the refill-port serialization (`mem_busy_until`); they overlap the
  refill as in the RTL. Eviction throughput 0.0126 → **0.0189** (RTL 0.018).

Verified no regression: `cold_miss=MemLatency+17` (sweep), `warm_hit=10`,
`cold_stream` throughput 0.0188, `coal_cold` mem_rd=32 all unchanged; the spatz
integration (`spatz:use_insitu_cache=True`) and `insitu_cache_microbench` build
and run clean (microbench `hit_repeat` 2.55→1.98 c/p — the forwarding buffer now
speeds repeated same-line reads).

**What this validates.** The **memory-traffic counts match** (coalescing collapses
128 same-line accesses to 32 refills; dirty evictions produce the expected ~1024
writebacks) — i.e. the model's *miss / coalesce / evict structure* is right. The
**throughput/latency gaps are exactly the documented Phase-B items**: write path
(early-ack + write-info serialization), input par-coalescer (same-cycle merge +
multi-port hit rate), forwarding-buffer same-row forward, and writeback/refill
overlap on the shared refill port. None are new — they're the same backlog as §5.

New traces: run any with `INSITU_CALIB_TRACE=<name> gvsoc --target=insitu_cache_calib run`.
