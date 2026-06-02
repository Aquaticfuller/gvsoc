# Upstream Updates — Relevance to the InSitu Cache Model

> Reviewed: 2026-04-21 after rebasing both `insitu-cache` branches onto fork
> masters. Commit ranges examined:
>
> - `core`: `0d03eda7..455488f8` (≈ 60 commits)
> - `pulp`: `72a7ea1..abcddd6`  (≈ 31 commits)
>
> This document grades each thematic group of upstream changes by how
> directly it could help (or force changes to) the InSitu cache model under
> `core/models/cache/insitu/`.

## 1. TL;DR — recommended priorities

| Priority | Item | Why |
|---|---|---|
| **P1 (adopt now)** | **`cache_v4`** as a reference port to io_v2 | Direct sibling of the model we extended. Shows the canonical io_v2 port-signature pattern + the beat-streaming refill completion idiom. Cleanest template if we want our cache to plug into the new router_v2/io_v2 stack. |
| **P1 (adopt now)** | **`ri5ky_testbench` calibration suite + `calib.h`** | Drop-in methodology for cycle-level RTL↔GVSoC comparison — exactly the blocker we hit at the end of Phase-6 validation. The pattern is "small inline-asm block, `calib_cycles()` start/end, structured `CALIB_REPORT` print". We can port one of these for cache-specific stimulus (streaming load, random load, write-then-read, etc.). |
| **P2 (adopt next)** | **Traffic generator v2** (`interco/traffic/generator_v2.{cpp,py}`) | Synthetic stimulus on io_v2 with `nb_pending_reqs` outstanding requests. Lets us drive the cache via `i_CONTROL`-programmed patterns instead of needing a real Spatz binary. Big throughput win for microbenchmarks (no 4-core ISS). |
| **P2 (consider)** | **`router_v2` family** (untimed / bandwidth / **backpressure** / **beat**) | More accurate than the synchronous router we use today. `KIND_BACKPRESSURE` adds explicit `retry()` semantics; `KIND_BEAT` does proper per-cycle beat forwarding. If we migrate to io_v2, we likely want `KIND_BEAT` on the L2 path. |
| **P2 (consider)** | **`memory_v3`** + **`BeatResponseAdapter`** | Memory_v3 is the io_v2 memory model. The auto-inserted BeatResponseAdapter converts a sync DONE into a per-beat resp stream. With these, our refill no longer needs the `set_duration(beats)` hack — the downstream emits one resp() per beat naturally. |
| **P3 (nice to have)** | **iss_v2 per-register stall reason / LSU per-bus-transaction events** | Better stall classification when measuring cache contribution to overall workload time. Lets us attribute pipeline stalls to "cache miss" specifically. |
| **P3 (nice to have)** | **Waveform dumper (`utils/fsdb_dumper`, `utils/fst_dumper`)** | Exposes GVSoC traces as GTKWave-friendly FST. Useful to visualize cache state alongside RTL waveforms during validation. |
| **Tracking only** | RI5CY / SpatzMempool / Magia changes | Different ISA / SoC. No direct impact on our model. |
| **Tracking only** | FlooNoC v2 model | Future direction if cache eventually fans out to a NoC. Not relevant now. |

## 2. Detailed per-item review

### 2.1 cache_v4 — `cbea7aa3 cache: add v4 on io_v2 with testbench`

**Files:** `core/models/cache/cache_v4.{cpp,py}`, `core/tests/cache/cache_v4/*`

A direct port of `cache_v3` to the io_v2 protocol. Header comment:

> Direct port of cache_v3 to the io_v2 IO interface. Functional scope and
> [...] same. [...]

Architectural deltas vs. v3 (and what we should learn for InSitu):

- **Port signature change**: `signature='io_v2'` on `i_INPUT` and `o_REFILL` (instead of `'io'`). Our InSitu controllers use `signature='io'` today.
- **Beat-streaming refill completion**: the cache only commits the refill on the **last beat** of the response — `if (!req->is_last) return;` (cache_v4.cpp:259). On a beat-streaming downstream (`router_v2` `KIND_BEAT`), refill issues one req and gets N resp() calls, one per beat. Cleaner than our `set_duration(beats)` placeholder.
- **No scratch arg stack**: explicitly noted in cache_v4.cpp:18 — "pending CPU requests are tracked by member fields and a queue [...] No arg stack". Same design choice we made for InSitu (we use a side-deque of `MshrEntry`).

**Action for InSitu**: When/if we migrate to io_v2, use cache_v4 as the reference port. The MSHR mechanics stay; just swap port signatures and add the `if (!req->is_last) return;` guard on the refill response path.

### 2.2 router_v2 family — `f67a9f89 router: add v2 router family ...`

**Files:** `core/models/interco/router/router_v2_{untimed,bandwidth,backpressure,beat}.cpp`, `core/models/interco/router_v2.py`

Four router implementations selected by a `kind` argument. The interesting ones for the cache path:

- **`KIND_BACKPRESSURE`** (`router_v2_backpressure.cpp`): explicit `retry()` upstream when an output frees up. Replaces the implicit "DENIED → upstream re-tries next cycle" GVSoC convention with a real cycle-accurate handshake.
- **`KIND_BEAT`** (`router_v2_beat.cpp`): forward path emits one req() per beat (`is_first`/`is_last`); response path emits one resp() per beat. Allocates a slot per burst, remaps `burst_id`. Cleanest cycle-accurate cache↔L2 link.

**Current state of InSitu**: we use the synchronous old router for the L2 fan-in (it's a single composite-pass-through `l2` port today). The interco between cores and cache controllers is `InsituCacheInterco` (our own component, with `output_busy_until` cyclestamps).

**Action for InSitu**: phase-7 migration: replace the L2 fan-in router with `Router_v2(kind=KIND_BEAT)` to get realistic refill / writeback beat pacing. Our `InsituCacheInterco` stays — it has cache-specific routing semantics (`dynamic_offset` hash to controller) that aren't a fit for the generic router.

### 2.3 io_v2 + BeatResponseAdapter — `9ed9b165 io_v2: add BeatResponseAdapter ...` and `2bd78772 Auto-insert io_v2 beat adapter ...`

**Files:** `core/models/utils/io_v2_beat_adapter.{cpp,hpp,py}`

The framework now auto-inserts a beat adapter when two io endpoints with different beat semantics meet (signature `io_v2` ↔ `io_v2_beat` etc.). The adapter:

- Returns `IO_REQ_GRANTED`/`IO_REQ_DENIED` from submit; never returns inline DONE.
- For each accepted burst, emits exactly `ceil(total_size / beat_width)` resp() calls with cumulative byte ordering and per-beat `is_first`/`is_last`.
- Honours the slave's `req->latency` annotation; spreads beats so the LAST lands at `now+latency`.

**Action for InSitu**: when we migrate ports to io_v2, the adapter is auto-injected by gvrun2's binding-collection pass — we don't instantiate it ourselves. Refill request: `set_size(64); req()` → response arrives as 4 resp()s of 16 B each (for `refill_beat_bytes=16`).

### 2.4 memory_v3 — `a4e9c17e memory: add v3 on io_v2 with testbench`

**File:** `core/models/memory/memory_v3.{cpp,py}`

io_v2 port of `memory_v2`. Same bandwidth/latency knobs, but emits per-beat responses through the auto-inserted adapter.

**Action for InSitu**: when the spatz cluster's SPM gets ported to memory_v3, our cache's L2 path will benefit automatically. No InSitu changes needed.

### 2.5 Traffic generators v2 — `fc2b584b Add v2 traffic gen/recv ...`

**Files:** `core/models/interco/traffic/generator_v2.{cpp,py}`, `receiver_v2.{cpp,py}`

`GeneratorV2(parent, name, nb_pending_reqs=64)` — driven by `i_CONTROL` (a wire of `TrafficGeneratorConfig`), emits configurable io_v2 traffic up to `nb_pending_reqs` outstanding.

**Why this matters for us**: at the end of the validation report (§7) we said "the fastest way to get a numerical RTL↔GVSoC cycle comparison is to write a small, single-core, printf-free benchmark". The traffic generator is even better — it bypasses the ISS entirely. Drive `InsituCacheTile.i_INPUT(0)` with `GeneratorV2`, count cycles to a fixed transaction count. No Spatz boot overhead, no barrier waits.

**Action for InSitu**: phase-6 validation harness — build a target like `pulp/insitu_cache_tb.py` but with `GeneratorV2` in place of the RV32 host. Then loop over patterns (streaming, strided, random, write-then-read) and emit cycle counts. This is probably the single highest-leverage change to unblock the Phase-6 numerical comparison.

### 2.6 RI5CY testbench + calibration suite (pulp)

**Files:** `pulp/tests/ri5ky_testbench/calibration/{load_use,jr_stall,...}/test.c`, `pulp/tests/ri5ky_testbench/calibration/calib.h`

Each calibration is a tiny stand-alone C program: inline-asm block, `calib_cycles()` start/end, `CALIB_REPORT("name", iters, cycles)` print. Example (`load_use/test.c`):

```c
uint32_t start = calib_cycles();
__asm__ volatile (DO_THE_PAIRS : : "r"(p) : ... );
uint32_t end = calib_cycles();
return end - start;
```

The companion `Cross-check PCER ld_stall against RTL on Ri5ky` (`696e499`) commit shows that these are *also* run on the RTL side and the cycle counts are diff-compared. **This is the canonical pattern for RTL↔GVSoC cycle calibration in this repo.**

**Action for InSitu**: phase-6 validation tests should follow the same template — small inline-asm blocks that touch the cache in known ways (cold streaming read, repeat-hit, write-then-read, etc.), with `CALIB_REPORT`-style output. Run on both RTL and GVSoC, `diff` the cycle counts. We have the GVSoC exit/print path wired (`[HTIF] Simulation exiting: cycles=N`); we just need the test corpus.

### 2.7 iss_v2 per-event hooks — multiple commits

- `9a435ffa iss_v2: per-register stall reason in scoreboard + LSU tags loads`
- `3bbe1b0f iss_v2 LsuV2: account load / store events per bus transaction`
- `0b33ddf7 iss_v2: deliver div operand values via event hook`
- `e8cb98df iss_v2: deliver decoder latency via event hook`

The iss_v2 LSU now annotates *why* the core stalled (e.g. "waiting on bus", "RAW", "div latency") and emits one event per bus transaction. Combined with our cache trace, this lets a downstream analysis tool say "for this run, N% of cycles were stalled on cache, M% on RAW, …".

**Action for InSitu**: not blocking, but useful for the Phase-6 validation report. If we get into "the cycle counts disagree by 8%; where?", these per-event hooks tell us whether the gap is in our cache model or in the ISS pipeline.

### 2.8 Waveform dumper — `9401e487` + `abf256c8`

**Files:** `core/models/utils/fst_dumper.{cpp,py}`, `core/models/utils/fsdb_dumper.{cpp,py}`

GTKWave FST and Verdi FSDB exporters for the existing GVSoC trace channels. Plug into the gen_gui pipeline.

**Action for InSitu**: makes it possible to side-by-side view a GVSoC trace and an RTL VCD for the same workload — useful when chasing the last few % of cycle-count drift. Not a P1 but worth knowing about.

### 2.9 Interleaver fixes — `c376bec4` + `91a46d6e`

- `c376bec4 interleaver: fix incorrect latency calculation`
- `91a46d6e interleaver: fix output selection when enable_shift is on`

These are in `core/models/interco/interleaver_impl.cpp` — the file we used as a pattern when writing `insitu_cache_interco.cpp` (see `prompt/insitu_vs_existing_cache_comparison.md` §2.3).

**Action for InSitu**: read the diffs to see if either bug also exists in our interco. Quick check: our interco doesn't have `enable_shift`, so `91a46d6e` doesn't apply. The latency-calc fix (`c376bec4`) — we should diff it against our interco logic and confirm we don't have the same bug.

### 2.10 Limiter improvement — `0ecb8e74 limiter: defer resp to the latest sub-request's completion cycle`

**File:** `core/models/interco/limiter.cpp`

If a single user request is internally split into multiple sub-requests, the response now waits for the LATEST sub-request's completion, not the first.

**Action for InSitu**: if we eventually put a `limiter` in front of the L2 to model AXI bandwidth, this fix matters. For now, our L2 fan-in is unlimited; phase-7 candidate.

### 2.11 idma_v2 cycle-accurate beat-streaming

**Files:** `pulp/models/pulp/ips/pulp/idma_v2/*`

The iDMA model gained a cycle-accurate beat-streaming variant. Currently DMA bypasses our cache (per RTL, see `pulp/pulp/snitch/snitch_cluster/snitch_cluster.py` — `idma.o_TCDM(tcdm.i_DMA_INPUT())`).

**Action for InSitu**: no immediate change. But if/when we want to model DMA traffic competing with the cache on the L2 port (refill backpressure when DMA is running), idma_v2 is the right backend to use.

### 2.12 Things we explicitly ignore

| Item | Reason |
|---|---|
| RI5CY core (`Ri5ky*` commits in core and pulp) | Different RISC-V implementation; the Spatz path doesn't use it. |
| SpatzMempool, Magia, Siracusa, pulp-open updates | Different chips/SoCs from the CachePool target. |
| FlooNoC v2 | Cluster-NoC, not cache-relevant unless we go multi-tile. |
| pcie_vfio_bridge | Host-to-target bridge, unrelated. |
| Datamover (MAGIA) | Vector data-mover IP, separate from cache. |

## 3. Proposed action list (ordered)

1. **Phase-6 unblock** (P1): port `pulp/insitu_cache_tb.py` to use `GeneratorV2` instead of a RV32 host. Add a small set of patterns mirroring the RTL tests (cold read, hit stream, random read, write-then-read). Emit `[CALIB_REPORT]`-style output. This gives us the first numerical RTL↔GVSoC comparison in <10 min wall-clock.

2. **Calibration test corpus** (P1): port `pulp/tests/ri5ky_testbench/calibration/`'s pattern to a `pulp/tests/insitu_cache/` directory. Each test is single-core inline-asm doing a known cache pattern + `CALIB_REPORT`. Run on both RTL (the existing `cachepool_cluster.vsim`) and GVSoC.

3. **Interleaver bug-check** (P3): diff `c376bec4` against `insitu_cache_interco.cpp::req_handler`; confirm we don't have the same latency-calc bug.

4. **(Optional, future)** **io_v2 migration** (P2): convert `InsituCacheController` / `InsituCacheCoalescer` / `InsituCacheInterco` / `InsituCacheTile` to io_v2 signatures. Replace the L2 fan-in router with `Router_v2(kind=KIND_BEAT)`. Drop the `set_duration(beats)` placeholders in favor of per-beat resp() responses from a memory_v3 backend. Reference: `cache_v4.cpp`'s diffs vs `cache_v3.cpp`.

5. **(Optional, future)** **Per-event stall attribution** (P3): when the validation report needs to explain a cycle gap, wire iss_v2's stall-reason events into a post-run summary that says "N% of cycles stalled on cache, M% on RAW, K% on div".

## 4. What's NOT in the upstream that would matter

To be explicit about gaps that the upstream rebase did *not* fill:

- **No counter-format convention** for cache hit/miss/coalescer counts that matches the RTL's `$display` output. Phase-6 still needs both sides to print counters in a `diff`-able format.
- **No reference cycle baselines** for the InSitu cache itself in the upstream. The calibration tests target RI5CY; we have to write our own for the cache.
- **No improvement to the multi-core barrier handling** in `cluster_registers`. CachePool binaries still spend cycles waiting on barriers between cores when running on GVSoC — the `wait(eoc); $finish` trigger we added gets the simulation to exit, but doesn't speed up the warm-up phase.

## 5. References

- `prompt/insitu_cache_gvsoc_plan.md` §7 — Phase-6 plan items
- `prompt/insitu_cache_validation_report.md` §7 — pending validation next steps
- `prompt/insitu_vs_existing_cache_comparison.md` §3 — InSitu vs cache_v3 reuse pattern (cache_v4 mostly reaffirms this)
- `core/models/cache/cache_v4.{cpp,py}` — reference for io_v2 port (P1 in §3)
- `pulp/tests/ri5ky_testbench/calibration/load_use/test.c` — reference for calibration test format (P1 in §3)
- `core/models/interco/traffic/generator_v2.{cpp,py}` — reference for traffic-gen-based microbenchmark harness (P1 in §3)
