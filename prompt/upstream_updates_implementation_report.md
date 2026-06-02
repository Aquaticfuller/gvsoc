# InSitu Cache — Upstream-Update Implementation Report

> Implements the P1 actions from `prompt/upstream_updates_review.md`.
> Date: 2026-04-21.

## 1. TL;DR

| Action (from review §3) | Status | Outcome |
|---|---|---|
| P1.1 — Microbench driver using v1 traffic generator | **DONE** | `make all TARGETS=insitu_cache_microbench` produces a target that sequences 7 known cache patterns and emits `[CALIB_REPORT]` cycle counts. Sub-1-second wall-clock per pattern. |
| P1.2 — Calibration test pattern (RTL-comparable) | **partial** | `[CALIB_REPORT name=... cycles=N]` output format is in place; pattern set encodes streaming/repeat reads + writes; an RTL companion harness still needs to be built. |
| P1.3 — Interleaver bug-check (`c376bec4`) | **DONE** | Our interco uses `inc_latency` (additive). Upstream bug was `set_latency` (max-only). Not affected. |
| P2 — io_v2 migration of cache components | not yet | Reference (`cache_v4`) and proposed steps documented in §6 below. |

## 2. What was built

### 2.1 `insitu_cache_microbench` target

**Files added:**

- `pulp/insitu_cache_microbench/__init__.py` — top-level target module
  (`gvsoc.runner.Target` subclass). Picks up by `--target=insitu_cache_microbench`.
- `pulp/insitu_cache_microbench/driver.py` — Python wrapper for the C++
  sequencer.
- `pulp/insitu_cache_microbench/driver.cpp` — sequences a list of patterns
  through the v1 `Generator`, prints `[CALIB_REPORT]` per pattern, calls
  `engine->quit(0)` when done.

**Topology:**

```
[InsituCacheMicrobenchDriver] --o_GEN_CTRL--> [Generator.i_CONTROL]
                                                       |
                                                   o_OUTPUT
                                                       |
                                                       v
                                             [InsituCacheTile.i_INPUT(0)]
                                                       |
                                                     o_L2
                                                       |
                                                       v
                                                  [memory.Memory l2]
```

**Why this is significant for Phase-6 validation.** The CachePool 4-core
Spatz boot path that blocked us at the validation report's §3.2 is gone:
no ISS, no barriers, no printf — just the `Generator` issuing
configurable io_v1 traffic into the cache, and the driver collecting
cycle counts via `TrafficGeneratorSync`. Each pattern completes in tens
to hundreds of simulated cycles and well under a second of wall-clock.

### 2.2 Pattern set (default)

In `__init__.py:DEFAULT_PATTERNS`, encoding canonical cache behaviours:

| Name | bytes | packet | wr | What it exercises |
|---|---:|---:|---:|---|
| `warmup` | 64 | 4 | 0 | First-ever access — 1 line of compulsory miss + 15 hits |
| `cold_stream_r4` | 256 | 4 | 0 | 4 compulsory misses + 60 hits |
| `hit_repeat_r4` | 256 | 4 | 0 | Re-read same 4 lines — 64 hits |
| `cold_stream_r16` | 1024 | 4 | 0 | 16 compulsory misses + 240 hits |
| `cold_stream_w4` | 256 | 4 | 1 | 4 write misses + 60 write hits, coalescer-driven WT |
| `hit_repeat_w4` | 256 | 4 | 1 | Repeat writes to warmed lines |
| `stream_w_newrgn` | 256 | 4 | 1 | Coalescer tag-change flush + new burst |

Edit `DEFAULT_PATTERNS` to add more, or call `get_patterns("preset")`
once additional presets are added.

## 3. First measured GVSoC cycle counts

End-to-end, on `cachepool_512` defaults
(64 B line, 4 ways, 128 sets, 4 controllers, `hit_latency=4`,
`refill_bank_write=2`, `refill_beat_bytes=16`, L2 = `Memory(latency=20)`):

```
[CALIB_REPORT] name='warmup'           packets=16  bytes=64    wr=0 cycles=46    cycles_per_packet=2.88
[CALIB_REPORT] name='cold_stream_r4'   packets=64  bytes=256   wr=0 cycles=175   cycles_per_packet=2.73
[CALIB_REPORT] name='hit_repeat_r4'    packets=64  bytes=256   wr=0 cycles=83    cycles_per_packet=1.30
[CALIB_REPORT] name='cold_stream_r16'  packets=256 bytes=1024  wr=0 cycles=691   cycles_per_packet=2.70
[CALIB_REPORT] name='cold_stream_w4'   packets=64  bytes=256   wr=1 cycles=175   cycles_per_packet=2.73
[CALIB_REPORT] name='hit_repeat_w4'    packets=64  bytes=256   wr=1 cycles=83    cycles_per_packet=1.30
[CALIB_REPORT] name='stream_w_newrgn'  packets=64  bytes=256   wr=1 cycles=175   cycles_per_packet=2.73
```

### 3.1 What these numbers mean

- **Hit throughput ≈ 1.3 cycles/packet** (`hit_repeat_r4`). With 4 outstanding
  requests from the generator (`nb_pending_reqs=4`) and a 4-cycle pipelined
  hit latency, steady-state hit throughput approaches 1 packet/cycle but
  pays a small overhead from the per-set bank-busy serialization
  (see `core/models/cache/insitu/README.md` §4.3).

- **Cold streaming ≈ 2.7 cycles/packet** (`cold_stream_r4/r16`,
  `cold_stream_w4/stream_w_newrgn`). Comprises 16 packets per line × 4 lines
  = 64 packets, of which 4 are compulsory misses (full L2 round-trip) and
  60 are hits. Linearly, `175 cycles / 64 packets ≈ 2.7 c/p` — matches the
  closed-form expectation `(4 × miss_cycles + 60 × hit_cycles) / 64`
  with miss_cycles ≈ 24 (L2 latency 20 + refill_bank_write 2 + some pipeline)
  and hit_cycles ≈ 1.3.

- **Reads vs. writes show identical critical-path cycles**
  (`cold_stream_r4` 175 = `cold_stream_w4` 175). Confirms the cache's write-
  through coalescer is off the user's critical path (§4.3 of the user doc):
  writes ack with +1 cycle latency on the cache side and the wide flush
  happens asynchronously to L2.

- **Linearity check:** `cold_stream_r16` (256 packets, 16 misses) = 691
  cycles. Predicted from r4: `175 × 4 = 700`. Measured 691. The 9-cycle
  underrun reflects pipelining of misses across the 16 cache lines (not
  serial as in the back-to-back r4 case).

These results are **internally consistent with the model's documented
timing formulas**. They are *not yet* validated against RTL — that step
needs an RTL-side counterpart that runs the same access patterns (see §5).

## 4. Bugs / surprises encountered during implementation

### 4.1 Address-mapping mismatch (microbench → memory)

**Symptom.** With `CACHED_BASE = 0x1000_0000` and a 256 KB memory backing,
the Memory model rejected refill requests with `Received out-of-bound
request (reqAddr: 0x10000000, memSize: 0x40000)`. The cache then never
got its refill response and the simulation hung forever waiting for the
generator's first packet to return.

**Root cause.** `memory.Memory(size=X)` only accepts addresses in
`[0, X)`. We were dropping into the memory with absolute addresses
above its range.

**Fix.** `CACHED_BASE = 0x0000_0000`. The cache is address-agnostic
(set/tag derived from whichever bits), so 0-based addressing changes
nothing about cache behavior, and avoids the need for an intermediate
remapping router. Documented in the target's source comment.

### 4.2 Submodule version skew after rebase

The rebase from `prompt/rebase_dev_branches_runbook.md` pulled in core +
pulp upstream master, but the `engine` and `gvrun` submodules were left
at older commits. The upstream `core/master` includes commits like
`458211be models: include per-module config headers` which expect the
gvrun config-gen layout from `a54a725 config_gen: use full module path
for header layout`, and `c376bec4 interleaver: fix incorrect latency
calculation` which uses an `IoReq::set_exact_latency` API only present
in upstream engine `9a5365bf io: add set_exact_latency to override
latency unconditionally`.

**Fix.** Bumped both `engine` (23523e72 → a8c57439) and `gvrun`
(beac7e2 → 79eba86) to their upstream `main` HEADs. Committed under
`8187b1a... → 2518ce2 submodules: bump engine and gvrun to upstream main`
in the parent repo.

**Follow-on for the runbook.** `scripts/rebase_dev_branches.sh` only
handles `core` and `pulp` (the forked submodules with `insitu-cache`
branches). Next time someone runs it, they should ALSO bump `engine`
and `gvrun` afterwards, or extend the script to do it. The script
currently does not because those submodules aren't forks and don't
have personal dev branches.

### 4.3 v1 Generator's arg-stack collides with cache save/restore?

The v1 `Generator` pushes 4 args onto the `IoReq`'s arg stack before
issuing the request (`generator.cpp:342-345`). Our cache controller
calls `req->save()` on miss, which also pushes 4 args (per the io.hpp
contract). After cache restore (4 pops) the generator's 4 args remain
on top of the stack — fine.

The key invariant is that **the cache must `save()` and `restore()` in
balanced pairs** before passing the request back to the generator via
`resp_port->resp(req)`. Our `fsm_drain_mshr` does this correctly. No
change needed.

## 5. What's still needed for full RTL↔GVSoC validation

The microbench gives us numerical GVSoC cycle counts in seconds.
Comparable RTL numbers are still missing because the RTL CachePool
testbench runs C binaries — there is no equivalent "synthetic stimulus"
input to the RTL.

### 5.1 Option A — RTL-side calibration C programs

Port the `ri5ky_testbench/calibration/` pattern from upstream pulp
(`75d0d44 Add ri5ky_testbench target and calibration suite`) to a new
`software/tests/cache_calibration/` corpus that runs identical access
patterns to the microbench's `DEFAULT_PATTERNS` on the RTL cluster.
Each test:

```c
calib_pccr_reset();
uint32_t start = calib_cycles();
__asm__ volatile (
    // streaming read of N words from buf
    "lw t0, 0(a0)\n"
    "lw t0, 4(a0)\n"
    ...
);
uint32_t end = calib_cycles();
printf("[CALIB_REPORT] name='cold_stream_r4' cycles=%u\n", end - start);
```

Then `diff` the GVSoC microbench output against the RTL run. Goal: ≤5%
cycle-count error.

### 5.2 Option B — Generator-driven RTL stimulus

Drive the RTL cluster's TCDM ports with the same kind of synthetic
stimulus using a SystemVerilog testbench. Higher fidelity, more setup
effort.

Option A is the straightforward next step. The microbench output format
(`[CALIB_REPORT] name=... cycles=N`) is already the diff-able format.

## 6. P2 backlog (carried forward from review §3)

Not yet implemented; documented here for reference:

1. **io_v2 migration of `InsituCacheController` / `InsituCacheCoalescer` /
   `InsituCacheInterco`.** Reference template: `core/models/cache/cache_v4.cpp`.
   Concretely: change `signature='io'` → `signature='io_v2'` on the
   controller's `i_INPUT` / `o_REFILL` ports; in C++, on the refill
   response handler, guard the completion logic with `if (!req->is_last)
   return;`. This lets us drop `set_duration(beats)` and let the auto-
   inserted `BeatResponseAdapter` (engine, commit `9a5365bf`+) emit
   per-beat responses naturally.

2. **Router_v2(KIND_BEAT) on the cache's L2 fan-in.** Once the cache is on
   io_v2, replace `core/models/cache/insitu/insitu_cache_tile.py`'s
   internal L2 path with a `Router_v2(kind=KIND_BEAT)` to get cycle-
   accurate beat pacing.

3. **memory_v3 on the L2 side.** Replace `memory.Memory` with
   `memory.memory_v3.Memory` in the microbench once the cache is io_v2.
   Both `memory_v3` and the v2 router emit per-beat responses; the
   adapter chain becomes automatic.

4. **Per-event stall attribution** (iss_v2 `9a435ffa` + `3bbe1b0f`).
   Useful when the eventual RTL↔GVSoC cycle gap needs to be attributed
   between cache modeling and ISS pipeline modeling.

## 7. Build invocation

```bash
# From the parent repo root:
PATH=/tmp/py312_shims:$PATH CXX=g++-14.2.0 CC=gcc-14.2.0 CMAKE=cmake-3.18.1 \
    make all TARGETS=insitu_cache_microbench

# Run:
PATH=/tmp/py312_shims:install/bin:$PATH \
    PYTHONPATH=install/python:$PYTHONPATH \
    gvsoc --target=insitu_cache_microbench run
```

Wall-clock to completion: well under 1 second on this host.

## 8. Files added / modified this round

```
Added:
  pulp/insitu_cache_microbench/__init__.py
  pulp/insitu_cache_microbench/driver.py
  pulp/insitu_cache_microbench/driver.cpp

Modified (parent repo, submodule bumps):
  engine submodule:  23523e72 -> a8c57439  (upstream main)
  gvrun  submodule:  beac7e2  -> 79eba86   (upstream main)
```

The `core` and `pulp` submodules are untouched (no edits to the
insitu-cache branches' tip commits). The microbench lives in `pulp/`
because that's the natural place for a `Target` definition — but it
doesn't touch any other pulp file.

## 9. References

- `prompt/upstream_updates_review.md` — original prioritized list.
- `prompt/insitu_cache_validation_report.md` — Phase-6 context this work
  unblocks.
- `core/models/cache/insitu/README.md` §4 — timing formulas the
  microbench results check against.
- `core/models/interco/traffic/generator.{hpp,cpp,py}` — v1 traffic
  generator that we drive.
- `pulp/tests/ri5ky_testbench/calibration/load_use/test.c` —
  reference RTL calibration template (P1.2 next step).
- `core/models/cache/cache_v4.{cpp,py}` — reference for the (deferred)
  io_v2 migration of the InSitu cache (P2.1 next step).
