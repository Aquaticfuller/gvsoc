# Weekly Report — GVSoC InSitu L1 Cache Model

**Period:** 2026-06-22 (Mon) → 2026-06-26 (Fri)
**Engineer:** Zexin Fu
**Area:** GVSoC CachePool model. Last week built the structural cache rewrite + a MINIMAL `gvsoc --target=cachepool` that boots the unmodified snrt CI binaries (see `weekly_report_2026-06-22.md`). **This week** took it forward on four axes: the **FULL 16-core** path, putting the InSitu cache **IN the data path** (the "complete" model, ON by default), an **AMO-lane fix** for cross-core atomics, and a **configurable Tile/Group topology**.

---

## TL;DR

Five workstreams, each building on the last:

1. **FULL 16-core CachePool path (no-cache).** Fixed the 16-core boot via a **per-tile-shared SPM** (the correct CachePool organization — a single shared 2 KiB SPM corrupts 16 stacks; fully per-core breaks shared `l1alloc`). Result: **6 of the 8 CI kernels are GENUINELY correct** — verified by the *printed* `Check Failed!`/`Error:` absence, not just `retval=0` (most kernels `return 0` unconditionally). fft + linked-list still fail (SPM-overflow / CL_CLINT).

2. **Cache IN the loop — the "complete" model, ON by default.** Wired the structural InSitu cache to front the cached-DRAM region; the VLSU's *uncached* inputs (`0xA0000000`) are address-routed to bypass it. With the cache on, **gemv + fmatmul run through the cache**; **fdotp Check-Fails** — a deeply-investigated, **timing-sensitive cross-core data** bug. Eliminated (with evidence) eviction-pressure, the eviction writeback, cross-line truncation, 4-lane concurrency, and the cache read/write/refill data path — all ruled out; the failure is a race (perturbing the timing makes it pass).

3. **Print-output investigation — a correction.** "Only fdotp prints" is **NOT a broken cache lock**: gemv/fmatmul print **nothing even with the cache OFF** (verified), so their silence is cache-independent; and snrt `printf` has **no lock** (the overlapped output is normal multi-core interleaving). fdotp is simply the one verbose kernel, and it has the real data bug.

4. **AMO-lane fix — cross-core atomic mutex.** The "1 core OK, 2+ cores broken" signature = a broken cached atomic. Found + fixed **two** real bugs: (a) the AMO/LR-SC shim was async-only and **double-completed → SIGABRT** on the synchronous cachepool core; (b) the scalar core was wired to the **wrong tile lane**, so the AMO shim never saw its atomics. **The cross-core lock now works** — a cell-level trace proves a clean Core0-release → Core1-acquire ping-pong. spin-lock still doesn't *finish*, but for a **separate** reason (below).

5. **Configurable topology.** `CACHEPOOL_NB_TILE` × `CACHEPOOL_CORES_PER_TILE` × `CACHEPOOL_BANKS_PER_TILE`; `NB_CORE` derived; the bootrom `core_count`/`tile_count` auto-patched from one base blob. **Verified:** no-cache 2 tiles×4 and 4 tiles×2 both run to EOC; **with-cache 2 tiles×4 gemv runs to completion** — the multi-tile cache (cross-tile remote xbars + per-tile AMO) boots and runs.

**Unifying open finding:** the single remaining correctness bug is **cross-core shared-(non-atomic)-data visibility** — the same mechanism behind *both* fdotp's wrong `result[]` reduction *and* spin-lock not terminating (its shared counter, incremented under the now-working lock, doesn't converge). The atomic **lock is fixed**; the **topology works**; this data-visibility issue is the next target.

**Accuracy caveats (non-overclaiming).** (i) gemv/fmatmul "run through the cache" + emit no `Check Failed`, but they print **no pass/fail verdict at all** (silent by build), so their correctness through the cache is **not independently confirmed** — only fdotp is verifiable, and it is wrong. (ii) The structural cache is a **per-cycle** model → cache-on runs are far slower than no-cache (heavy/lock kernels exceed practical timeouts). (iii) **No cycle calibration** against RTL yet. (iv) `cores/tile ≤ 4` (the 2 KiB per-tile SPM holds ~4 stacks). (v) The multi-tile *cache* models compile on-demand → build once with `CACHEPOOL_NB_TILE≥2`.

---

## What was done

### 1. FULL 16-core CachePool path (no-cache) — 06-23

Extended the MINIMAL 4-core target to 16 cores. The blocker was the SPM: the snrt crt0 gives **every** hart the same stack VA, so a single shared 2 KiB SPM collides 16 stacks (spin-lock/fft hang), while a fully per-core SPM breaks shared `l1alloc`. Fix = **per-TILE-shared SPM** (`spm_num_groups = NB_TILE`): cores in a tile share one SPM, tiles have separate SPMs — exactly the CachePool organization. Patched the bootrom BOOTDATA to `core_count=16, tile_count=4`.

**Result — 6 of 8 CI kernels GENUINELY correct** (verified by the *printed* result, correcting the prior `retval=0`-only read, since the kernels `return 0` regardless): spin-lock, load-store_M16, fdotp, gemv-opt, fmatmul, byte-enable. fft and linked-list still fail (fft = SPM overflow needing a partitionable SPM; linked-list = needs CL_CLINT inter-core IRQ).

### 2. Cache in the data path — the "complete" model, ON by default — 06-23…06-25

Wired the structural InSitu cache (single tile / group) to front the cached-DRAM PMA `[0x80000000, 0x84000000)`; the SPM/stack stays direct (per-tile), refills route via the cluster wide_axi → SoC DRAM. **Made it ON by default** (`CACHEPOOL_USE_CACHE=1`) so `--target=cachepool` *is* the complete CachePool model; `=0` bypasses for the fast functional path. Address-routed the **VLSU lanes** so the *uncached* input arrays (`dotp_A/B` @ `0xA0000000`) bypass the cache (else they were wrongly cached, creating input-size-proportional eviction pressure).

**fdotp data-correctness investigation (extensive).** fdotp Check-Fails with the cache. Ruled out, each with evidence: eviction-pressure (the cache gets ~40 accesses, `evict=0`); the eviction writeback (gating it off didn't fix); cross-line truncation (the guard never fires); 4-lane concurrency (1 lane still fails); the read/write/refill **data path** (an ungated served-vs-DRAM check found no mismatch). The failure is **timing-sensitive** — adding benign latency makes it **pass** — i.e. a deterministic *race*, not corrupted bytes. Localized to the only cross-core cached interaction: the `result[]` write → barrier → core-0 reduction-read.

### 3. Print-output investigation — correction — 06-25

User-reported "only fdotp prints; the others' locks look broken." Traced it: snrt `_putchar` is a bare store to the UART (uncached peripheral) with **no lock**, so multi-core output interleaves by design (not a bug). gemv/fmatmul print **nothing even cache-OFF** (verified), so their silence is **cache-independent** (their banners are gated/compiled-out / core-0 skips them). Net: the cache did **not** break printing or locks; fdotp is just the verbose kernel and carries the real data bug.

### 4. AMO-lane fix — cross-core atomic mutex — 06-25

The signature **1 core correct / 2+ cores broken** is the textbook broken-cached-atomic symptom (snrt mutex = `amoswap` on a cached lock word). Root-caused + fixed two bugs:
- **Shim sync/async mismatch (SIGABRT).** The `spatz_cache_amo` shim was written for the async Spatz cache: it issues a sub-read/sub-write and, on the response, calls `resp()` while `req_handler` returns `PENDING`. On the **synchronous** cachepool core the whole RMW resolves in-call, so it `resp()`-ed **and** returned PENDING → double-completion → abort (only on true-AMO kernels like spin-lock). Fixed by returning `IO_REQ_OK` (no `resp()`) when the RMW completes synchronously.
- **Scalar mis-laned.** The AMO/LR-SC shim sits on tile lane `n_ppc-1` (RTL ordering: scalar = last lane), but the cachepool wired the scalar to lane 0, so the shim never mediated the scalar's atomics. Enabled `amo_lane` and re-laned the scalar to `n_ppc-1` (VLSU to `0..n_ppc-2`).

**Validated (cell trace):** Core0 acquires (`old=0`), releases (write 0); Core1 then reads 0 and acquires — a **clean cross-core ping-pong on the single shared cell**. So the atomic lock is correct. **However** spin-lock 2-core still doesn't *complete* (>3.3 B cycles vs 5851 no-cache): the shared **counter** incremented under the (working) lock isn't converging the loop — a **separate cross-core shared-data** issue, the same class as fdotp, *not* the lock.

### 5. Configurable topology — 06-25

Generalized the hardcoded "16 → 4×4, else 1 tile" into env knobs: `CACHEPOOL_NB_TILE`, `CACHEPOOL_CORES_PER_TILE`, `CACHEPOOL_BANKS_PER_TILE` (cache cells per tile; power-of-two; default = cores/tile; may differ from cores → an N-core→M-bank shared tile). `NB_CORE = NB_TILE × CORES_PER_TILE`. The bootrom `core_count`(@0x44)/`tile_count`(@0x68) is **patched from the one base blob** for any topology. `NB_TILE>1` → the multi-tile `InsituCacheGroup` (cross-tile shared L1 via remote xbars); else a single structural tile. The group path now builds its config from the requested topology (was hardcoded 4×4) and the single-tile path uses `banks_per_tile` (with `interco.num_outputs` tracking it for correct N→M routing). Back-compat: `CACHEPOOL_NB_CORE=16` → 4×4.

---

## Validation / scorecard

**No-cache FULL 16-core — unmodified snrt CI binaries (6/8 genuinely correct):**

| kernel | verdict | kernel | verdict |
|---|---|---|---|
| spin-lock | ✅ correct | fmatmul-32b | ✅ correct |
| load-store_M16 | ✅ correct | byte-enable | ✅ correct |
| fdotp-32b | ✅ correct | fft-32b | ⛔ SPM overflow |
| gemv-opt | ✅ correct | …linked-list | ⛔ needs CL_CLINT |

**With-cache (complete model, 4-core):**

| kernel | result | note |
|---|---|---|
| gemv-opt | runs through cache, no `Check Failed` (silent) | correctness not independently verifiable |
| fmatmul-32b | runs through cache, no `Check Failed` (silent) | " |
| fdotp-32b_M32768 | ⚠️ **Check Failed** (88353 cyc) | the open cross-core data bug (uncached A/B + result[] reduction) |
| fft / spin-lock / load-store / linked-list / byte-enable | error / timeout | SPM/CLINT gaps + cache-sim slowness |

**Configurable topology (verified):**

| config | cache | result |
|---|---|---|
| 2 tiles × 4 (8 cores) | off | ✅ EOC (77104 cyc) |
| 4 tiles × 2 (8 cores) | off | ✅ EOC (76973 cyc) |
| 2 tiles × 4 (8 cores) | **on** | ✅ **EOC (77276 cyc)** — multi-tile cache + remote xbars work |
| 1 tile × 8 | off | ⛔ 2 KiB SPM overflow (8 stacks) — cores/tile ≤ 4 |

**AMO-lane fix:** spin-lock crash → fixed; single-core mutex prints cleanly; gemv/fmatmul unaffected; cross-core lock visibility **proven correct** by the cell trace (clean acquire/release ping-pong). Open: spin-lock test still doesn't terminate (cross-core counter, separate from the lock).

---

## Commits this week

`core` (gvsoc-core) / `pulp` (gvsoc-pulp), branch `insitu-cache` on the `Aquaticfuller/*` forks; **parent submodule-pointer bump committed + pushed this week** (`f9ebafd`).

| Repo | SHA | Subject |
|---|---|---|
| pulp | `66ebb3c` | cachepool: 16-core FULL config — per-core-private SPM + 16-core bootdata |
| pulp | `5ec8cb6` | cachepool: per-TILE-shared SPM (the correct 16-core organization) |
| core | `0757b944` | insitu-cache: warn on cross-line access in exchange_line_data (defensive) |
| pulp | `2867db2` | cachepool: WIP cache-fronting-DRAM path (gated, default off) |
| pulp | `e076efc` | cachepool: address-route the VLSU lanes (uncached bypasses the cache) |
| pulp | `c3f45d7` | cachepool: cache-in-the-loop ON by default (the complete CachePool model) |
| pulp | `6849c06` | cachepool: enable the InSitu-cache AMO lane + re-lane the scalar to lane n_ppc-1 |
| core | `4341bbcc` | insitu-cache: AMO shim — return OK (not PENDING) when the RMW resolves synchronously |
| pulp | `419f43d` | cachepool: configurable topology — N tiles × M cores/tile × K banks/tile |
| parent | `f9ebafd` | cachepool: bump core + pulp submodule pointers (committed + **pushed** to `main`) |

(The 06-22 MINIMAL-SoC / structural-rewrite commits were covered in `weekly_report_2026-06-22.md`.)

---

## Docs / reports produced

- `prompt/cachepool_complete_model_run_guide_2026-06-25.md` — **user-facing how-to-run guide**: build/run, all env knobs (incl. the new topology knobs), per-kernel outputs, caveats, status vs. goal.
- `prompt/WORKLOG.md` — running dev log (this week's entries appended).
- Updated `prompt/insitu_cache_architecture_v2.md` (kept current with the model changes).

---

## Open items / next

- **[BIGGEST OPEN] Cross-core shared-(non-atomic)-data visibility** — the unifying root cause behind *both* fdotp (wrong `result[]` reduction) *and* spin-lock not terminating (its shared counter). The atomic lock is fixed and the cell is genuinely shared, yet a non-atomic write by one core isn't promptly visible to another core's read in the per-cell synchronous model. Fixing this likely fixes both kernels. Next: instrument the shared counter / `result[]` cell the way the lock cell was instrumented (cyc, core, rw, value) to expose the visibility/timing mechanism.
- **Cycle calibration vs RTL QuestaSim `[EOC]`** — still the end goal; not started for the cachepool path.
- **CachePool FULL gaps** — partitionable SPM (fixes fft + lifts the cores/tile ≤4 limit), CL_CLINT inter-core IRQ (fixes linked-list).
- **Multi-tile cache build ergonomics** — the cross-tile `remote_xbar` model compiles only when the build graph includes the group; either always-compile it or document "build once with `CACHEPOOL_NB_TILE≥2`" (currently documented in the run guide).
- **Verify gemv/fmatmul through the cache** — they're silent, so use a memory-checksum (cache-on vs cache-off result arrays) rather than their absent prints.
