# RTL-vs-GVSoC per-kernel cycle diff (16-core) — v2, loader-artifact-aware

**Date:** 2026-07-27 (v2, supersedes the morning's v1 table in this file's §A) · **Status:** provisional
RTL reference (older revision sweep); model post-R1.
**RTL reference:** `ManyRVData_rebase/reports/sweep_2026-05-29_05-54/cachepool_4t_fpu_512/logs/*.log`
(insitu-cache `2710920`, 4-tile/16-core fpu_512; `ClockPeriod = 1.0ns` → cycles = EOC-time/1000; all
retval=0).
**Model:** post-R1 build (A1+E1+D1+D2+B1+C1+E4 + wide-AXI ELF loader), 16-core 4×4, cache ON, streams
cached.

## 1. The current table (v2 — wide-AXI loader)

| Kernel | RTL cyc | GVSoC cyc | Δ | verdict |
|---|---|---|---|---|
| **load-store_M16** | 101,208 | 106,129 | **+4.9%** | ✅ **within target** |
| byte-enable | 237,889 | 203,001 | −14.7% | ✅ close |
| fdotp-32b_M32768 | 48,213 | 28,001 | −41.9% | ⛔ 1.7× fast |
| fdotp-32b_M8192 | 37,544 | 17,997 | −52.1% | ⛔ 2.1× fast |
| gemv-opt_M512_N128_K32 | 56,448 | 31,770 | −43.7% | ⛔ 1.8× fast |
| fmatmul-32b_M32_N32_K32 | 56,689 | 35,329 | −37.7% | ⛔ 1.6× fast |
| spin-lock | 68,368 | 25,265 | −63.0% | ⛔ 2.7× fast (B3) |
| fft-32b_M1024_N16 | 130,217 | 44,752 | −65.6% | ⛔ 2.9× fast (F1 + issue-side) |
| linked-list_M1_N1350_K10 | 183,228 | 376,919 | +105.7% | ⛔ 2.1× slow — **but 262k of it is the 16 MB loader**; ex-loader −37% fast |

**The picture after R1:** the "model 5–12× too slow" readings were the ELF-loader artifact (§2).
Corrected, the model is **uniformly too FAST** (1.6–2.9×) except load-store (+4.9%, in target).
The too-fast family maps to the review's issue-side/occupancy gaps: B3 (AMO free), F1 (flush free),
B2 (xbar arbitration free), J1/I-items (scalar LSU + VLSU issue geometry / MLP), C2, G-refill
overlap. Attack order: **R3 (B3, spin-lock) → R4 (F1, fft) → R5 (issue-side: J1 scalar LSU
outstanding + VLSU width/I-items) → R2 (E3 partitioning, deprioritized: load-store is in-target)
→ DRAM timing (P3.1)**.

## 2. The R1 finding — the ELF-loader artifact (why v1 was wrong)

GVSoC's `ElfLoader` writes ELF segments through the interconnect as real IO requests. Pre-R1 it rode
the **narrow AXI (bw=8)**: load time ≈ `section_bytes / 8` cycles *before any instruction executes* —
invisible unless you compare against a simulator whose load is free (RTL fesvr/DPI ≈ 0 cycles).

| Kernel | .pdcp_src | narrow-loader cost | share of the old total |
|---|---|---|---|
| linked-list_M1_N1350_K10 | 16.8 MB | **~2.10M cyc** | **95%** of 2.22M (the "12× slow" anomaly) |
| load-store_M16 | 3.0 MB | ~393k | **69%** of 566k (the "5.6× slow" reading) |
| gemv-opt_M512 | 258 KB | ~33k | 52% of 62k |
| fdotp-32b_M32768 | 256 KB | ~33k | 56% of 59k |
| fdotp-32b_M8192 | 64 KB | ~8k | 30% of 27k |
| fft | 64 KB | ~8k | 15% of 54k |

Fix (pulp `f4df56c`): loader → wide_axi (bw=64) + catch-all map (entry write still reaches the
peripheral). Residual load time = bytes/64 (linked-list 262k — its EOC still can't be compared
directly; use its kernel phase prints: **model work 38,040 vs RTL 70,480 = 1.85× fast**).

### v1 table (superseded — kept for the record, narrow-AXI loader)
gemv +10.6% · byte-enable −13.8% · fdotp M32768 +21.4% · fdotp M8192 −28.2% · fmatmul −32.8% ·
fft −58.9% · spin-lock −61.0% · load-store **+459.8%** · linked-list **+1109.6%** — the last two were
loader-dominated; the rest shift by §2's amounts.

## 3. How the anomaly was pinned (R1 investigation trail)

1. Cache counters at stop(): L1 91% hits, all L1+AMO latency ≈ **2.3%** of the anomalous cycles →
   cache exonerated (not capacity, not D1/B1/winfo, not AMO cost — AMOs are ~free, the B3 gap).
2. Ablations: 16≈8≈2 cores (not contention), VLSU lanes 4→1 (+1%, not the vector path), coalescer
   on/off (identical).
3. Instruction trace (libdw symbolization): cores execute **zero instructions** for the first
   ~2.1M cycles, then the whole kernel runs in the last ~35k → something *before* the cores starts
   dominates.
4. Kernel's own prints: `[core 0]: start=2,103,820 end=2,127,952 total=24,132` — the work phase is
   ~24k cycles; and `.pdcp_src` = 16.8 MB ≈ 2.1M cycles at 8 B/cyc → **the loader**.
5. RTL log cross-check: RTL work phase ≈ 70,480 (16-core) — model 1.85× fast on the real work.

## 4. Caveats

- RTL numbers are from the **2026-05-29 sweep (`2710920`)**, not the current `05e4671a` revision —
  re-run the RTL CI before declaring <10% anywhere.
- The RTL total includes its own ~103k epilogue tail on linked-list (UART flush etc.); where a kernel
  prints phase boundaries (linked-list only), compare work phases.
- The remaining loader residual (bytes/64) still affects load-store (~49k) and linked-list (~262k)
  EOC totals; a true backdoor loader is the clean end-state.
