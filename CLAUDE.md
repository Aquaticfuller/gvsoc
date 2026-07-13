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
(`DiyouS/gvsoc-core` and `DiyouS/gvsoc-pulp`; previously `Aquaticfuller/...`,
a colleague's fork the user doesn't have push access to). Both forks use
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

## CachePool v2 target

### Hardware/software reference

- **RTL branch & commit**: `dev/multi-group` @ `05e4671a6cc355923793893c7be5bc373cbb0dde` — the ManyRVData hardware revision this GVSoC model is built against. See also `rtl_readonly` memory for the reference tree location.
- **Software config**: `cachepool_fpu_16g` — the ManyRVData config used to generate the CachePoolTests software/binaries this model is validated against.

### Known gaps / not yet implemented

The 256-core fdotp/fmatmul livelock (undersized `pdcp_mem`) documented as open in
`prompt/cachepool_v2_architecture.md` §13.1/13.2 **is fixed and verified** (both
kernels reach `EOC: exit code 0` with zero `FAIL` at full 256-core scale) — that
doc predates the fix and is stale on this point; trust this file + `git log` over
it for current status.

Actual open items:

1. **Address scrambling in L1** — the model approximates the RTL's hash-way
   victim/set-index selection with a Knuth-style hash rather than RTL's exact
   polynomial (`core/models/cache/insitu/README.md` §9 roadmap item 4). Only
   matters if set-index aliasing becomes workload-visible.
2. **Cache partitioning** — `cachepool_v2_cluster_peripheral.cpp` doesn't
   implement `l1d_part` / `l1d_xbar_config` / `l1d_flush`; those writes silently
   return OK and are no-ops (`prompt/cachepool_v2_architecture.md` §13.3/13.4).
   The 0xa0000000 "uncached" region is also treated identically to cacheable
   DRAM — coalescer-side uncached logic isn't implemented either.
3. **L2 refill mesh** — RTL's real L2-side interconnect is WIP upstream, so this
   model uses a flat AXI `Router` tree (not a mesh) from each group down to
   `l2_mem`/`pdcp_mem`. Those backing stores are also plain `memory.Memory`
   (idealized fixed-latency), not routed through DRAMSys — no realistic DRAM
   timing model yet either.
4. **Calibration** — Phase 6 validation (RTL-vs-GVSoC cycle-count/counter diff on
   curated workloads: cache-line-rw-smoke, random reads, streaming writes,
   blocked GEMM, vector AXPY) hasn't been done (`core/models/cache/insitu/
   README.md` §9). The calibrated controller is validated against the standalone
   `insitu_cache_calib` testbench, not the full `cachepool_v2` topology.
5. **Structural (RTL-faithful, per-cycle) cache core** — a second,
   `use_structural_core=True` implementation path exists alongside the default
   calibrated controller; Steps 1–2/4 are committed but Steps 3 (forwarding
   buffer), 5 (parallel coalescer), and 6 (crossbar/remote crossbar) are
   incomplete, and it isn't wired into `cachepool_v2` at all. Not just
   uncalibrated — the model itself is unfinished.

### Build

All commands run from the **inner gvsoc folder** (`/scratch/diyou/cachepool/gvsoc/gvsoc/`), never the root.

```bash
conda run -p /home/msc26f31/.conda/envs/gvsoc bash -c \
  'cd /scratch/diyou/cachepool/gvsoc/gvsoc && \
   eval "$(scripts/setup_elfutils_headers.sh --env)" && \
   CXX=g++-14.2.0 CC=gcc-14.2.0 CMAKE=cmake-3.18.1 make build TARGETS="cachepool_v2"'
```

- The conda env with Python 3.12 + toolchain is at `/home/msc26f31/.conda/envs/gvsoc`.
- `setup_elfutils_headers.sh --env` sets `CPATH`/`LIBRARY_PATH` for elfutils headers; run once to download, `--env` is fast/idempotent on subsequent calls.
- Use target `cachepool_v2` (not `cachepool`).

### Run simulation

```bash
# Source the environment first (once per shell session):
source sourceme.sh

# Run (from /scratch/diyou/cachepool/gvsoc/gvsoc/):
gvsoc --target=cachepool_v2 \
      --binary ../ManyRVData/software/build/CachePoolTests/test-cachepool-fdotp-32b_M32768 \
      image flash run \
      --trace=/cachepool_v2_soc/cachepool_cluster/group_0_0/tile_0/pe0 \
      --trace=/cachepool_v2_soc/peripheral \
      > ./gvsoc_trace.txt
```

- `../ManyRVData` is relative to the inner gvsoc folder → resolves to `/scratch/diyou/cachepool/gvsoc/ManyRVData/`.
- Test binaries live in `../ManyRVData/software/build/CachePoolTests/`.
- **`test-cachepool-fdotp-32b_M8192` will not run correctly at 256 cores** — the M8192 problem size is too small to divide evenly across 256 Spatz-4 cores. Use `test-cachepool-fdotp-32b_M32768` (or larger) for full 256-core runs; M8192 is only valid at smaller core counts.
- `--trace=` paths are GVSoC component hierarchy paths (not filesystem paths). Use `.` to trace everything (very verbose). `--trace-level=trace` has been observed to stall elaboration itself for 10-15s producing zero output even scoped to a handful of components — avoid it; prefer targeted `fprintf(stderr, ...)` instrumentation in the C++ source for deep debugging.
- To capture the fatal message before an `abort()`, prefix with `stdbuf -oL -eL` to disable stdio buffering.
- Do **not** run the process in the background; kill any hung simulation and check the log.
- **The `gvsoc` wrapper can silently swallow the launched process's stdout/stderr** (confirmed: `fprintf(stderr, ...)` calls that fire on every instruction produced zero bytes through it, even after 90s+). If a run looks suspiciously silent, generate the config with a short-timeout `gvsoc ... image flash run` (the config write happens within the first ~1-10s, well before any hang) then invoke `install/bin/gvsoc_launcher --config=gvsoc_config.json` **directly** — this reliably shows real-time output.
- **`gvsoc_config.json` is not regenerated if it already exists** — there's no mtime/staleness check against the Python topology source. Always `rm -f gvsoc_config.json` before regenerating after any Python-side change, or you'll silently keep simulating the old topology/wiring.
- **Debug-topology override** (for faster iteration than the full 256-core config): `CACHEPOOL_V2_NB_X_GROUPS` / `_NB_Y_GROUPS` / `_TILES_PER_GROUP` / `_CORES_PER_TILE` env vars (default 4/4/4/4) in `cachepool_v2_system.py`, e.g. `CACHEPOOL_V2_NB_X_GROUPS=2 CACHEPOOL_V2_NB_Y_GROUPS=2 CACHEPOOL_V2_TILES_PER_GROUP=1 CACHEPOOL_V2_CORES_PER_TILE=4` = 16 cores instead of 256. Keep `CORES_PER_TILE>=2` — `Hierarchical_cache`'s icache sizing math (`pulp/mempool/hierarchical_cache.py`) goes fractional/negative below that (known bug, not yet fixed, see `prompt/cachepool_v2_architecture.md` §13.2.2).

### Directory layout

| Path | Contents |
|------|----------|
| `/scratch/diyou/cachepool/gvsoc/gvsoc/` | GVSoC SDK — source, build, install, sourceme.sh |
| `/scratch/diyou/cachepool/gvsoc/ManyRVData/` | RTL reference + built software + test binaries (read-only) |
| `pulp/pulp/cachepool_v2/` | Python topology files for the v2 model |
| `core/models/cache/insitu/` | InsituCache C++/Python model |
| `core/models/cpu/iss/src/ara/spatz_vlsu.cpp` | Spatz VLSU (AraVlsu with DENIED handling) |

### Key design notes

- **Address normalization**: The "uncached" DRAM region 0xa0000000–0xBFFFFFFF is treated as cacheable DRAM for now. `cachepool_v2_tile.py` maps it to 0x80000000-based addresses before L1. The `CachepoolV2DramNormalizer` shim (`cachepool_v2_dram_normalizer.cpp`) handles this for VLSU ports without consuming IoReq arg slots (unlike Router, which calls `arg_alloc(4)` per traversal).
- **IoReq arg stack**: `IO_REQ_NB_ARGS = 16` slots. Each Router traversal costs 4 slots. Components using `req_forward` (L1NocAddressConverter, DramNormalizer) cost 0 slots. The FlooNoc NI needs slots at `current_arg+0` and `current_arg+1`.
- **AraVlsu DENIED**: When the FlooNoc NI already has a pending burst, it returns `IO_REQ_DENIED` to a second concurrent VLSU request on the same port. The fix in `spatz_vlsu.cpp` treats DENIED like PENDING — increments `nb_pending_bursts` and advances the address. The NI will eventually call `response` via the Router's response path.
- **GVSoC composite-boundary port names must match exactly, and a mismatch fails silently.** When crossing a composite component boundary with `self.bind(child, 'child_port', self, 'boundary_name')` + (one level up) `self.bind(tile_instance, 'boundary_name', target, 'target_port')`, the *exact* port name string must match what the target component actually exposes (e.g. `Router`/`Hierarchical_Interco` with `nb_slaves=N` expose `input_0..input_{N-1}`, not a plain `input`, once `N` is passed or defaulted). GVSoC's `vp::Component::create_ports()` auto-creates a placeholder `VirtualPort` for *any* unrecognized "self"-referenced name rather than raising an error — so a typo'd port name silently produces an orphaned, never-connected dead end instead of a build failure. This caused a real bug: every core in `cachepool_v2` was permanently stuck at the reset vector because `cachepool_v2_group.py` bound to `axi_ico`'s `'input'` instead of `'input_0'` (see `prompt/cachepool_v2_architecture.md` §13.2.2). When a request mysteriously comes back `IO_REQ_INVALID` despite the wiring "looking right" in Python, suspect this first — check `Router::req()`'s `!entry->itf.is_bound()` branch, or instrument `engine/engine/src/ports.cpp`'s `MasterPort::bind_to_slaves()`/`get_final_ports()` to see whether the binding chain actually resolves (`nb_final` should be ≥1, not 0).

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
5. **Wire the C++ side**: for the calibrated path, edit `insitu_cache_controller.cpp`
   (read props via `get_js_config()->get_child_*`, gate behaviour — e.g.
   `if (write_through_mode_) issue_write_through(req);`). For the structural path,
   wire the corresponding knob in `insitu_cache_core.cpp` or the relevant header.
   Phase A = simple gates; full-topology refactors go to Phase B.
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

**Calibrated (cycle-approximate) path** — default (`use_structural_core=False`):

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

**Structural (RTL-faithful) path** — opt-in (`use_structural_core=True` in
`InsituCacheTileConfig`). Steps 1–4 committed; Steps 3/5/6/7 pending. Latency emerges
from pipeline cycles; calibration deferred until Steps 5–7 are in place:

- `insitu_cache_decode.hpp` — Step 1: RTL-faithful address decode, hash-way (`lowtag^lowset`),
  SOP hit/hit_pend/hit_conflict/all_pend classify, full-assoc LRU victim, encoder LRU-credit
  update, masked byte merge. Header-only, no ports.
- `insitu_cache_bank_array.hpp` — Step 2: pseudo-dual-port bank model (6-state R/W classify,
  `bank_select = low log2(BankFactor) bits of set`, per-cycle WR_CONFLICT scoreboard → read
  retry next cycle). Header-only.
- `insitu_cache_fwd_buffer.hpp` — Step 3: forwarding buffer header (in progress).
- `insitu_cache_core.{cpp,py}` — Step 4: per-cycle ClockEvent FSM core (2-stage pipeline:
  stage-0 arbitrate → preread; stage-1 decode+FSM+bank write+drain). Consumes Steps 1–2.
  Bounded streaming accept queue (`max_outstanding` knob, default 32).
- `insitu_cache_par_coalescer.{cpp,py}` — Step 5: parallel coalescer (RTL `par_coalescer_top`
  port; stub / in progress).
- `insitu_cache_xbar.{cpp,py}`, `insitu_cache_remote_xbar.{cpp,py}` — Step 6: crossbar and
  remote crossbar (in progress).
- `insitu_cache_cell_coalescer.{cpp,py}` — cell-granularity coalescer.
- `insitu_cache_amo.hpp`, `insitu_cache_amo_shim.{cpp,py}` — AMO support shim.
- `insitu_cache_group.py` — group component (composite helper).
- `insitu_cache_coalesce.hpp`, `insitu_cache_l2_addr.hpp`, `insitu_cache_route.hpp`,
  `insitu_cache_spm_remap.hpp`, `insitu_cache_sync_fsm.hpp` — shared header logic.

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
- Two selectable implementations share the same tile wrapper. `InsituCacheTileConfig.use_structural_core=False` (default) → calibrated controller; `=True` → per-cycle FSM core (Steps 1–4). The cluster integration keeps the default until the structural core's synchronous-slave inline mode lands (Steps 5–7).
- The structural core's per-access latency over-predicts under deep saturation (open-loop replay double-count + single-outstanding-refill serialization). Do not read structural-core numbers as calibrated; closed-loop region_cyc comparison is the right metric (see `prompt/insitu_cache_misspath_diagnosis_2026-06-16.md §13`).
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

**Build environment.** On the ETH cluster (`fenga` / `gondola` nodes), the correct
Python is in the shared conda env. Full build procedure:

```bash
conda activate /home/msc26f31/.conda/envs/gvsoc
eval "$(scripts/setup_elfutils_headers.sh --env)"   # sets CPATH + LIBRARY_PATH
CXX=g++-14.2.0 CC=gcc-14.2.0 CMAKE=cmake-3.18.1 make build TARGETS="cachepool"
source sourceme.sh
```

The default system `python3` is 3.6 (too old). The conda env at
`/home/msc26f31/.conda/envs/gvsoc` provides Python 3.12 with all required packages.

**elfutils headers (since the 2026-06 upstream pull).** Upstream's ISS now resolves trace
PC→symbol at runtime via libdw (`core/models/cpu/iss*/src/trace.cpp` includes
`<elfutils/libdwfl.h>`; `riscv.py` calls `add_libraries(['dw','elf'])`, which needs engine
`Component.add_libraries()` — engine ≥ `a3d410b4`, i.e. the bumped engine pointer). The ETH
cluster ships the runtime libs (`libdw.so.1`/`libelf.so.1`) but **not** `elfutils-devel`, and
there's no passwordless sudo. Provide the headers + the missing `libdw.so` link symlink
**without sudo** via `scripts/setup_elfutils_headers.sh` (dnf-downloads the matching
`elfutils-devel` RPM into `third_party/elfutils-devel/` and extracts just the headers). Once
run once, the `--env` flag just prints the exports (fast, idempotent):
`eval "$(scripts/setup_elfutils_headers.sh --env)"` → sets `CPATH` (include search) and
`LIBRARY_PATH` (link search). Without these, the iss targets fail to compile
(`elfutils/libdwfl.h: No such file`) / link (`cannot find -ldw`).

**Note on `dnf download` failures.** If `setup_elfutils_headers.sh` fails with
`Error: Loading repository 'code'` (VS Code's dnf repo failing), the root filesystem
is also likely full (`/var/tmp` out of space). Run dnf with:
`dnf download --disablerepo=code --setopt=cachedir=/tmp/dnf-cache-elf ...` to bypass both.

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

Reference numbers to match **for the calibrated controller** (config 512):
**warm read-hit = 10 cyc isolated / 7 cyc streaming**, **cold read-miss =
MemLatency + 17 cyc**, **miss throughput serialized** (≈ 1/(MemLatency+17)),
**single-port hit ceiling ≈ 0.86 acc/cyc**, **write latency 8 / throughput
~0.49**, **read-after-write forwarding 7 cyc**. Full comparison + current gaps:
`prompt/insitu_cache_calib_report.md`.

The structural core (`use_structural_core=True`) is **not yet calibrated** —
per-access latency over-predicts under saturation (open-loop replay double-count;
see `prompt/insitu_cache_misspath_diagnosis_2026-06-16.md §13`). Calibrate via
closed-loop `region_cyc` once Steps 5–7 are in place.

## Architecture notes

- Targets are Python classes subclassing `gvsoc.runner.Target` (e.g. `pulp/pulp-open.py`). They point at a "board" model (e.g. `Pulp_open_board`) whose hierarchy is built out of `gvsoc.systree.Component` subclasses. A board composes a SoC, which composes clusters/IPs; each `Component` calls `set_component('<module>.<class>')` to bind to a compiled C++ model in `core/models/`.
- C++ models live under `core/models/<category>/<name>.cpp` with a paired `<name>.py` that exposes the Python `Component`. Interconnect primitives (router, demux, interleaver, splitter, remapper, test-and-set, rw_splitter, converter, limiter, log_ico, bus_watchpoint) are in `core/models/interco/`. Two ISS generations coexist: the legacy one in `core/models/cpu/iss/` and the active one in `core/models/cpu/iss_v2/`.
- Bindings between components are explicit (`self.bind(src, 'port', dst, 'port')`) — see the DRAMSys example wiring in `DRAMSys.md:64-68`.
- `engine/python/gvsoc/` provides two parallel `systree` / `runner` variants (`systree.py`/`runner.py` vs. `systree_gvrun.py`/`runner_gvrun2.py`) — the `USE_GVRUN`/`USE_GVRUN2` env vars select which one `gvrun` activates.
