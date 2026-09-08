# GVSoC

GVSoC is the PULP chips simulator that is natively included in the Pulp SDK and is described and evaluated fully in Bruschi et al. [\[arXiv:2201.08166v1\]](https://arxiv.org/abs/2201.08166).


## GVSoC documentations

The user documentation, focusing on how to use GVSOC, is available [here](https://gvsoc.readthedocs.io/en/latest/).

The developer documentation, focusing on how to develop models or extend GVSOC is available [here] (https://gvsoc-developer.readthedocs.io/en/latest/).

## GVSoC Tutorial

If you want to learn more about GVSoC, get started through the tutorial available [here](https://gvsoc-developer.readthedocs.io/en/latest/tutorials.html). This tutorial provides hands-on practice on building systems on GVSoC and extracting the performance results.


## OS Requirements installation

These instructions were developed using a fresh Ubuntu 22.04 (Jammy Jellyfish).

The following packages needed to be installed:

~~~~~shell
sudo apt-get install -y build-essential git doxygen python3-pip libsdl2-dev curl cmake gtkwave libsndfile1-dev rsync autoconf automake texinfo libtool pkg-config libsdl2-ttf-dev wget sphinx-build doxygen
~~~~~

These are the packages neded on a Fedora:

~~~~~shell
sudo dnf install -y make gcc cmake ninja-build.x86_64 g++ pip lz4-devel ccache glibc-devel.i686 zlib-ng-compat-devel.i686 SDL2 SDL2-devel SDL2_ttf-devel.x86_64 SDL2_image-devel.x86_64 wget2 sphinx-build doxygen
~~~~~

Please also check any README.md in the submodules for target-specific requirements, like for example pulp/README.md.

## Python requirements

Additional Python packages are needed and can be installed with the following commands from root folder:

```bash
git submodule update --init --recursive -j8
pip3 install -r core/requirements.txt
pip3 install -r gapy/requirements.txt
```

## Installation

Get submodules and compile GVSoC with this command:

~~~~~shell
make all TARGETS=<target>
~~~~~

<target> should indicate the target for which GVSoC must be build. This can for example be generic targets rv32 or rv64. 

On ETH network, please use this command to get the proper version of gcc and cmake:

~~~~~shell
CXX=g++-14.2.0 CC=gcc-14.2.0 CMAKE=cmake-3.18.1 make all TARGETS=pulp-open
~~~~~

## Usage

The following example can be launched on pulp-open:

~~~~~shell
./install/bin/gvsoc --target=pulp-open --binary examples/pulp-open/hello image flash run
~~~~~

## Running CachePool kernels (RLC and the rest of the CI suite)

This fork adds a **`cachepool_v3`** target: a cycle-approximate model of the CachePool cluster
— Snitch+Spatz core complexes over a **shared** InSitu L1 data cache, in a multi-group mesh with
two NoC levels — that boots and runs the **unmodified** CachePool test binaries, the same ELFs you
build for RTL simulation. No recompilation of the software is needed to move a kernel from
QuestaSim to GVSoC.

The model's own documentation, including the cluster design and every configuration knob, is in
[`core/models/cache/insitu/README.md`](core/models/cache/insitu/README.md).

Build the binaries on the RTL side first, following
`software/tests/multi_producer_single_consumer_double_linked_list/README.md`
in the ManyRVData repo (`make sw config=cachepool_fpu_512`, variants under
`software/build/CachePoolTests/`). Everything below consumes those ELFs as-is.

### 1. Build the simulator

~~~~~shell
# ETH network: pin the toolchain and provide the elfutils headers (needed since the
# 2026-06 upstream pull; the script downloads them without sudo, idempotent).
eval "$(scripts/setup_elfutils_headers.sh --env)"
CXX=g++-14.2.0 CC=gcc-14.2.0 CMAKE=cmake-3.18.1 make all TARGETS="cachepool_v3"
source sourceme.sh     # puts install/bin on PATH; once per shell
~~~~~

The Python code needs **Python >= 3.10**. Required pip packages are listed in the *Python requirements* section above.

### 2. Run a kernel

~~~~~shell
B=<ManyRVData>/software/build/CachePoolTests
gvsoc --target=cachepool_v3 \
      --binary $B/test-cachepool-multi_producer_single_consumer_double_linked_list_M48_N800_K300 \
      image flash run
~~~~~

Run each simulation from its **own working directory** — GVSoC writes `gvsoc_config.json`
into the cwd and **does not regenerate it if it already exists**, so parallel runs in one
directory race, and a stale file silently simulates the previous topology. When changing
any option below, `rm -f gvsoc_config.json` first.

### 3. Choosing the hardware topology (no rebuild required)

Unlike the RTL flow (where the core count is baked in at elaboration), the topology is set by
environment variables at run time:

| Variable | Meaning | Default |
|---|---|---|
| `CACHEPOOL_V3_NB_X_GROUPS` / `_NB_Y_GROUPS` | mesh dimensions | 1 / 1 |
| `CACHEPOOL_V3_TILES_PER_GROUP` | tiles per group | 4 |
| `CACHEPOOL_V3_CORES_PER_TILE` | **core complexes** per tile — not harts | 4 |
| `CACHEPOOL_V3_SCALAR_PER_CC` | scalar harts per complex; `2` = the dual-scalar config | 1 |
| `CACHEPOOL_V3_BANKS_PER_TILE` | L1 cache banks per tile (power of two) | = complexes/tile |
| `CACHEPOOL_V3_MEM_LATENCY` | backing-store latency, cycles | 50 |

Total cores = `NB_X x NB_Y x TILES_PER_GROUP x CORES_PER_TILE x SCALAR_PER_CC`. Defaults give
16 cores; `2x2` groups gives 64 and `4x4` gives 256:

~~~~~shell
CACHEPOOL_V3_NB_X_GROUPS=2 CACHEPOOL_V3_NB_Y_GROUPS=2 \
  gvsoc --target=cachepool_v3 --binary $B/test-cachepool-<kernel> image flash run
~~~~~

One thing that catches people: `CORES_PER_TILE` counts **core complexes**. A complex owns one
Spatz and one L1 cache bank; with `SCALAR_PER_CC=2` it holds two scalar harts that share them.

The bootrom's core/tile counts are patched automatically to match, so any combination boots.
Note that a *kernel* may still require a particular core count (e.g. `fft` only passes at its
native 16-core geometry, and `fdotp_M8192` does not divide across 256 cores).

### 4. Reading the output

A good run ends with:

```
[EOC] Simulation exiting: retval=0 cycles=937001
```

The RLC kernel additionally prints its own region markers, which are the numbers to use for
performance comparisons:

```
[core 0]: start cycle = 282870, end cycle = 821505, total cycles = 538635
```

> **Important — compare *work phases*, not EOC totals.** GVSoC loads the ELF through the
> modelled interconnect, so the EOC count includes a load time proportional to the binary's
> data sections (the RLC multi-user ELF carries ~11.7 MB of `.pdcp_src`, ~180k cycles;
> QuestaSim loads via a free backdoor). The kernel's own `total cycles` marker excludes it and
> is directly comparable to the RTL's region count.

Useful extra diagnostics, printed at the end of every run:
`[INSITU-CORE ...]` per-bank cache statistics (hits/misses/refills/evictions/flushes plus a
latency budget) and `[ARA-STATS ...]` per-core vector issue counters.

### 5. Reference runs — RLC multi-user thread scaling (16 cores)

Copy-pasteable sweep of the producer/consumer variants at the standard 4x4 = 16-core
topology. The P/C split is **compiled into the ELF** (the `_P<p>_C<c>` variants); only the
topology comes from the environment:

~~~~~shell
B=<ManyRVData>/software/build/CachePoolTests
K=test-cachepool-multi_producer_single_consumer_double_linked_list_M48_N800_K300

for V in "" _P2_C8 _P4_C4 _P4_C8; do            # "" = the default 2P/2C build
  mkdir -p /tmp/rlc/$V && cd /tmp/rlc/$V && rm -f gvsoc_config.json
  gvsoc --target=cachepool_v3 --binary $B/$K$V image flash run > run.log 2>&1
  echo "$V: $(grep -oE 'retval=[0-9]+ cycles=[0-9]+' run.log | tail -1)" \
       "work=$(grep -oE 'total cycles = [0-9]+' run.log | head -1 | grep -oE '[0-9]+')" \
       "errs=$(grep -cE 'ERROR|Check Failed' run.log)"
done
~~~~~

All four must report `retval=0` with **zero** `ERROR` / `Check Failed` lines, which is what this
sweep is for. The shape of the scaling is that producers saturate first — going 2→4 producers is
worth far more than adding consumers on top of 2 producers — and consumers only pay off once the
producers keep up.

> The absolute cycle counts previously tabulated here were measured on the earlier `cachepool`
> model and are **not** valid for `cachepool_v3`, which has a different fabric. They have been
> removed rather than relabelled; re-measure before quoting any figure from this sweep.

### 6. Cross-check against the RTL reference numbers

Calibration is anchored at **64 cores** (`2x2` groups) against the RTL running the same ELF.

| Kernel | Character | RTL | GVSoC | Ratio |
|---|---|---|---|---|
| RLC `M1_N1350_K100` (fast pair) | latency-bound, L1-resident after warm-up | 150,175 / 150,183 | 149,248 / 149,678 | **0.6% fast** |
| `byte-enable` | L1-resident, no refills | 289,468 | 252,494 | 0.87x — 13% fast |
| `bandwidth` | memory-bound, exercises the refill path | 2,058 | 29,122 | **14.2x slow** |

**The sign flip is the result, not the ratios.** A uniformly-slow model cannot be 14.2x slow on
one kernel and 13% fast on another. It places the remaining error in the **refill path** and
nowhere else: kernels that stay in L1 are close, kernels that stream through DRAM are not.

The two known contributors are one outstanding miss per cache controller, and — until
`CACHEPOOL_V3_DRAMSYS=1` — a flat fixed-latency store where the hardware has per-channel DRAM.
Neither has been measured out yet, so treat throughput-bound absolute numbers as indicative and
latency-bound ones as calibrated.

### 7. Notes and troubleshooting

- **Do not background the simulation.** If a run appears to hang, kill it and inspect the log;
  prefix with `stdbuf -oL -eL` to capture output before an abort.
- **`--trace=<component path>`** dumps traces for a component (hierarchy path, not a file
  path), e.g. `--trace=/chip/soc/cluster_0/pe0/insn` for one core's instructions. It is very
  slow on long kernels — prefer the end-of-run counters above for performance questions.
- **Realistic DRAM timing** is available with `CACHEPOOL_V3_DRAMSYS=1`, which gives every memory
  channel of the refill mesh its own DRAM (HBM2 by default, `CACHEPOOL_V3_DRAM_TYPE` selects the
  config) instead of one shared flat store. It is 10-100x slower in wall-clock and needs SystemC
  preloaded — see [DRAMSys.md](./DRAMSys.md) and the model README. The default backing store uses a
  calibrated fixed latency (`CACHEPOOL_V3_MEM_LATENCY`, default 50).
- The model's own documentation — cluster design, every configuration knob, telemetry, current
  limitations — is [`core/models/cache/insitu/README.md`](core/models/cache/insitu/README.md).
  Development history is `prompt/WORKLOG.md`. Older runbooks under `prompt/` describe the earlier
  `cachepool` target and its environment variables, which do not apply here.

## Citing

If you intend to use or reference GVSoC for an academic publication, please consider citing it:

```
@INPROCEEDINGS{9643828,
	author={Bruschi, Nazareno and Haugou, Germain and Tagliavini, Giuseppe and Conti, Francesco and Benini, Luca and Rossi, Davide},
	booktitle={2021 IEEE 39th International Conference on Computer Design (ICCD)},
	title={GVSoC: A Highly Configurable, Fast and Accurate Full-Platform Simulator for RISC-V based IoT Processors},
	year={2021},
	volume={},
	number={},
	pages={409-416},
	doi={10.1109/ICCD53106.2021.00071}}
```

## Using GVSoC with DRAMsys

If you want to use DRAMsys with GVSoC follow the steps mentioned in [DRAMsys.md](./DRAMSys.md)
