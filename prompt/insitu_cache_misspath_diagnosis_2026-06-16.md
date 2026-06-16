# Miss-path diagnosis vs the single-tile RTL reference (2026-06-16)

Using the new single-tile RTL reference (`reports/cache_calib/rtl_ref_1t_2026-06-16/`), we did an
open-loop per-access replay of 5 kernels through the GVSoC calib model (both at MemLatency=50,
controller-view traces, per-cycle output arb) and diffed per-access latency vs the RTL `.rtl.csv`.

## Result

| kernel | RTL avg | GVSoC avg | mean Δ | **hit Δ** | **miss Δ** |
|---|---|---|---|---|---|
| idotp M8192 | 167.0 | 206.6 | +39.6 | +0.5 | +79.7 |
| fmatmul M32 | 18.6 | 29.7 | +11.0 | +6.5 | +30.7 |
| fft N4 | 20.3 | 29.0 | +8.7 | +7.5 | +17.4 |
| fdotp M8192 | 116.9 | 142.1 | +25.2 | +0.2 | +75.4 |
| gemv M512 | 110.0 | 137.4 | +27.4 | +2.8 | +75.9 |

The **hit path is faithful** (+0.2…+7.5 cy). All the error is **miss-path under deep saturation**
(these kernels are memory-bound; misses queue 5–7 deep, RTL per-miss latency 330 cy on idotp).

## Root cause (diagnosed, not the obvious candidate)

- **It is the `max_outstanding` gap (calib_report §13), NOT MSHR-full stalls / multi-read-pend.**
  GVSoC bounds outstanding misses by the **per-port requester budget** (4 VLSU lanes × 32 = **128**);
  the RTL bounds by a **cache-internal resource** (MSHR / accept depth ≈ **56**, per the 16-core
  `coal_cold out 128 vs RTL 56`). Under saturation GVSoC's miss queue is ~2× deeper → a roughly
  **constant +40…+80 cy** per-miss inflation.
- Evidence it's a steady-state queue-depth difference (not an unbounded backup): the over-prediction
  is **flat across the whole trace** (idotp ctrl-0 chunks: +62/+81/+84/+84/+94/+86/+87/+80), and the
  CALIB_REPORT shows **`max_outstanding=128`**.
- Ruled out: flipping `enable_multi_read_pend` True→ had **zero effect** (verified the flag was live in
  the dumped config) — the queue is budget-bounded, not `retr_fifo`-bounded, so the secondary-read
  merge path is irrelevant here.

## Why this is hard (the coupling / prior NO-GO)

Capping GVSoC's outstanding at ~56 to match RTL would fix the saturated per-access latency **but
regresses the matched synthetic miss-throughput** (coal_cold / cold_stream / evict) — the per-port-
budget model is exactly what makes those throughputs match RTL. This is the documented
`insitu_cache_calib_report.md §13` "coupled / NO-GO" result.

## Recommendation

The open-loop **saturated per-access latency** is a coupled, known-hard target — and it is likely an
**over-statement of the error that matters**: the real goal is the **closed-loop cycle count**, which
is driven by miss **throughput** (which IS matched ≤7%), not individual saturated latency. So:

1. **Primary:** validate **closed-loop** (`region_cyc`) against the §D RTL table — wire GVSoC cache
   refills to a DDR4-1866 DRAMSys model + the single-tile topology (P2 inc1–3) + `dynamic_offset≈6`,
   run the RTL ELFs. The matched throughput should make closed-loop cycles far closer than the +80 cy
   per-access latency suggests.
2. **Only if closed-loop cycles are off in a way attributable to outstanding depth:** then model the
   **per-resource MSHR/accept-depth cap** (P3) with the RTL's actual cap — for which we'd ask the RTL
   side for the **per-kernel `max_outstanding`** (their offered follow-up), to set the cap precisely
   rather than guess ~56.

**Net:** don't chase the open-loop saturation latency in isolation (it's the §13 NO-GO coupling); use
closed-loop cycles as the metric of record and let it tell us whether the outstanding-cap matters.
