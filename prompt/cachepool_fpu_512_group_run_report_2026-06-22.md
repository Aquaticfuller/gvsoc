# CachePool fpu_512 Group — Cluster Wiring + Benchmark Run Report (2026-06-22)

**Task:** wire the structural `cachepool_fpu_512` group into the GVSoC cluster, then run the benchmark
binaries listed in `ManyRVData_rebase/util/auto-benchmark/configs-ci.sh` (binaries under
`ManyRVData_rebase/software/build/CachePoolTests/`) and report the results.

**Outcome (headline):** the structural group is **wired into the cluster** (opt-in
`use_cachepool_group` → 4 tiles × 4 cores, matching `cachepool_fpu_512.mk`). However, the CachePool CI
**benchmark binaries do not run on the GVSoC `--target=spatz` SoC** — they are `snrt`-based binaries built
for the **CachePool RTL** SoC and are executed by the auto-benchmark via **QuestaSim (`vsim`)**, not
gvsoc. On the gvsoc spatz target they produce **no output and hang at boot** (verified at the baseline,
no cache, including `nb_core=16`). Running them on gvsoc needs a **GVSoC model of the CachePool SoC**
(boot/snrt environment, memory map, cluster peripheral/CSRs, print/HTIF path) — which does not exist; the
gvsoc spatz target is a different SoC. Details + what's needed below.

---

## 1. What the CI runs

`configs-ci.sh`: `CONFIGS="cachepool_fpu_512"`, `PREFIX="test-cachepool-"`, 8 kernels:
`spin-lock`, `load-store_M16`, `fdotp-32b_M32768`, `gemv-opt_M512_N128_K32`, `fmatmul-32b_M32_N32_K32`,
`fft-32b_M1024_N16`, `multi_producer_single_consumer_double_linked_list_M1_N1350_K10`, `byte-enable`.

All 8 binaries **exist** at `ManyRVData_rebase/software/build/CachePoolTests/test-cachepool-<kernel>`
(ELF32 RISC-V, single-float ABI, load at `0x8000_0000`, entry e.g. `0x80002760`, `snrt` crt0).

**How the CI executes them (`run_ci.sh` / `run_all.sh`):** `SIM_CMD="${ROOT_PATH}/sim/bin/cachepool_cluster.vsim"`
+ `make -C $ROOT generate vsim config=$cfg` → **QuestaSim RTL simulation of the CachePool cluster**. The
benchmarks are RTL-sim binaries for the CachePool SoC, not gvsoc binaries.

## 2. Group wiring into the cluster (DONE)

New opt-in property **`use_cachepool_group`** (`snitch.py`; default False). When set with
`use_insitu_cache` + `use_structural_insitu_cache`, the cluster (`snitch_cluster.py`) builds
**`InsituCacheGroup`** from `make_cachepool_fpu_512_config()` instead of a single tile:
- num_tiles=4, 4 cores/tile, 4 controllers/tile (NumL1CacheCtrl=NumCores=16), 5 TCDM ports/core,
  num_remote_port_core=2, per-controller 4-way×256-set×64B (bank_factor=2, hash-way), CoalFactor=2.
- Same `i_INPUT(port)`/`o_L2` facade as the tile, so the existing core→cache binding is unchanged
  (core c lane j → port c·5+j → tile c//4, local core c%4, lane j).
- `assert nb_core == num_tiles·cores_per_tile` (=16). inline_sync_miss + functional_writethrough on.
Invocation: `gvsoc --target=spatz --target-property use_insitu_cache=True --target-property
use_structural_insitu_cache=True --target-property use_cachepool_group=True --target-property
soc/cluster/nb_core=16 --binary <elf> run`.

The group itself is validated **data-correct** (open-loop calib, cross-tile routing, `data_err=0`) and the
single-tile structural path runs closed-loop (`vfadd` 15/15) — see the structure maps / WORKLOG.

## 3. Benchmark run attempts (the blocker)

| Run | nb_core | cache | result |
|---|---|---|---|
| `test-cachepool-spin-lock` | 2 (default) | none (baseline) | **no output** |
| `test-cachepool-spin-lock` | 16 | none (baseline) | **no output** |
| `test-cachepool-cache-line-rw-smoke` | 16 | none (baseline) | **no output; killed at 200 s (hang)** |

The binaries do **not** boot to first print or HTIF exit on the gvsoc spatz target (contrast: the
gvsoc-native `vfadd` test prints `[TC] PASSED` + `[HTIF] Simulation exiting`). Because the baseline
(no cache) already hangs, this is **not** a cache-model issue — it is a **SoC-level boot incompatibility**.

**Root cause.** The CachePool benchmarks use the **`snrt` (Snitch runtime)** crt0
(`snrt.crt0.init_global_pointer` → `init_core_info` → `init_bss` …) which expects the **CachePool SoC**:
its cluster base/TCDM map, the per-core/per-tile config + barrier/wakeup registers, the peripheral CSRs,
and the print path. The GVSoC `--target=spatz` is a **different SoC** (the gvsoc-pulp Spatz cluster; the
vfadd that runs is from gvsoc's own `spatz-rtl/sw/riscvTests` suite, matching *that* SoC). The snrt boot
spins on environment it doesn't find → hang before any output. (Both binaries share the `tohost`/`fromhost`
HTIF symbols, so the *exit* mechanism would work — but the boot never reaches it.) There is **no GVSoC
CachePool SoC target** in the tree (only `insitu_cache_tb` and the calib TB); a stale
`debug_binary_0_test-cachepool-cache-line-rw-smoke.debugInfo` (Apr 20) is the only trace of a prior
gvsoc attempt, with no standing harness.

## 4. What's needed to actually run these benchmarks on gvsoc

Running the CachePool CI binaries on gvsoc requires a **GVSoC model of the CachePool SoC** (not just the
cache), so the `snrt` boot environment matches:
1. The CachePool cluster memory map (TCDM base/size, L2/DRAM at `0x8000_0000`), 16 cores, the boot/entry.
2. The cluster **peripheral / CSR block** the snrt boot + barriers use (cluster config, wakeup, the
   `l1d_*` CSRs, the print/UART or HTIF putchar path) — currently MISSING (the gap audit flagged this).
3. The group (done) + the **L2/DDR4 channel split** (`l2_addr.hpp` scramble/NAPOT, 4 channels) on refill.
Alternative: recompile the benchmarks against the **gvsoc-spatz BSP** (so they boot the gvsoc spatz SoC) —
but then they are no longer the same binaries the RTL CI runs.

## 5. What IS validated (the structural cache model)

- `make_cachepool_fpu_512_config()` matches `cachepool_fpu_512.mk` (4 tiles, 16 cores, num_remote_port_core=2).
- The **group** routes local + cross-tile by TileID, `data_err=0` (open-loop calib, 4-tile group).
- The **single-tile** structural cache runs **closed-loop** (`vfadd` 15/15, cyc≈59001) — the cluster
  cache datapath + the synchronous-slave core are proven on a gvsoc-native kernel.
- The group is now **wired into the cluster** behind `use_cachepool_group` and **runs closed-loop on the
  full 16-core topology**: `gvsoc --target=spatz ... use_cachepool_group=True soc/cluster/nb_core=16
  --binary <vfadd>` → **15/15 PASSED, retval=0, cycles=69001** (single-tile 59001, flat 58001 — the
  16-core 4-tile group elaborates, binds, and a gvsoc-native kernel boots + executes through it
  data-correct). This proves the cluster group wiring; only the *CachePool RTL binaries* are blocked (SoC).

## 6. Recommendation

The structural cache + group are complete and data-correct. To get the **CI benchmark cycle numbers**,
the next milestone is a **GVSoC CachePool SoC target** (cores + the group + cluster peripheral/CSRs +
DDR4 L2 + the snrt-compatible boot/print) so the unmodified RTL binaries boot — a SoC-integration effort
distinct from the cache modeling. Until then, closed-loop validation uses gvsoc-native kernels (vfadd),
and per-access fidelity uses the open-loop calib trace replay vs `rtl_ref_1t_2026-06-16`.
