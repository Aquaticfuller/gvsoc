# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

This repo is a top-level "SDK" that aggregates several git submodules into a single buildable simulator. The submodules (per `.gitmodules`) are:

- `engine/` — core C++ simulation engine (`gvsoc-engine`). Also ships the `gvsoc` / `gvconsole` / `gvcontrol` / `gvsoc-itf-gen` / `regmap-gen` CLIs under `engine/bin/`, and the Python side (`engine/python/gvsoc/`: `systree.py`, `runner.py`, etc.) that defines the component/binding API.
- `core/` — generic hardware models (`gvsoc-core`). `core/models/` holds CPU ISS (`cpu/iss`, `cpu/iss_v2`), memory (incl. `dramsys.{cpp,py}`), interconnect (`interco/`), devices, caches, GDB server.
- `pulp/` — PULP-platform chip/IP models and target entry points (`gvsoc-pulp`). Top-level files like `pulp-open.py`, `rv64.py`, `snitch.py`, `spatz.py`, `ara.py` are *target* definitions; `pulp/pulp/chips/*` contain the board/SoC compositions; `pulp/pulp/<ip>/` contains individual IP models (cluster, redmule, ne16, idma, …).
- `gvrun/` — newer Python-based runner (`gvrun` / `plprun` CLIs). Layered on top of `gvsoc` via `--platform=gvsoc`.
- `gapy/` — packaging / flash-image / debug-info tooling (`gapy`, `gen-debug-info`).
- `gvtest/` — Python test framework (`gvtest` CLI). See `gvtest/SPECIFICATIONS.md` — configuration is hierarchical via `gvtest.yaml` merged from testset dir up to FS root; `python_paths` are only on `sys.path` during `testset_build()`.
- `config_tree/` — Python module for describing/accessing the hierarchical system configuration.
- `pulpos/` — PULP-OS runtime used by some tests.

The repo's own `core/CMakeLists.txt` is empty (0 bytes) before `git submodule update` — if a clean-looking tree appears empty, the submodules likely aren't checked out.

The `core` and `pulp` submodules are pointed at the user's forks
(`Aquaticfuller/gvsoc-core` and `Aquaticfuller/gvsoc-pulp`). Both forks use
`master` as the default branch and have a long-lived `insitu-cache` dev
branch. **When the user asks to "rebase the dev branches", "pull from
upstream/main", or "update from main", see `prompt/rebase_dev_branches_runbook.md`
and use `scripts/rebase_dev_branches.sh`** — that script captures the safe
procedure (recovery SHAs, dirty-tree handling, conflict-abort, force-with-
lease push, parent submodule-pointer bump).

## Build system

Top-level `Makefile` wraps CMake. The main build flow:

1. `make checkout` → `git submodule update --recursive --init`.
2. `make build` (default target via `make all`) first builds & installs `gvrun` and `config_tree` (`gvrun.build`), then invokes a single CMake configure at repo root that wires together the engine, core, gapy, gvtest, gvrun, pulpos, and config_tree via `add_subdirectory` (`CMakeLists.txt:1-17`).

Key CMake variables passed by `make build` (Makefile:71-80):

- `GVSOC_MODULES` — semicolon-separated list of Python package roots to install. Default: `engine/python;core/models;pulp;pulp/targets;gvrun/python;config_tree`. Append extra target roots via `MODULES=...` on the make command line.
- `GVSOC_TARGETS` — whitespace-separated list of targets to compile. Defaults live in `Makefile:6-25` and include e.g. `rv64`, `pulp-open`, `pulp-open-nn`, `pulp.spatz.spatz`, `snitch`, `snitch:core_type=fast`, `ara`, `spatz`, `siracusa`, `chimera`, `mempool`. A target can take `key=value` suffixes (e.g. `pulp-open:chip/cluster/redmule=True`).
- `BUILDDIR` / `INSTALLDIR` — default to `./build` and `./install`, or `$GVSOC_WORKDIR/{build,install}` if `GVSOC_WORKDIR` is set.
- `DEBUG=1` flips the build type from `Release` to `RelWithDebInfo`.

Common invocations:

```bash
# Full build for a specific target
make all TARGETS=pulp-open

# ETH cluster: pin toolchain versions (see README.md)
CXX=g++-14.2.0 CC=gcc-14.2.0 CMAKE=cmake-3.18.1 make all TARGETS=pulp-open

# Debug build
make all TARGETS=pulp-open DEBUG=1

# Clean: removes $BUILDDIR and $INSTALLDIR
make clean

# Build docs (user + developer manuals from core/)
make doc
```

`ccache` is auto-detected and enabled when present (`CMakeLists.txt:5-9`).

## Environment

After installing, `source sourceme.sh` puts `install/bin` on `PATH` and `install/python` on `PYTHONPATH`. It also prepends `third_party/DRAMSys` to `LD_LIBRARY_PATH` (harmless if unused). When `GVSOC_WORKDIR` is set, `sourceme.sh` sources from `$GVSOC_WORKDIR/install` instead of the in-tree `install/` — keep it consistent with the make invocation. `gapy/bin` is already on `PATH` during `make build` itself (`Makefile:43`).

## Running a simulation

Two frontends exist:

- Classic: `gvsoc --target=<name> --binary <elf> image flash run` (see `README.md:65-67`, `examples/pulp-open/testset.cfg`).
- New runner: `gvrun` / `plprun` — shell wrapper in `gvrun/bin/gvrun` sets `USE_GVRUN=1`/`USE_GVRUN2=1` and dispatches to the `gvrun` Python module with `--platform=gvsoc --target-dir=install/targets --target-dir=install/generators --model-dir=$GVRUN_MODEL_PATH` (defaults to `install/models`).

Examples live under `examples/<target>/` and each has a `testset.cfg` + `gvtest.yaml`. Example binary for DDR experiments: `gvsoc --target=pulp-open-ddr --binary <bin> image flash run --trace=ddr`.

## Testing

`gvtest` is the test driver. Top-level `testset.cfg` imports subsets from `core/tests`, `core/docs/developer_manual/tutorials`, `tests/`, `examples/`.

- `make test` runs `test.build` (fetches/builds external SDKs) then `GVTEST_CMD`.
- `make test.run` skips the build and just runs tests.
- `make github.test` runs the lightweight CI set from `testset-github.cfg` with a 120s per-test timeout.
- Target narrowing: pass `TEST_TARGETS="pulp-open rv64"` — this expands into `--target` flags for `gvtest` (`test.mk:5-6`).
- Extra gvtest options: `GVTEST_OPT="..."`; global per-test cap: `TIMEOUT=<seconds>`.

Single-test selection uses gvtest filters rather than a separate harness — invoke `gvtest` directly against a leaf `testset.cfg` or use gvtest's filter/selector args (see `gvtest/SPECIFICATIONS.md`).

Per-subsystem test fixtures live under `tests/` and are bootstrapped by `test.mk`'s `test.checkout.*` / `test.build.*` targets (riscv-tests, pulp-sdk, pulp-sdk-siracusa, chimera-sdk, snitch, spatz, ara, magia, pulp-nn, mempool). Each target has pinned commit SHAs in `test.mk`; don't bump these casually — they're part of the CI contract.

Some external-toolchain tests require env vars to point at cross toolchains: `CHIMERA_LLVM`, `LLVM_BINROOT`, `SPATZ_LLVM`, `SPATZ_GCC`, `VSIM_HOME`, `RISCV_GCC`, `ARA_LLVM`, `MAGIA_GCC_TOOLCHAIN` (`test.mk:83, 108, 132, 151, 172`).

## DRAMSys integration

DRAMSys is optional. One-shot setup: `source dramsys_pushbutton_ETHenv.sh` (ETH cluster) or `source dramsys_pushbutton.sh` (elsewhere — needs GCC ≥ 11.2, CMake ≥ 3.18.1). Under the hood (`Makefile:108-156`) this builds SystemC 3.0.1 into `third_party/systemc_install/`, installs the prebuilt `libDRAMSys_Simulator.so` (rebuilding from source if the self-test fails, ~40 min), and copies DRAM configs into `core/models/memory/dramsys_configs/`. DRAM model selection is in `core/models/memory/dramsys.py` (`dram-type`: `ddr3` | `ddr4` | `hbm2` | `lpddr4`); see `DRAMSys.md` for a fuller walkthrough including how to port the integration onto another GVSoC branch.

## InSitu cache performance model

A cycle-approximate GVSoC model of the CachePool InSitu L1 data cache lives in
`core/models/cache/insitu/`. **Full user-facing documentation:
[`core/models/cache/insitu/README.md`](core/models/cache/insitu/README.md).**

**Architecture-spec docs** (in `prompt/`):
- `insitu_cache_architecture_v2.md` — **current** RTL (rebased tree at
  `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/working_dir/insitu-cache/`).
  Single wide cache + N→1 coalescer, partition-flushable wrapper, three coalescer
  styles. **Read this first.**
- `insitu_cache_architecture.md` — legacy v1 RTL (4-controller + interco) that the
  initial GVSoC model was built against. Retained for the per-line-state-machine /
  FSM-state details that still apply.

### Tracking new RTL revisions (procedure)

When the user says "the RTL has updated, please update our model" or equivalent:

1. **Re-read the RTL** under `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/working_dir/insitu-cache/`
   (or the rebased tree they point at). Files of interest in priority order:
   - `src/insitu_cache/insitu_cache_top.sv` (parameters, port list)
   - `src/insitu_cache/insitu_cache_pkg.sv` (line states, types)
   - `src/cachepool/cachepool_cache_ctrl.sv` (per-SoC controller — the integration
     point; parameter defaults here matter more than the cache_top defaults)
   - `src/insitu_cache/insitu_cache_tcdm_wrapper.sv` and the
     `_partitionable_flushable.sv` variant (SPM + flush mechanism)
   - `src/coalesce_unit/par_coalescer/par_coalescer_top.sv` (the new coalescer)
   - `src/insitu_cache/insitu_cache_decoder.sv` and `_encoder.sv` (hit/miss logic
     and LRU/state transitions)
2. **Don't modify** anything under that tree — it's read-only RTL reference.
3. **Update `prompt/insitu_cache_architecture_v2.md`** with: any new parameter
   defaults, new module additions, new control signals (`cache_sync_insn`,
   `bank_depth_for_SPM`, etc.), new latency knobs. The §0 delta table is the
   most important section to keep current.
4. **Update `core/models/cache/insitu/insitu_cache_config.py`** to mirror new
   knobs. Default values should track the latest CachePool ctrl defaults (not
   the cache_top defaults, which are different).
5. **Wire the C++ side** in `insitu_cache_controller.cpp`: read the new
   properties via `get_js_config()->get_child_*`, gate behaviour appropriately
   (e.g. `if (write_through_mode_) issue_write_through(req);`). Phase A can
   keep these as simple gates; full-topology refactors go to Phase B.
6. **Regression smoke**:
   `make all TARGETS="insitu_cache_microbench spatz:use_insitu_cache=True insitu_cache_tb"`
   then run `gvsoc --target=insitu_cache_microbench run` and confirm the 7
   `[CALIB_REPORT]` lines change in expected directions (e.g. flipping defaults
   should change cycle counts by small predictable deltas).
7. **Document the round** in a follow-up report under `prompt/` (see
   `upstream_updates_implementation_report.md` as a template).

The RTL location and the GVSoC repo location are tracked in
`~/.claude/projects/.../memory/rtl_readonly.md`.

### Summary of the model:

- `insitu_cache_controller.{cpp,py}` — one cache controller (tag array, MSHR, hit/miss,
  hash-or-LRU victim selection, eviction, refill, write-through hook).
- `insitu_cache_interco.{cpp,py}` — hashed N-to-M crossbar mapping TCDM ports to
  controllers on address bits `[dynamic_offset +: log2(num_outputs)]`.
- `insitu_cache_coalescer.{cpp,py}` — 3-state FSM write-through merger with configurable
  watchdog (RTL §10).
- `insitu_cache_tile.py` — composite component assembling N controllers + N coalescers +
  1 interco + a fan-in `l2_router` on the L2 output side.
- `insitu_cache_config.py` — `InsituCacheControllerConfig`, `InsituCacheCoalescerConfig`,
  `InsituCacheIntercoConfig` (all `config_tree.Config` subclasses), plus a plain-Python
  `InsituCacheTileConfig` bundling them. `make_cachepool_512_config()` returns the
  canonical 1-tile / 4-core / 4-way / 128-set / 512b-line / hash-way configuration from
  `prompt/insitu_cache_architecture.md §1.3`.

**Enabling on the spatz cluster.** `ClusterArch` in
`pulp/pulp/snitch/snitch_cluster/snitch_cluster.py` takes `use_insitu_cache=False`
(default → no behavior change) / `True`. `SnitchArchProperties` in
`pulp/pulp/chips/snitch/snitch.py` exposes it as a user property:

```bash
gvsoc --target=spatz --target-property use_insitu_cache=True --binary <elf> run
```

The cache sits between `cores_ico[core_id]` / `o_VLSU(lane)` and the TCDM. Its L2
fan-in goes to the cluster's `wide_axi`, which already routes TCDM-range addresses to
`tcdm.i_DMA_INPUT()` — so by default the cache refills from the existing SPM. Pointing
the cache at DDR instead is a matter of configuring `wide_axi`'s map to route
cache-range refills elsewhere.

**Design notes** (see `prompt/insitu_cache_gvsoc_plan.md` for the full plan):
- The model is cycle-approximate (<5% target), not cycle-exact.
- `IoReq::get_args()` is **shared** with `save()`/`restore()` (save pushes 4 slots onto
  the arg stack starting at `current_arg`). Don't co-use slots without offsetting past
  what `save()` wrote. The controller works around this by keeping per-request context
  in a side-deque (`MshrEntry`) rather than scratch args.
- The refill response matches pending lines by re-decoding address → set/tag and
  scanning for the `READ_PEND` / `WRITE_PEND` way. Simpler than per-refill scratch.
- `std::vector<bool>` uses proxy iterators — `for (auto &v : vec)` can't bind to a real
  `bool &`. Assign by index when iterating.

**Standalone testbench.** `pulp/insitu_cache_tb.py` brings up a minimal SoC (one RV32
scalar host → single `InsituCacheTile` → memory) for driving focused microbenchmarks
without the full Spatz cluster. Build via `make all TARGETS=insitu_cache_tb`.

**Build environment.** The GVSoC Python code (including `config_tree`) requires
Python ≥ 3.10 for `str | None` syntax. If the default `python3` is 3.9, shim it:
`ln -sf /usr/bin/python3.12 /tmp/py312_shims/python3 && PATH=/tmp/py312_shims:$PATH make …`.
Needed pip packages for Python 3.12: `typing_extensions prettytable rich pexpect
pycryptodome ppk2_api pyelftools psutil lz4 setuptools<81 numpy pandas matplotlib mako
hjson jsonref`.

**elfutils headers (since the 2026-06 upstream pull).** Upstream's ISS now resolves trace
PC→symbol at runtime via libdw (`core/models/cpu/iss*/src/trace.cpp` includes
`<elfutils/libdwfl.h>`; `riscv.py` calls `add_libraries(['dw','elf'])`, which needs engine
`Component.add_libraries()` — engine ≥ `a3d410b4`, i.e. the bumped engine pointer). The ETH
cluster ships the runtime libs (`libdw.so.1`/`libelf.so.1`) but **not** `elfutils-devel`, and
there's no passwordless sudo. Provide the headers + the missing `libdw.so` link symlink
**without sudo** via `scripts/setup_elfutils_headers.sh` (dnf-downloads the matching
`elfutils-devel` RPM into the gitignored `third_party/elfutils-devel/` and extracts just the
headers). Then export what it prints before building:
`eval "$(scripts/setup_elfutils_headers.sh --env)"` → sets `CPATH` (include search) and
`LIBRARY_PATH` (link search). Without these, the iss targets fail to compile
(`elfutils/libdwfl.h: No such file`) / link (`cannot find -ldw`).

## Development log (for weekly reports)

**Standing convention (user request):** maintain a running dev log so weekly
reports are easy to assemble. This mirrors the convention in the RTL repo
(`ManyRVData_rebase/CLAUDE.md`).

- **Log file:** `prompt/WORKLOG.md` — newest entries at top. (The GVSoC repo
  keeps all its narrative docs/reports under `prompt/`, so the worklog lives
  there alongside the `weekly_report_*.md` and architecture docs.)
- **When to append:** every time we make a meaningful code/model/config/test
  modification, and **always when we make a git commit** (across any of the
  submodules — `core`, `pulp`, `engine`, `gvrun`, or the parent). Add the entry
  as part of the same step as the commit (don't batch it for later).
- **What to record (in detail):**
  - **Date + time** of the change/commit (absolute, e.g. `2026-06-01 19:40 +0200`).
  - **Commit hash + subject** per repo touched (if committed); note
    "uncommitted/staged" otherwise. Remember submodule SHAs change independently
    from the parent pointer bump.
  - **Files touched** (paths).
  - **What** was done and **why** (root cause / motivation), enough to recall
    the work months later without re-reading the diff.
  - **Verification** — how it was tested (targets built, microbench / calib
    numbers, pass/fail, regression smoke).
  - Link related reports under `prompt/` and any open follow-ups.
- **Goal:** at week's end, the weekly report (`prompt/weekly_report_<date>.md`)
  is assembled by reading `WORKLOG.md` + `git log` across submodules, not by
  reconstructing from memory.

## Calibrating the model against the RTL standalone testbench

The RTL side ships a standalone performance-calibration testbench around one
`cachepool_cache_ctrl` (coalescer + Snitch bypass + `insitu_cache_tcdm_wrapper`)
driven by a deterministic fixed-latency refill responder. Its design, the
**trace + result CSV interchange formats**, the **memory-model algorithm** (as
portable pseudocode), and the **RTL reference numbers** are documented under
`/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/reports/cache_calib/`:
`PLAN.md`, `TRACE_SPEC.md`, `CALIB_IMPLEMENTATION.md`, `REPORT.md`,
`results_memlat{10,50,100,200}.csv`, `traces/sample.trace` (+ `.rtl.csv`).

**The GVSoC side reproduces this** so the two engines can run the *same* trace
through the *same* memory-timing model and we diff the per-access `latency`
column. GVSoC-side pieces:

- `core/models/cache/insitu/insitu_calib_mem.{cpp,py}` — the fixed-latency,
  **serializing** refill responder (`MemLatency` / `BeatGap` / `AcceptEvery`),
  the GVSoC twin of `refill_mem_model.sv`. Serialization is modelled with a
  `mem_busy_until` cyclestamp (synchronous-OK path), which reproduces the RTL's
  "at most one outstanding line-refill" miss-throughput behaviour.
- `pulp/insitu_cache_calib/` — the calibration target: a trace-replay driver
  (`calib_driver.{cpp,py}`) that ingests `port,rw,addr,size,delay`, honours the
  per-port file-order + concurrent-port semantics, stamps `t_issue`/`t_resp`,
  and emits the per-access + aggregate CSVs in the shared schema.
- `make_cachepool_512_calib_config()` in `insitu_cache_config.py` — one
  controller, 5 ports, 4-way × 256-set (= 64 KiB), matching the RTL DUT geometry.

Reference numbers to match (config 512): **warm read-hit = 10 cyc isolated /
7 cyc streaming**, **cold read-miss = MemLatency + 17 cyc**, **miss throughput
serialized** (≈ 1/(MemLatency+17), not divided by accept depth), **single-port
hit ceiling ≈ 0.86 acc/cyc**. Full comparison + current gaps:
`prompt/insitu_cache_calib_report.md`.

## Architecture notes

- Targets are Python classes subclassing `gvsoc.runner.Target` (e.g. `pulp/pulp-open.py`). They point at a "board" model (e.g. `Pulp_open_board`) whose hierarchy is built out of `gvsoc.systree.Component` subclasses. A board composes a SoC, which composes clusters/IPs; each `Component` calls `set_component('<module>.<class>')` to bind to a compiled C++ model in `core/models/`.
- C++ models live under `core/models/<category>/<name>.cpp` with a paired `<name>.py` that exposes the Python `Component`. Interconnect primitives (router, demux, interleaver, splitter, remapper, test-and-set, rw_splitter, converter, limiter, log_ico, bus_watchpoint) are in `core/models/interco/`. Two ISS generations coexist: the legacy one in `core/models/cpu/iss/` and the active one in `core/models/cpu/iss_v2/`.
- Bindings between components are explicit (`self.bind(src, 'port', dst, 'port')`) — see the DRAMSys example wiring in `DRAMSys.md:64-68`.
- `engine/python/gvsoc/` provides two parallel `systree` / `runner` variants (`systree.py`/`runner.py` vs. `systree_gvrun.py`/`runner_gvrun2.py`) — the `USE_GVRUN`/`USE_GVRUN2` env vars select which one `gvrun` activates.
