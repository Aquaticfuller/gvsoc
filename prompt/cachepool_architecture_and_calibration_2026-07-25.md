# CachePool GVSoC model — architecture, hierarchy, and kernel performance (calibration reference)

> **CALIBRATION UPDATE 2026-07-26.** Steps 1–4 of the calibration order are now DONE and committed:
>
> 1. **Sync-slave hit/miss knobs** (core `a850fbe7`): `structural_hit_latency_cycles=10`,
>    `structural_miss_penalty_cycles=12`. Calib TB: warm hit **10** (RTL 10), cold miss **67 @ML50 / 117 @ML100**
>    (RTL ML+17). The async controller's own calibration is untouched.
> 2. **Refill-occupancy gate** (core `e2aeb60a`): per-cell `sync_refill_busy_until_` + `ml_nominal_` +
>    `structural_install_tail_cycles=3`. Cold-stream throughput **0.0143 @ML50** (RTL ~0.0149), **0.0083 @ML100**
>    (RTL ~0.0085) — was 0.0188/0.0097 (too fast). Isolated ML+17 unchanged.
> 3. **DRAMSys behind the SoC DRAM** (core `c4ad304a`, pulp `2b98759`/`4e42434`): `CACHEPOOL_DRAMSYS=1` routes
>    the cached DRAM through DRAMSys DDR4. Required fixing the **icache `IO_REQ_DENIED` refill segfault**
>    (`cache_impl.cpp` — DENIED refills were dropped but DRAMSys retried+responded → empty-queue pop). Verified
>    fdotp_M8192 completes. **Caveat: DRAMSys is 10–100× slower in wall-clock** — use small kernels / the calib
>    TB for DRAM-timing calibration. Runtime recipe in `cachepool.py`.
> 4. **xbar + cross-tile hop latency** (core config/tile/group): `xbar_latency_cycles=1`,
>    `hop_latency_cycles=1` (RTL `tcdm_cache_interco` request-side `spill_register` + group AXI `CUT_ALL_PORTS`).
>
> **Result: all 8/8 CI kernels still pass data-correct at 16-core (4×4) with the full calibration applied.**
> Calibrated 16-core cycles vs the pre-calibration baseline: spin-lock 26879 (was 25695), fdotp 87346 (86243),
> gemv 89481 (88331), fmatmul 48765 (46491), byte-enable 210777 (196355), load-store 1108280 (1105531),
> fft 57934 (57477), linked-list 4312955 (4305314). **Next (remaining): per-kernel cycle diff vs RTL QuestaSim
> `[EOC]` (the end goal — needs the RTL reference numbers), cell-coalescer modeling, DRAM-timing refinement.**

---

# CachePool GVSoC model — architecture, hierarchy, and kernel performance (calibration reference)

**Date:** 2026-07-25
**Repos:** parent `Aquaticfuller/gvsoc@main` (`cc10cca`), `gvsoc-core@insitu-cache` (`19a1797d`),
`gvsoc-pulp@insitu-cache` (`9aaa78d`), `gvsoc-engine` @ upstream `ea216770`.
**Purpose:** one document that describes (1) the current architecture and hierarchy of the CachePool
GVSoC model, (2) the measured performance of all 8 CI kernels, and (3) what is and is not calibrated —
so that cycle-accuracy work on the multi-tile (and later multi-group) model has a fixed reference.

---

## 1. Executive summary

- The model is **`gvsoc --target=cachepool`** with the InSitu L1 cache **in the data path by default**
  (`CACHEPOOL_USE_CACHE=1`). Topology is configurable: N tiles × M cores/tile × K cache banks/tile.
- **Functional status: all 8/8 CI kernels are data-correct** at the full 16-core (4 tiles × 4 cores)
  CachePool configuration; 7/8 at 4-core (fft fails there only from the core-count partition mismatch in
  the benchmark itself). This was achieved this week (four root causes fixed: HW barrier never blocked,
  shared-SPM stack collision, AMO result delivered to the wrong request buffer, plus the DiyouS-integration
  regressions).
- **Calibration status: functional correctness done; cycle accuracy NOT yet done.** The cache used in the
  target (the structural core in synchronous-slave mode) has never been calibrated against RTL — only the
  older *calibrated controller* was, and only against the standalone single-controller RTL testbench, not
  the full topology. Known approximation points are inventoried in §6 (the largest: **all crossbars
  currently add 0 cycles**, DRAM is idealized fixed-latency, no DRAMSys, refill is single-outstanding,
  cell coalescer is off, write-through only).
- The kernels print their **own mcycle-based cycle counts** ("The execution took N cycles"), which are
  meaningful in our model — these are the cleanest calibration metric against the RTL runs (§7).

---

## 2. Architecture — SoC level (`--target=cachepool`)

`pulp/cachepool.py` — a minimal CachePool SoC that boots the **unmodified** snrt CachePool CI binaries.

```
                         ┌─────────────────────────── CachePoolSoc ───────────────────────────┐
                         │  rom (bootrom @0x1000, BOOTDATA patched per topology)               │
   loader (ElfLoader) ──►│  entry → CLUSTER_BOOT_CONTROL (periph+0x20)                          │
                         │                                                                     │
                         │  narrow_axi ──┬─► wide_axi ─► HBM (cached DRAM 0x8000_0000–0xA000_0000)
                         │               ├─► uncached mem (0xA000_0000–0xBFFF_F800)             │
                         │               ├─► cluster_0 (SnitchCluster): SPM window              │
                         │               │      0xBFFF_F800–0xC000_0000                         │
                         │               ├─► cluster peripheral (0xC000_0000)                   │
                         │               └─► UART (0xC001_0000, byte sink → stdout)             │
                         └─────────────────────────────────────────────────────────────────────┘
```

Memory map (CachePool `cachepool_fpu_512` software layout):

| Region | Address | Model |
|---|---|---|
| bootrom | `0x0000_1000` | `memory.Memory`, BOOTDATA `core_count@0x44` / `tile_count@0x68` patched per topology |
| cached DRAM | `0x8000_0000 – 0xA000_0000` (512 MiB) | the region the InSitu cache fronts; backing = HBM via wide_axi |
| uncached DRAM | `0xA000_0000 – 0xBFFF_F800` | plain `memory.Memory` (atomics), **bypasses** the cache (`.pdcp_src` inputs live here) |
| SPM/TCDM | `0xBFFF_F800`, 2 KiB/core | **per-core-private** `memory.Memory` instances (matches RTL; see §4 note) |
| cluster peripheral | `0xC000_0000` | `spatz/cluster_registers` in `cachepool_mode` (barrier, EOC, boot-control, L1D scratch) |
| UART | `0xC001_0000` | `cachepool_uart` write-only byte sink → stdout |

**Peripheral registers (the correctness-critical ones):**

| Offset | Meaning | Model behaviour |
|---|---|---|
| `0x10` | `HW_BARRIER` | **real counting barrier** — each arriving core parks (`IO_REQ_PENDING`), all released when the last checks in. *(Fixed 2026-07-25: previously fell through to the regmap's `HART_SELECT_0` and never blocked — the fdotp bug.)* |
| `0x20` | `CLUSTER_BOOT_CONTROL` | regmap-backed; the loader writes the ELF entry here, bootrom reads it. |
| `0x24` | `CLUSTER_EOC_EXIT` (older layout) | write bit0 → quit with retval=bits[3:1]. |
| `0x68` | `CLUSTER_EOC_EXIT` (newer layout, DiyouS) | write bit0 → quit(0). Both layouts supported. |
| `0x28–0x4C` | L1D config (older layout) | RW scratch; `0x3C` = FLUSH_STATUS reads 0. |
| `0x00–0x2F` (exc. `0x20`,`0x24`) | perf counters (newer layout) | scratch, reads 0. |
| `0x58–0xA4` | L1D config (newer layout) | RW scratch; `0x90` = FLUSH_STATUS reads 0. |

---

## 3. Architecture — cluster level (SnitchCluster, `pulp/pulp/snitch/snitch_cluster/snitch_cluster.py`)

Per core: **Snitch scalar core (legacy v1 ISS)** + **Spatz VLSU** (`CACHEPOOL_VLSU_LANES`, default 4).

```
core c ── o_DATA ──► cores_ico[c] (Router) ──┬─► SPM window 0xBFFF_F800 → spm[c] (per-core private)
                                             ├─► cached DRAM region     → insitu_cache scalar port (lane n_ppc-1)
                                             └─► default                → narrow_axi (uncached/periph/UART/SoC)
core c ── o_VLSU(lane j) ──► vico[c][j] (Router) ─┬─► cached DRAM region → insitu_cache lane-j port
                                                  ├─► SPM window         → spm[c]
                                                  └─► default            → narrow_axi
core c ── o_FETCH ──► icache.i_INPUT(c)   (shared Hierarchical_cache; refill → cluster wide_axi)
insitu_cache.o_L2 ──► cluster wide_axi ──► o_WIDE_SOC ──► SoC wide_axi ──► HBM
cluster_registers ◄── narrow_axi (SoC) and cores_ico (per-core input, barrier/EOC/boot-control)
```

Key wiring facts (all verified this week):
- **Scalar → tile lane `n_ppc-1`** (the AMO shim lane, RTL ordering); **VLSU lanes → `0..n_ppc-2`**.
  `n_ppc = 1 + spatz_nb_lanes` (default 5). Tile port for (core c, lane j) = `c*n_ppc + j`.
- The **uncached region (`0xA000_0000+`) bypasses the cache** on both scalar and VLSU paths (default route
  → narrow_axi), so the `.pdcp_src` input arrays are never cached.
- The **shared icache** refills through the cluster `wide_axi` — the same router the cache's L2 fan-in
  uses; no interference observed.
- `cluster_registers` handles the HW barrier/EOC/boot-control as in §2. `barrier_req`/`barrier_ack`
  (CSR barrier `0x7C2`) also exist and share `barrier_status` with the MMIO barrier — a known latent
  interaction if a kernel mixes both (none of the 8 does).

---

## 4. Architecture — the InSitu cache (the model under calibration)

### 4.1 Single tile (`NB_TILE=1`)

`InsituCacheTile` (`core/models/cache/insitu/insitu_cache_tile.py`):

```
               (n_ppc per-port-class crossbars — one per lane, route BY ADDRESS)
  port p ──► xbar[p % n_ppc].in_[p // n_ppc]        # any core's lane j → any cell, address-routed
                    │
     xbar[j].out(cb) ──► per-core cache cell cb  (num_controllers = banks/tile, default = cores/tile)
                    │
   lane j<n_ppc-1 (VLSU)  ──► cell's InsituCacheCore input j          (direct)
   lane n_ppc-1 (scalar)  ──► InsituCacheAmo (AMO/LR-SC shim) ──► cell's scalar input
                    │
   cell refill + evict ──► tile o_L2 ──► cluster wide_axi ──► SoC DRAM
```

- **`InsituCacheCore`** (the structural model, `insitu_cache_core.cpp`) runs in **synchronous-slave mode**
  (`run_request_sync`): decode → hit serve / miss → evict-dirty-victim → refill (single-outstanding) →
  install → serve, all resolved in-call with `inc_latency`. Tag array: per-cell set-associative
  (factory: 4-way × 256-set × 64 B line = 64 KiB/cell).
- **`InsituCacheAmo`** (the `spatz_cache_amo` shim) sits on the scalar lane only (RTL
  `cachepool_tile.sv:658`): READ/WRITE pass through; LR/SC with a per-bank reservation; true AMOs do a
  read-modify-write through the cell and return the old value via `get_second_data()` (fixed this week).
- The xbars route a whole access to **one** cell by address (`BankSel = addr[log2(line) +: log2(banks)]`).
  **No address rotation** (`enable_rotation=False`), no cell coalescer (`cell_coalescer=False`) in this
  configuration.

### 4.2 Multi-tile group (`NB_TILE>1`, e.g. 16-core = 4×4)

`InsituCacheGroup` (`insitu_cache_group.py`): N tiles as above **plus one remote crossbar per port-class**
(`InsituCacheRemoteXbar`), giving a **cross-tile shared L1**: a core in tile A reaches a line homed in
tile B by address — the tile xbar emits the request on its remote-out slot, the remote xbar routes it to
the target tile's remote-in (source-tile-mod-N slot pinning), and GVSoC's response path auto-routes back.
Refill/evict from every cell in every tile fans into the tile `o_L2` → cluster `wide_axi` → SoC DRAM.

### 4.3 Configurable topology (env knobs)

| Knob | Default | Meaning |
|---|---|---|
| `CACHEPOOL_NB_TILE` | 1 | tiles; `>1` → `InsituCacheGroup` with remote xbars |
| `CACHEPOOL_CORES_PER_TILE` | 4 | cores per tile; `NB_CORE = NB_TILE × CORES_PER_TILE` |
| `CACHEPOOL_BANKS_PER_TILE` | = cores/tile | cache cells per tile (power-of-two) |
| `CACHEPOOL_VLSU_LANES` | 4 | Spatz VLSU lanes per core |
| `CACHEPOOL_SPM_GROUPS` | = NB_CORE | SPM instances (=NB_CORE → per-core-private, =1 shared) |
| `CACHEPOOL_USE_CACHE` | 1 | 1 = cache in the data path; 0 = direct DRAM |
| `CACHEPOOL_NB_CORE` | 4 | back-compat: 16 → 4×4, else 1 tile × N |

The bootrom's BOOTDATA `core_count`/`tile_count` is patched to match at load time (one base blob).

### 4.4 Per-core-private SPM (correctness note)

The snrt crt0 gives every hart the **same stack VA**. On the RTL the 2 KiB SPM window is physically
private per core. With a shared SPM model, all cores' stack frames collide at identical physical
addresses (trace-proven: a `_vsnprintf` saved-`ra` slot was overwritten by another core's `printf_`
frame → `ret` to `0x0` → instruction-access-fault trap). The model therefore builds **one SPM instance
per core** by default (`CACHEPOOL_SPM_GROUPS=NB_CORE`). None of the 8 CI kernels use `snrt_l1alloc`
(verified: 0 symbols), so per-core SPM is safe across the suite.

### 4.5 For comparison: `cachepool_v2` (DiyouS's multi-group target)

A **separate, additive** target (`--target=cachepool_v2`): **4×4 groups × 4 tiles/group × 4 cores/tile =
256 cores (16 groups, 64 tiles)**, raw `SnitchFast` cores + mempool `Hierarchical_cache` /
`Hierarchical_Interco` / `L2_subsystem`, a real **FlooNoc 4×4 mesh** for cross-group L1 traffic, and the
*calibrated controller* (not the structural core). It does not share our structural tile/group or AMO
lane. It is the natural vehicle for **multi-group** calibration; our `cachepool` is the vehicle for
**multi-tile** calibration at CachePool scale.

---

## 5. Latency model inventory (what every component currently charges)

| Component | Latency model today | Notes |
|---|---|---|
| `InsituCacheCore` read hit | `hit_latency_cycles` (config default **4**) | isolated; streaming warmth knob exists but OFF (`streaming_hit_latency_cycles=-1`) |
| `InsituCacheCore` write hit | hit latency + `write_commit_cycles` serialization (added latency, never DENY) | models the write-commit port |
| `InsituCacheCore` miss | `refill full_latency (from backing store) + refill_bank_write_cycles + miss_penalty_cycles`, **single-outstanding** refill (serialized miss throughput) | eviction of a dirty victim precedes the refill; write hits allocate + write-through |
| `InsituCacheAmo` | 0 added; an AMO = 2 cell accesses (RMW read + write) | atomicity is structural (single shim per cell) |
| tile `InsituCacheXbar` | **`xbar_latency_cycles = 0`** | ⚠ crossbar currently FREE |
| `InsituCacheRemoteXbar` (cross-tile hop) | **`hop_latency_cycles = 0`** | ⚠ cross-tile hop currently FREE — likely the biggest multi-tile calibration knob |
| SoC DRAM (HBM) | `memory.Memory` idealized fixed latency; bandwidth via wide_axi (64 B) / narrow_axi (8 B) | **no DRAMSys** — no realistic DRAM timing |
| uncached mem | `memory.Memory` idealized fixed latency | `.pdcp_src` path |
| SPM (per-core) | `memory.Memory`, `width_log2=2`, atomics | |
| cluster peripheral | register access +11 cyc (barrier/EOC path); EOC quit | HW barrier parks cores (`IO_REQ_PENDING`) |
| icache refill | `Hierarchical_cache` → wide_axi | shared, 1 per cluster |
| loader/bootrom | one-time; entry write + MSIP wake | |

**The two structural zeros to remember when reading cycle counts: tile xbar = 0 and cross-tile hop = 0.**

---

## 6. Kernel performance results (measured 2026-07-25)

All runs: `gvsoc --target=cachepool --binary $B/test-cachepool-<k> run`, EOC cycles from the simulator.
Correctness verified by each kernel's own check (no `Check Failed`/`Error`, correct printed result).

### 6.1 4-core (1 tile × 4), cache OFF vs cache ON

| Kernel | cache-OFF cyc | cache-ON cyc | Δ (ON−OFF) | Δ% | verdict (ON) |
|---|---|---|---|---|---|
| spin-lock | 8,710 | 10,853 | +2,143 | +24.6% | ✅ `result: 6; gold: 6` |
| load-store_M16 | 1,056,405 | 1,086,770 | +30,365 | +2.9% | ✅ |
| fdotp-32b_M32768 | 78,842 | 92,867 | +14,025 | +17.8% | ✅ |
| gemv-opt_M512_N128_K32 | 82,592 | 95,262 | +12,670 | +15.3% | ✅ |
| fmatmul-32b_M32_N32_K32 | 11,978 | 30,893 | +18,915 | +157.9% | ✅ |
| fft-32b_M1024_N16 | SIGABRT | 59,272 (retval=1) | — | — | ⛔ partition mismatch |
| linked-list_M1_N1350_K10 | rc=1 | 4,249,663 | — | — | ✅ |
| byte-enable | 5,458 | 196,001 | +190,543 | +3490% | ✅ PASSED |

### 6.2 16-core (4 tiles × 4), cache ON

| Kernel | cyc | vs 4-core ON | verdict |
|---|---|---|---|
| spin-lock | 25,695 | ×2.37 | ✅ `result: 120; gold: 120` (Σ0..15) |
| fdotp-32b_M32768 | 86,243 | ×0.93 | ✅ |
| gemv-opt_M512_N128_K32 | 88,331 | ×0.93 | ✅ |
| fmatmul-32b_M32_N32_K32 | 46,491 | ×1.50 | ✅ |
| fft-32b_M1024_N16 | 57,477 | (fails at 4-core) | ✅ **retval=0** |
| linked-list_M1_N1350_K10 | 4,305,314 | ×1.01 | ✅ |
| load-store_M16 | 1,105,531 | ×1.02 | ✅ |
| byte-enable | 196,355 | ×1.00 | ✅ PASSED |

### 6.3 Reading these numbers (calibration caveats)

1. **These are functional-model cycles, not calibrated cycles.** Do not compare them to RTL yet pointwise.
2. The cache-ON/OFF Δ mixes real cache cost (miss refills, write-through, hit latency) with the known
   model approximations of §5 (0-cost xbars, idealized DRAM, serialized refill, no coalescing).
3. `fmatmul` (+158%) and `byte-enable` (+3490%) have extreme cache-ON deltas — these are the first
   candidates for calibration analysis (byte-enable does dense sub-word stores → every store is a
   write-through hit + write-commit serialization; fmatmul is small and miss-dominated).
4. 4→16 scaling is *not* meaningful yet for most kernels (problem sizes are fixed; some kernels barely
   parallelize; the uncached-input and peripheral paths don't scale).
5. `fft` passes only at the binary's native 16-core geometry — partition mismatch at 4 cores is a
   benchmark property, not a model bug.

---

## 7. Calibration state vs RTL, and how to close it

### 7.1 What *is* calibrated (limited scope)

The **calibrated controller** (`InsituCacheController`, the *other* implementation — not the structural
core used in the cachepool target) was validated against the **standalone RTL `cache_calib` testbench**
(one controller, deterministic fixed-latency refill memory):

| Metric | RTL reference (config 512) |
|---|---|
| warm read-hit | **10 cyc isolated / 7 cyc streaming** |
| cold read-miss | **MemLatency + 17 cyc** |
| miss throughput | serialized ≈ 1/(MemLatency+17) |
| single-port hit ceiling | ≈ 0.86 acc/cyc |
| write latency / throughput | 8 cyc / ~0.49 |
| read-after-write forwarding | 7 cyc |

### 7.2 What is **not** calibrated (the structural path used in the target)

| Item | State | Impact |
|---|---|---|
| structural sync-slave hit/miss latency | measured **warm hit 9 / cold miss ML+12** vs RTL **10 / ML+17** (older comparison) | systematic ~1–5 cyc under-prediction per access |
| tile xbar latency | **0** | unknown vs RTL |
| cross-tile hop latency | **0** | unknown vs RTL — the key multi-tile knob |
| DRAM timing | idealized fixed latency, **no DRAMSys** | dominant unknown for memory-bound kernels |
| L2 refill path | flat AXI `Router` tree (not the RTL mesh/L2) | refill latency shape wrong |
| refill concurrency | single-outstanding | miss throughput serialized harder than RTL |
| cell coalescer | OFF (sync model can't batch) | VLSU burst aggregation not modeled |
| write path | write-through everywhere (`functional_writethrough`) | write-back/write-coalescing traffic not modeled |
| hash/victim select | Knuth-style hash, not the RTL scramble polynomial | set-aliasing differences possible |
| L1D partition/flush CSRs | scratch no-ops | partition/flush timing not modeled |
| uncached region | treated as ordinary memory with ideal latency | `0xA0000000` path uncalibrated |

### 7.3 The calibration metric to use: kernel-reported cycles

Every CI kernel prints its own **mcycle-based** measurement (e.g. fdotp: *"The execution took N
cycles"*; spin-lock's `result`; the perf banners). These counters are real sim cycles in our model and
correspond to the same region the RTL benchmark prints in QuestaSim. **Recommended calibration flow:**

1. Collect the RTL reference: per-kernel **kernel-reported cycles + QuestaSim `[EOC]` cycles** for the
   same 8 binaries at 16-core (and 4-core if the RTL supports it).
2. Compare against the §6 numbers, per kernel, splitting the delta into: cache-core latency (§7.2 row 1),
   refill/DRAM path (rows 3–5), xbar/hop (row 2), and peripheral/boot overhead.
3. Instrument with the structural core's built-in counters (`cnt_rd_hit_/cnt_rd_miss_/cnt_wr_hit_/
   cnt_wr_miss_/cnt_evict_/cnt_refill_`) to attribute error to hit-rate vs per-access-latency.
4. Only after single-tile numbers converge, calibrate the **cross-tile hop** (`hop_latency_cycles`) on
   16-core runs, then multi-group (v2: FlooNoc hop latencies + L2 subsystem).

### 7.4 Suggested calibration order

1. **Sync-slave hit/miss knobs** → close the 9-vs-10 / ML+12-vs-ML+17 gap on the standalone harness.
2. **Refill outstanding depth** (or a small refill pipeline) → fix serialized-miss throughput.
3. **DRAM model** — DRAMSys DDR4 behind the SoC DRAM (exists in the repo: `core/models/memory/dramsys.py`).
4. **xbar + remote-xbar hop latencies** (currently 0) — from RTL `tcdm_cache_interco` pipeline depth.
5. **Cell coalescer for VLSU bursts** — biggest structural fidelity gap for vector kernels.
6. Re-measure the §6 tables after each step and re-diff vs RTL.

---

## 8. Runbook (for the calibration runs)

```bash
cd /usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_GVSoC/gvsoc
export PATH=/tmp/py312_shims:$PATH
export CPATH="$(pwd)/third_party/elfutils-devel/root/usr/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="$(pwd)/third_party/elfutils-devel/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"

# build (multi-tile cache models compile only when the group is in the build graph)
CACHEPOOL_NB_TILE=4 CXX=g++-14.2.0 CC=gcc-14.2.0 CMAKE=cmake-3.18.1 make build TARGETS="cachepool"

source sourceme.sh
export LD_LIBRARY_PATH="/usr/pack/gcc-14.2.0-af/lib64:$LD_LIBRARY_PATH"
B=/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/software/build/CachePoolTests

# 16-core full CachePool, cache ON (the calibration configuration)
rm -f gvsoc_config.json    # ALWAYS delete after any topology/python change (no staleness check)
CACHEPOOL_NB_TILE=4 CACHEPOOL_CORES_PER_TILE=4 \
  gvsoc --target=cachepool --binary $B/test-cachepool-fdotp-32b_M32768 run

# A/B the cache (functional baseline)
CACHEPOOL_USE_CACHE=0 gvsoc --target=cachepool --binary $B/test-cachepool-fdotp-32b_M32768 run
```

Gotchas: `gvsoc_config.json` is not auto-regenerated; the `gvsoc` wrapper can swallow stdout/stderr (use
`install/bin/gvsoc_launcher --config=gvsoc_config.json` directly for reliable output); `timeout 300+` for
linked-list/load-store.

---

## 9. Open items / risks for calibration

1. **fft at non-16 core counts** — needs the partitionable SPM (per-core stack + shared heap) if small
   configs must run it; at the native 16-core geometry it passes.
2. **Multi-group calibration** belongs to `cachepool_v2` — but note v2 bypasses the AMO lane and uses the
   *calibrated controller*, not the structural core; the two targets' cycle numbers are NOT comparable
   without reconciling the cache implementations.
3. **CL_CLINT** turned out unnecessary for the current suite (linked-list passes); only needed if future
   kernels use inter-core MSI.
4. **The CSR barrier (`0x7C2`) and MMIO barrier share `barrier_status`** — a kernel mixing both would
   mis-sync; none of the 8 does.
5. All results are reproducible at the pushed commits (parent `cc10cca`, core `19a1797d`,
   pulp `9aaa78d`). Recovery refs exist if any integration step needs undoing
   (`recovery/*-pre-diyou`).
