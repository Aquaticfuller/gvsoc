# E4 / P2.13 — 0xA0000000 through the cache: the bypass is retired (and the M32768 bug does not reproduce)

**Date:** 2026-07-27 · **Status:** DONE, verified, committed
**Commits:** pulp `661e345` (+ parent pointer bump)
**Roadmap:** item P2.13 (gap E4) of `prompt/cachepool_architecture_gap_review_2026-07-26.md` —
the pivotal item that makes the whole calibrated cache stack kernel-visible.

---

## 1. The gap (E4)

The model routed `[0xA0000000, 0xBFFFF800)` — all `.data` + `.pdcp_src` kernel inputs — around
the cache over the shared 8 B/cyc narrow AXI into a side memory. The RTL caches the whole
0x80000000–0xBFFFFFFF DRAM range (`cachepool_pkg.sv:464-469`, one PMA rule); **0xA0000000 is the
private-bank boundary, not an uncached region**. The bypass was never a design choice — it was a
workaround for the *M32768 eviction data bug* (`snitch_cluster.py`'s own comment admitted it), so
the kernels' dominant streaming traffic ran on a different machine than the RTL, and the cache saw
none of it (no eviction pressure, no refill occupancy, no cold misses) — which is why every P1
cache fix showed ~0 kernel-cycle movement.

## 2. The change

- `cachepool.py`: `cluster.cache_region` extended from `[DRAM_BASE, 0xA0000000)` to
  **`[DRAM_BASE, SPM_BASE)`** (the full DRAM PMA minus the SPM window). Scalar + VLSU lane maps
  derive from `cache_region`, so both pick it up unchanged. Refills/evictions on the extended range
  ride the wide AXI to the already-mapped `uncached` backing memory (width_log2=6 since P1.1).
  **A/B:** `CACHEPOOL_CACHE_ALL_DRAM=0` restores the old bypass (verified: 4-core fdotp 148,248,
  data-correct).
- `snitch_cluster.py`, `cachepool.py`: the workaround comments rewritten to match reality.

Rerouting was ~10 lines; the fear was always the bug — see §3.

## 3. The M32768 eviction bug does NOT reproduce

The bug was diagnosed against a much older cache. Two of the P1 fixes plausibly eliminated its
root causes outright:

- **A1 (delayed VLSU commit)** — pre-A1 the VLSU committed bursts at issue, so vector consumers
  could read elements whose burst data hadn't logically arrived; under eviction pressure (a burst
  evicted/refilled between issue and use) that race becomes real data corruption.
- **D1 (PEND-line semantics)** — pre-D1 a follower during a refill window took an ordinary hit on
  a not-yet-installed line: under streaming pressure, same-line VLSU followers are constant.

Either is sufficient to explain "Check Failed at M32768" (input-size-proportional: bigger streams
= more eviction pressure = more mid-refill followers). Both are now fixed properly, so the
workaround is retired at the root.

## 4. Verification

### 4.1 Kernel sweeps — all data-correct, streaming kernels 45–60% faster

**4-core single tile:** fdotp_M32768 **105,468** retval=0 (bypass: 148,212, **−29%**).

**16-core (4×4), full stack (A1+E1+D1+D2+B1+C1+E4), 9/9 retval=0, zero FAIL lines**
(spin-lock `result: 120; gold: 120`, byte-enable `PASSED`):

| Kernel | post-B1/C1 (bypass) | E4 (streams cached) | Δ |
|---|---|---|---|
| fdotp-32b_M8192 | 48,902 | **26,963** | **−44.9%** |
| fdotp-32b_M32768 | 147,409 | **58,515** | **−60.3%** |
| gemv-opt_M512_N128_K32 | 154,172 | **62,427** | **−59.5%** |
| fft-32b_M1024_N16 | 109,246 | **53,514** | **−51.0%** |
| spin-lock | 26,636 | 26,636 | 0 |
| fmatmul-32b_M32_N32_K32 | 38,117 | 38,117 | 0 |
| byte-enable | 204,981 | 204,981 | 0 |
| load-store_M16 | 565,879 | 566,576 | +0.1% |
| linked-list_M1_N1350_K10 | 2,223,254 | 2,216,153 | −0.3% |

Why faster *with* the cache: the streams have cross-iteration temporal reuse the bypass threw
away (fdotp: 3 passes over A/B; fft: multi-pass; gemv: block reuse) + 64 B line refills that make
neighboring lane words free + the wide refill fabric replacing the 8 B/cyc narrow link. Note
fdotp_M32768 (58,515) now lands **below the pre-A1 "optimistic" 87,346** — with the full cache
stack active, the model is both more faithful *and* faster, because the cache finally does its job.

### 4.2 Dirty-eviction-under-rotation gate (new)

The read-only capacity trace never covered dirty evictions; `capacity_dirty_2048` (write 2048
lines, read back, 4 banks): rotation OFF → 0/2048 read-back hits (thrash) **data_err=0**;
rotation ON → **2048/2048** hits **data_err=0**. Writebacks + rotation are data-exact.

### 4.3 Calib gates

Unaffected (E4 touches pulp target files only); the structural battery stands at: isolated
67/10, cold_stream 0.0143, pend_follower 67,73,9,73,10, coal_merge 67×4/10×4/8×4 — all exact.

## 5. Consequences / follow-ups

- **The kernel cycle tables are now meaningful for RTL comparison.** Next checkpoint: per-kernel
  RTL QuestaSim [EOC] diff (needs the RTL CI numbers — E4.4).
- The `uncached` memory now serves only refill/evict traffic (+ residual narrow-AXI defaults).
  Its width_log2=6 provisioning is now on the refill path — DRAMSys (P3.1) remains the realistic
  timing answer for that path.
- E3 (`l1d_part` runtime partitioning — load-store actually calls it) and F1 (flush FSM) are now
  the highest-value remaining gaps: both are kernel-visible with the streams cached.
