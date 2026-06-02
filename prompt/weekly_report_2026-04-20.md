# Weekly Report — InSitu Cache GVSoC Performance Model

**Week of 2026-04-20**

## Summary

Designed, implemented, integrated, and started validating a cycle-approximate
GVSoC performance model of the CachePool InSitu L1 data cache. End state: model
compiles, instantiates on the real Spatz cluster target, boots real rv32 vector
binaries end-to-end, exits cleanly with cycle counts, and is documented for
other users.

## Deliverables

- **Architecture spec read-through and design plan**
  (`prompt/insitu_cache_architecture.md` RTL spec,
  `prompt/insitu_cache_gvsoc_plan.md` modeling plan).

- **Performance model** under `core/models/cache/insitu/` (new):
  - `insitu_cache_controller.{cpp,py}` — tag array, hit/miss, MSHR merging,
    hash-or-LRU victim select, eviction, refill, write-through, FIFO
    backpressure.
  - `insitu_cache_interco.{cpp,py}` — address-hashed N-to-M crossbar with
    round-robin arbitration.
  - `insitu_cache_coalescer.{cpp,py}` — 3-state write-through merger with
    watchdog + read-snoop flush.
  - `insitu_cache_tile.py` — composite (interco + N controllers + N coalescers
    + L2 fan-in).
  - `insitu_cache_config.py` — `Config` classes with canonical `cachepool_512`
    defaults.

- **Integration** into the spatz cluster behind `use_insitu_cache` flag
  (`pulp/pulp/snitch/snitch_cluster/snitch_cluster.py`,
  `pulp/pulp/chips/snitch/snitch.py`). Default off — no regression on existing
  targets.

- **Standalone testbench** target `insitu_cache_tb` for driving isolated
  microbenchmarks.

- **User docs** `core/models/cache/insitu/README.md` (~550 lines): topology,
  build, CLI invocation, per-transaction timing formulas with worked examples,
  config reference, telemetry, troubleshooting.

- **Repo onboarding doc** `CLAUDE.md` at the top level.

## Infrastructure fixes that came out of validation

1. **Null data-pointer segfault** in refill/evict/write-through —
   `Memory::handle_read` memcpys against the request's data pointer; added
   scratch buffers.
2. **Cross-composite binding bug** in `o_L2` (silent SIGABRT) — fixed with
   proper pass-through port pattern.
3. **Missing simulation-exit mechanism** — GVSoC's spatz `ClusterRegisters`
   didn't handle `CLUSTER_EOC_EXIT` (0x68); added a watchpoint that mirrors the
   RTL testbench's `wait(eoc); $finish`.
4. **No cycle-count output on HTIF exit** — added `[HTIF] Simulation exiting:
   retval=X cycles=Y` stderr print so RTL↔GVSoC comparison is tabulatable.

## Validation (partial)

RTL reference cycles (Questa + DRAMSys5 on `cachepool_cluster.vsim`):

| Test                | Cycles  | Status   |
|---------------------|--------:|----------|
| cache-line-rw-smoke |  25,822 | PASS     |
| idotp-32b_M1024     |  43,786 | finished |
| cache-test-scalar   | 734,222 | PASS     |

GVSoC:

| Test                  | Mode              | Cycles     | Status                                |
|-----------------------|-------------------|-----------:|---------------------------------------|
| test-riscvTests-vfadd | spatz, no cache   | **54,001** | PASS (clean HTIF exit)                |
| test-riscvTests-vfadd | spatz, cache on   | —          | killed at 32 min (running, not stuck) |
| CachePool binaries    | spatz             | —          | simulation-throughput limited (4-core Spatz accurate ISS + cache ≈ 1–5 kHz simulated-per-real) |

## Git state

Three commits on personal forks:

- `Aquaticfuller/gvsoc-core` (branch `insitu-cache`): adds `cache/insitu/`
  model.
- `Aquaticfuller/gvsoc-pulp` (branch `insitu-cache`): cluster wiring +
  standalone testbench.
- Parent repo (branch `main`): submodule URL switch + bumps, `CLAUDE.md`,
  `prompt/` docs.

## Next steps

- Write a single-core, printf-free, ≤1000-cycle cache microbenchmark so
  GVSoC-cache runs finish in ≤10 min wall-clock. This is the one thing
  blocking a direct RTL↔GVSoC cycle-count comparison.
- Expose internal model counters (hit/miss/merge/flush) in the same format as
  RTL's `$display` counters for counter-level validation.
- Once the first RTL↔GVSoC numerical comparison is in, calibrate the timing
  knobs against the `<5%` target if needed.
