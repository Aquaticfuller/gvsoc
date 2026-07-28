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

This fork adds a **`cachepool`** target: a cycle-approximate model of the CachePool cluster
(Snitch+Spatz cores, the InSitu L1 data cache, SPM, peripheral) that boots and runs the
**unmodified** CachePool test binaries — the same ELFs you build for RTL simulation. No
recompilation of the software is needed to move a kernel from QuestaSim to GVSoC.

Build the binaries on the RTL side first, following
`software/tests/multi_producer_single_consumer_double_linked_list/README.md`
in the ManyRVData repo (`make sw config=cachepool_fpu_512`, variants under
`software/build/CachePoolTests/`). Everything below consumes those ELFs as-is.

### 1. Build the simulator

~~~~~shell
# ETH network: pin the toolchain and provide the elfutils headers (needed since the
# 2026-06 upstream pull; the script downloads them without sudo, idempotent).
eval "$(scripts/setup_elfutils_headers.sh --env)"
CXX=g++-14.2.0 CC=gcc-14.2.0 CMAKE=cmake-3.18.1 make all TARGETS="cachepool"
source sourceme.sh     # puts install/bin on PATH; once per shell
~~~~~

The Python code needs **Python >= 3.10**. If your default `python3` is older, shim it:
`ln -sf /usr/bin/python3.12 /tmp/py312_shims/python3 && export PATH=/tmp/py312_shims:$PATH`.
Required pip packages are listed in the *Python requirements* section above.

### 2. Run a kernel

~~~~~shell
B=<ManyRVData>/software/build/CachePoolTests
gvsoc --target=cachepool \
      --binary $B/test-cachepool-multi_producer_single_consumer_double_linked_list_M48_N800_K300 \
      run
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
| `CACHEPOOL_NB_TILE` | number of tiles | 1 |
| `CACHEPOOL_CORES_PER_TILE` | cores per tile (keep >= 2) | 4 |
| `CACHEPOOL_BANKS_PER_TILE` | L1 cache banks per tile (power of two) | = cores/tile |
| `CACHEPOOL_USE_CACHE` | `0` bypasses the L1 cache (A/B the cache's effect) | 1 |

Total cores = `NB_TILE x CORES_PER_TILE`. The standard CachePool config is 4x4 = 16 cores:

~~~~~shell
CACHEPOOL_NB_TILE=4 CACHEPOOL_CORES_PER_TILE=4 \
  gvsoc --target=cachepool --binary $B/test-cachepool-<kernel> run
~~~~~

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

### 5. Cross-check against the RTL reference numbers

Measured with the current model at 16 cores (4x4), against the reference figures in the RTL
kernel README:

| Case | RTL work phase | GVSoC work phase | Delta |
|---|---|---|---|
| TC2 multi-user `M48_N800_K300` (2P/2C) | 530,059 | 538,635 | **+1.6%** |
| TC1 single-user `M1_N1350_K100` | 130,828 | 155,373 | +18.8% |

Other CI kernels are within roughly 5-15% (gemv +1.0%, byte-enable -5.4%, fmatmul -9.0%);
see `prompt/cachepool_rtl_kernel_diff_2026-07-27.md` for the full per-kernel table and the
root cause of each remaining outlier.

> **Known model-vs-RTL divergence:** the RTL README lists TC2 with `CONSUMER_CORE_NUM >= 8`
> as currently failing (under debug). Those variants (`P2_C8`, `P4_C8`) **pass** on this
> model, so the model does not currently reproduce that failure — do not treat a passing
> GVSoC run of those variants as validation of the RTL configuration.

### 6. Notes and troubleshooting

- **Do not background the simulation.** If a run appears to hang, kill it and inspect the log;
  prefix with `stdbuf -oL -eL` to capture output before an abort.
- **`--trace=<component path>`** dumps traces for a component (hierarchy path, not a file
  path), e.g. `--trace=/chip/soc/cluster_0/pe0/insn` for one core's instructions. It is very
  slow on long kernels — prefer the end-of-run counters above for performance questions.
- **Realistic DRAM timing** is available with `CACHEPOOL_DRAMSYS=1` (DDR4 via DRAMSys, 4
  channels); it is 10-100x slower in wall-clock. See [DRAMSys.md](./DRAMSys.md) for setup.
  The default backing store uses a calibrated fixed latency (`CACHEPOOL_MEM_LATENCY`, default 50).
- A full runbook with more configuration examples lives in
  `prompt/cachepool_complete_model_run_guide_2026-06-25.md`, and the multi-user RLC scaling
  sweep in `prompt/multiuser_llist_sweep_2026-07-27.md`.

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
