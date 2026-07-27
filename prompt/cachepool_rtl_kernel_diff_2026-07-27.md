# RTL-vs-GVSoC per-kernel cycle diff (16-core) — v3, ML=50 backing store

**Date:** 2026-07-27 (v3 — supersedes v2) · **Status:** provisional RTL reference (older revision sweep).
**Model:** post-R5 build (P1 + E4 + R1 loader fix + R3 B3 + R4 F1 + R5: ML=50 backing latency), 16-core
4×4, cache ON, streams cached.
**RTL reference:** `ManyRVData_rebase/reports/sweep_2026-05-29_05-54/cachepool_4t_fpu_512/logs/*.log`
(1.0 ns clock; all retval=0).

## 1. The current table (v3 — ML=50 backing store)

| Kernel | RTL cyc | GVSoC cyc | Δ | status |
|---|---|---|---|---|
| **fdotp-32b_M32768** | 48,213 | 51,001 | **+5.8%** | ✅ within ~10% |
| **gemv-opt_M512_N128_K32** | 56,448 | 54,001 | **−4.3%** | ✅ within ~10% |
| **byte-enable** | 237,889 | 225,001 | **−5.4%** | ✅ within ~10% |
| spin-lock | 68,368 | 76,802 | +12.3% | 🔶 close (B3 window + flush) |
| fdotp-32b_M8192 | 37,544 | 31,443 | −16.2% | 🔶 |
| fmatmul-32b_M32_N32_K32 | 56,689 | 46,001 | −18.9% | 🔶 |
| load-store_M16 | 101,208 | 154,935 | +53.1% | ⛔ dependent-miss regime (E3 candidate) |
| fft-32b_M1024_N16 | 130,217 | 59,001 | −54.7% | ⛔ 2.2× fast (issue-side, not memory) |
| linked-list_M1_N1350_K10 | 183,228 | 653,001 | ⛔ | 262k loader + work-phase storm (issue-side) |

**The R5 finding:** the plain backing store had **latency=0** — every miss/eviction/icache-fill paid
~nothing, so the whole miss path ran ~50 cycles too cheap vs the RTL's DRAMSys DDR4. `latency=50`
(= the RTL standalone calib responder's MemLatency) moves fdotp/gemv/byte-enable into ±6%. The
remaining outliers decompose cleanly: load-store (dependent small-miss chain — flat ML over-charges
it; E3 partitioning is the real fix), fft (2.2× fast — its gap is issue-side/burst-structure, NOT
memory), spin-lock (+12.3%, now limited by the flush cost + B3 window), linked-list (issue-side
storm + loader; not memory).

## 2. The DRAMSys path (gold check, in bring-up)

The RTL tb itself backs the L2 with **DRAMSys (4× DDR4, `ddr4-example.json`, 1 KiB interleave)** —
the [EOC] references already contain real DRAM timing. `CACHEPOOL_DRAMSYS=1` now routes the whole
DRAM range through N DRAMSys channels behind an `Interleaver` (1 KiB stripes), with the loader and
interleaver made DENIED-resilient (core `e6486d52`) and the mux clock bound. Wall-clock is
10–100× slower — use it to refine `CACHEPOOL_MEM_LATENCY` per access regime rather than for sweeps.

## 3. History

- **v1 (superseded):** narrow-AXI loader; load-store "+459.8%", linked-list "+1109.6%" (loader artifacts).
- **v2 (superseded):** wide-AXI loader; load-store +4.9%, everything else 1.6–2.9× fast, linked-list
  2.1× slow. The uniform too-fast reading was dominated by the **0-latency backing store** (§1).
- The R1 investigation trail (cache exonerated by counters → ablations → instruction trace → loader)
  is in v2's §3.

## 4. Caveats

- RTL numbers are from the **2026-05-29 sweep (`2710920`)**, not the current `05e4671a` revision —
  re-run the RTL CI before declaring <10% anywhere.
- `CACHEPOOL_MEM_LATENCY=50` is a flat first-order DRAM price; the DRAMSys path (§2) refines it.
- linked-list's EOC still carries ~262k loader cycles (16 MB `.pdcp_src`); compare work phases.

