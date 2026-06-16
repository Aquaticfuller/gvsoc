# Request to the RTL side — reference data for GVSoC closed-loop cache-model validation (2026-06-15)

## Why (1 paragraph)
We have a cycle-approximate GVSoC performance model of the CachePool InSitu L1 D-cache. It is already
calibrated **open-loop** (we replay the per-controller `replay_batch_2026-06-12` traces through the
same fixed-latency memory model and match per-access latency). We are now validating it **closed-loop**
(real Spatz kernels running end-to-end) and need an apples-to-apples **RTL reference cycle count** at a
topology the GVSoC model can match. The model currently builds a **single tile**, so the near-term
target is a **single-tile RTL run**. This doc lists exactly what we need so the comparison is valid.

---

## A. PRIMARY ask — single-tile (4-core) reference run

Please run the InSitu-cache cluster in the **single-tile** configuration and report the data in §C/§D.

### A1. Configuration to use (please CONFIRM the actual values you ran with)
- **Topology:** `NumTiles = 1`, `NumCores = 4` (`NumCoresTile = 4`) — i.e. `config/cachepool_1t.mk`
  (or `num_tiles=1 num_cores=4` however you parameterize it). One L1 D-cache **per core**
  (`NumL1CacheCtrl = NumCores = 4`).
- **Refill regime — IMPORTANT:** use the **committed `refill_data_width = 128` ⇒ `BurstLength = 4`**
  (single-outstanding) regime — i.e. the calibrated/shipping config, **NOT** the local 512-bit
  `BurstLength = 1` experiment that sits as an uncommitted edit in `config/cachepool_512.mk`. Please
  confirm `refill_data_width` and the resulting `BurstLength`.
- **Cache geometry:** confirm `L1LineWidth` (512?), `SetAssociativity` (4?), `L1NumEntryPerCtrl`
  (entries per controller), `L1BankFactor` (=2?), folded/hash-way/forwarding-buffer enabled,
  `WriteThroughMode` (=0 / write-back?).
- **Bank mapping / partition:** confirm the L1 is **all-shared** (no `num_private_cache` partition
  active), and report the **runtime `dynamic_offset` (a.k.a. `xbar_offset`) value** the SDK/boot code
  actually programs before the kernel runs (the HW FF resets to 5'd14 — does boot change it? whatever
  the kernels see, we need that number so our address→bank routing matches).
- **Refill / next-level latency — CRITICAL for cycle matching:** report the **effective L1-miss refill
  latency in cycles** (request→first-data and the per-beat gap), and where refills are served from
  (TCDM-resident? an L2$? DRAM/HBM?). This is the single biggest knob for matching cycle counts; we set
  the GVSoC memory model to the same value.

### A2. Kernels to run + the binaries
Run the **same kernels** we already have per-access traces for (so workload + sizes match exactly):
- `vfadd` (sanity / smoke)
- `fmatmul` at **M=N=K=32** and at **M=N=K=128**
- `fft` (M=1024, N=16)
- `gemv` (M=512, N=128, K=32)
- `fdotp` (M=8192)

**Please attach the exact ELF binaries (or their build hashes) + the input sizes used**, so we run the
*identical* binaries in GVSoC. If these are the same builds that produced `replay_batch_2026-06-12`,
just confirm that.

---

## B. SECONDARY ask — full-system (16-core, 4-tile) totals (only if cheap)
For the eventual full-system diff (once our multi-tile model lands), the **total end-to-end cycle count
for the existing 16-core `replay_batch_2026-06-12` runs** would be ideal — we already have those
per-access traces, so we just need the **whole-kernel cycle count** of those same runs (no new run
needed if you logged it). Same config dump as §A1 but for `NumTiles=4 / NumCores=16`.

---

## C. Cycle-counting convention (so we measure the same thing)
Cycle counts only compare if we bound the same region. Please report, per kernel, **whichever of these
you have** and **say which one**:
1. **Kernel-region cycles** — `mcycle` (or the perf counter) delta around the kernel hot loop, if the
   benchmark instruments it. *(Preferred — excludes boot/setup differences.)*
2. **Total cycles to end-of-computation** — full program to EOC / `tohost` write.

If the benchmark already prints a cycle number, just tell us what region it covers.

---

## D. Data to capture, per kernel (a small table is perfect)

| kernel | size (M/N/K) | **cycles** (which region?) | rd acc | wr acc | hits | misses | refills (L2 rd) | writebacks |
|---|---|---|---|---|---|---|---|---|

- **cycles** is the headline. The cache counters (hits/misses/refills/writebacks) let us cross-check
  that our model reproduces the *cache behaviour*, not just the bottom-line cycle — and localize any
  mismatch to hit-path vs miss-path.
- If per-core counters are easy, per-core is a bonus; aggregate is fine.

---

## E. Summary of what to send back
1. The §A1 config values (a short list, confirming the ones we guessed).
2. The §A2 ELF binaries (or build hashes) + input sizes.
3. The refill/next-level latency (§A1, the critical number).
4. The §D per-kernel table (single-tile/4-core primary; 16-core if cheap), stating the cycle-region
   convention (§C).

That's everything — with this we can run the identical binaries in GVSoC at the matching single-tile
topology, set the same memory latency, and diff cycle counts (and cache stats) directly. Thanks!
