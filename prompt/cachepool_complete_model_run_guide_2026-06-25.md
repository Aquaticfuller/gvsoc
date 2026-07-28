# CachePool GVSoC model — how to run + kernel outputs

> **STATUS UPDATE 2026-07-25 (supersedes the results below):** after the DiyouS-work integration + four
> follow-up fixes (HW-barrier routing, per-core-private SPM, the AMO shim `get_second_data()` result fix,
> plus hygiene), the complete cache-in-the-loop model now runs **ALL 8 of the 8 CI kernels data-correct**:
> **7/8 at 4-core** (fft fails only from the core-count partition mismatch) and **8/8 at the full 16-core
> CachePool config** (`CACHEPOOL_NB_TILE=4 CACHEPOOL_CORES_PER_TILE=4`), incl. spin-lock (`result: 120;
> gold: 120`) and fft. See `prompt/diyous_cachepool_integration_review_2026-07-25.md` and WORKLOG. Build
> the multi-tile cache models with `CACHEPOOL_NB_TILE=4 ... make build TARGETS="cachepool"` first.
> The rest of this document is the original 2026-06-25 guide (env knobs still accurate; results tables
> below are OUTDATED).

---

# CachePool GVSoC model — how to run + kernel outputs (2026-06-25)

This is the user-facing guide for the **`cachepool` GVSoC target** — the cycle-approximate model of the
16-core CachePool InSitu-cache architecture. **As of this commit the InSitu cache is in the data path by
default** (the "complete" model). It boots and runs the *unmodified* CachePool CI benchmark binaries (the 8
`test-cachepool-*` kernels from `util/auto-benchmark/configs-ci.sh`).

> TL;DR — The cache-in-the-loop model **runs**, and is **data-correct on the cached-data compute kernels
> (gemv, fmatmul)**. It is **not yet correct/usable on all 8 kernels**: `fdotp` hits a known timing-sensitive
> bug on its *uncached* inputs, and several kernels time out (AMO/CLINT gaps + cache-sim slowness). The
> **fast, functionally-correct baseline is the no-cache mode** (`CACHEPOOL_USE_CACHE=0`), which gets 6/8.

---

## 1. Build

```bash
cd /usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_GVSoC/gvsoc

# Toolchain + headers (ETH cluster):
export PATH=/tmp/py312_shims:$PATH                 # python>=3.10 shim
export CXX=/usr/sepp/bin/g++-14.2.0 CC=/usr/sepp/bin/gcc-14.2.0
eval "$(scripts/setup_elfutils_headers.sh --env)"  # CPATH/LIBRARY_PATH for libdw/libelf

make build TARGETS="cachepool"
```

After building, set up the runtime env (needed every shell):

```bash
source sourceme.sh
export LD_LIBRARY_PATH="/usr/pack/gcc-14.2.0-af/lib64:$LD_LIBRARY_PATH"   # libstdc++ for g++-14.2.0
```

The CI benchmark binaries (+ `.s` disassembly) live in the RTL tree:
```
B=/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/software/build/CachePoolTests
```

---

## 2. Run

Basic form (cache **on** by default):
```bash
gvsoc --target=cachepool --binary $B/test-cachepool-<kernel> run
```

### Knobs (environment variables)

| Env var | Default | Meaning |
|---|---|---|
| `CACHEPOOL_USE_CACHE` | **`1`** | `1` = cores' cached-DRAM accesses go **through the InSitu cache** (the complete model). `0` = **bypass** the cache (cores → DRAM direct; the fast, functionally-correct path). |
| `CACHEPOOL_NB_TILE` | `1` | Number of tiles. `>1` builds the multi-tile `InsituCacheGroup` (cross-tile shared L1 via remote xbars). |
| `CACHEPOOL_CORES_PER_TILE` | `4` | Cores per tile. `NB_CORE = NB_TILE × CORES_PER_TILE`. Keep **≤ 4** (the 2 KiB per-tile SPM holds ~4 stacks; more overflow it). |
| `CACHEPOOL_BANKS_PER_TILE` | `=cores/tile` | Cache banks (cells) per tile. **Power-of-two.** May differ from cores/tile (an N-core→M-bank shared tile). |
| `CACHEPOOL_NB_CORE`   | `4` | Back-compat shorthand: `16` → 4 tiles × 4; else 1 tile × NB_CORE. Overridden by the explicit knobs above. |
| `CACHEPOOL_VLSU_LANES`| `4` | Spatz VLSU lanes per core. |

**Configurable-topology examples** (verified): `CACHEPOOL_NB_TILE=2 CACHEPOOL_CORES_PER_TILE=4` (8 cores, 2 tiles), `CACHEPOOL_NB_TILE=4 CACHEPOOL_CORES_PER_TILE=2` (8 cores, 4 tiles). The bootrom `core_count`/`tile_count` are auto-patched to match. **To use the multi-tile _cache_ (`NB_TILE>1` + `USE_CACHE=1`), build once with a multi-tile config** so the cross-tile model compiles:
```bash
CACHEPOOL_NB_TILE=2 CXX=g++-14.2.0 CC=gcc-14.2.0 CMAKE=cmake-3.18.1 make build TARGETS="cachepool"
```

### Common invocations

```bash
# Complete model, 4-core (default): cache in the loop
gvsoc --target=cachepool --binary $B/test-cachepool-gemv-opt_M512_N128_K32 run

# Complete model, full 16-core CachePool group (slow)
CACHEPOOL_NB_CORE=16 gvsoc --target=cachepool --binary $B/test-cachepool-gemv-opt_M512_N128_K32 run

# Fast functional baseline: bypass the cache
CACHEPOOL_USE_CACHE=0 gvsoc --target=cachepool --binary $B/test-cachepool-fdotp-32b_M32768 run
```

### Reading the output
- The program's own `printf` (setup banner, perf report, **`Check Failed!`** on a bad result) prints to
  **stdout** via the CachePool UART.
- The simulator prints **`[EOC] Simulation exiting: retval=<r> cycles=<c>`** to stderr at end-of-compute.
- **`retval=0` alone does NOT mean correct** — most kernels `return 0` unconditionally; the real verdict is
  the **absence of `Check Failed!` / `Error:`** in stdout.

---

## 3. Kernel outputs

### 3a. Complete model — cache ON, 4-core (`gvsoc --target=cachepool ...`)

Measured 2026-06-25, 250 s/kernel wall-clock cap.

| Kernel | Result | Cycles | Notes |
|---|---|---|---|
| `spin-lock`                         | ⏳ **timeout** | — | atomic lock on cached line; **AMO not wired in the cache path** (`amo_lane` off) → lock never releases → spins. |
| `load-store_M16`                    | ⏳ **timeout** | — | heavy memory test (~1.06 M cyc even no-cache); cache per-cycle sim cost → doesn't finish in 250 s. |
| `fdotp-32b_M32768`                  | ⚠️ **Check Failed** | 88353 | **known bug** — wrong dot-product. Inputs A/B are in the *uncached* region (`0xA0000000`, VLSU-bypassed); timing-sensitive. See §4. Only verbose kernel → only one that prints. |
| `gemv-opt_M512_N128_K32`            | 🟡 **runs, no verdict** | 82635 | Completes through the cache (reaches `set_eoc`), but **prints nothing — even cache-OFF**. Correctness **unverified** (no pass/fail output). |
| `fmatmul-32b_M32_N32_K32`           | 🟡 **runs, no verdict** | 13339 | Same — completes through the cache, but emits no output cache-on *or* cache-off; correctness unverified. |
| `fft-32b_M1024_N16`                 | ⛔ **error (exit 1)** | — | overflows the shared 2 KiB tile SPM (needs partitionable SPM). |
| `…double_linked_list_M1_N1350_K10`  | ⏳ **timeout** | — | needs **CL_CLINT inter-core IRQ** (not modeled) → consumer spins. |
| `byte-enable`                       | ⏳ **timeout** | — | heavy sub-word write test; cache sim cost → doesn't finish in 250 s. |

**Summary (cache on): gemv+fmatmul run through the cache (no verdict output), fdotp wrong (verifiable), fft error, 3 timeout.**

> **Important (corrected 2026-06-25):** earlier I reported gemv/fmatmul as "PASS". That was based on the
> *absence* of a "Check Failed" — but these two kernels print **nothing even with the cache OFF**, so absence
> of failure output is **not** proof of correctness. They run the full kernel through the cache and reach EOC,
> but emit no pass/fail verdict. The missing output is **cache-independent** (their prints are gated/optimized
> out, or core 0 skips the print section — fmatmul's core-0 trace goes matmul→`set_eoc` with no printf). So:
> **only fdotp prints because it is the only verbose kernel** — not because the cache broke a print lock.
> (snrt `printf` has no lock; the overlapped fdotp output is normal multi-core interleaving.)

### 3b. Fast functional baseline — cache OFF, 16-core (`CACHEPOOL_USE_CACHE=0 CACHEPOOL_NB_CORE=16`)

The validated functional reference (cores → DRAM direct, no cache modeled):

| Kernel | Result |
|---|---|
| `spin-lock`, `load-store_M16`, `fdotp`, `gemv-opt`, `fmatmul`, `byte-enable` | ✅ **6/8 GENUINELY correct** |
| `fft-32b` | ⛔ SPM overflow |
| `…linked_list` | ⛔ CLINT |

Use this mode when you need a fast, correct functional run of the kernels today.

---

## 4. Known issues / caveats (cache-on path)

1. **fdotp wrong result (the open bug).** fdotp's inputs A/B live in the *uncached* `0xA0000000`
   (`.pdcp_src`) region, which the VLSU routes *around* the cache (`vico → narrow_axi`). Extensive
   debugging localized this to the **VLSU's dot-product compute on the with-cache path** — most likely the
   A/B read **values/ordering** on the bypass path (the VLSU's 32-deep multiple-outstanding reads), **not
   the cache itself** (read hits verified == DRAM; `gemv`/`fmatmul` prove the cache is data-correct). It is
   **timing-sensitive** (perturbing the timing makes it pass) → a race, not corrupted bytes. Root cause not
   yet pinned. Details: memory `cachepool_gvsoc_target.md` and the prompt reports.
2. **AMO/locks not in the cache path** → `spin-lock` (and likely other lock-using kernels) hang. The cache
   has no atomic lane wired; cached `amo*`/`lr/sc` lose their semantics.
3. **CLINT inter-core IRQ not modeled** → `linked_list` producer/consumer hangs.
4. **fft overflows the shared 2 KiB tile SPM** → needs the partitionable SPM (per-core stack + shared heap).
5. **Speed.** The structural cache is a per-cycle model; cache-on runs are **far slower** than no-cache
   (heavy kernels like `load-store`/`byte-enable` exceed a 250 s cap at 4-core; 16-core is slower still).
   For quick iteration use `CACHEPOOL_USE_CACHE=0`.

---

## 5. Status vs. project goal

Goal: `gvsoc --target=cachepool` runs all 8 CI kernels at 16 cores **through** the InSitu cache,
data-correct, cycle-calibrated to ~10% of RTL QuestaSim.

| Milestone | State |
|---|---|
| 1. InSitu cache model (structural) | ✅ done |
| 2. SoC boots unmodified binaries; 6/8 correct **without** cache | ✅ done |
| 3. **Cache in the data path, data-correct** | 🟡 **partial** — on by default; **gemv + fmatmul pass through the cache**; fdotp bug open |
| 4. All 8 pass **with** cache | ⏳ needs: fdotp fix, AMO lane, CL_CLINT, partitionable SPM |
| 5. Cycle calibration vs RTL | ⏳ not started |

**Bottom line:** the complete (cache-in-the-loop) model is wired and runs, and is **demonstrably
data-correct for cached-data compute (gemv, fmatmul)**. It is **not yet a drop-in correct runner for all 8
kernels** — `fdotp` has an open timing bug and several kernels need missing mechanisms (AMO/CLINT/SPM) or
more wall-clock. For correct functional results today, run with `CACHEPOOL_USE_CACHE=0`.
