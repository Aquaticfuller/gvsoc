# Multi-user linked-list (M48_N800_K300) — config sweep on the GVSoC model

**Date:** 2026-07-27 · **Model:** `--target=cachepool`, current build (post-S1 + coalescer member-mapping fix `c05b9450`)
**Kernel:** updated `multi_producer_single_consumer_double_linked_list` (multi-user: **48 UEs**, 810 B PDUs,
300 pkgs; `ManyRVData_rebase/software/tests/...`, binaries from `software/build/CachePoolTests`).
Consumer `c` owns users `{u : u % stride == c % stride}` (stride = min(consumer count, 48); producers share one
PDCP descriptor stream; aggregate consumer throughput rate-limited at OUTPUT_DATARATE = 7 MB/s.

## 1. Results (all retval=0, zero ERROR/Check-Failed lines)

| Config (binary) | Topology (tiles × cores/tile) | Active cores (P+C) | EOC cycles | Kernel work phase |
|---|---|---|---|---|
| P2/C2 (default) | 1×4 = 4 | 4 | 1,002,001 | 695,088 |
| P2/C2 (default) | 4×4 = 16 | 4 (+12 spare) | 937,001 | 538,635 |
| P2/C4 | 2×4 = 8 | 6 (+2 spare) | 850,001 | 522,554 |
| P4/C4 | 2×4 = 8 | 8 | 668,001 | 340,633 |
| P4/C4 | 4×4 = 16 | 8 (+8 spare) | 700,001 | 301,139 |
| P2/C8 | 4×4 = 16 | 10 (+6 spare) | 904,001 | 505,146 |
| P4/C8 | 4×4 = 16 | 12 (+4 spare) | 648,001 | 250,210 |
| `_sc` (RLC_SELF_CHECK=1) | 4×4 = 16 | 4 (+12 spare) | 938,001 | 538,613 |

The `_sc` self-check build matches the default P2/C2 run (work 538,613 ≈ 538,635, same path) — the
self-test path adds no measurable overhead.

## 2. What the numbers say (scaling behavior)

- **Producers are the first bottleneck.** At 2×4 with 4 consumers: 2 producers 522,554 → 4 producers
  340,633 = **1.53× faster**; adding consumers on top of too few producers barely helps (P2C4 522,554 vs
  P2C8 505,146 = +3%).
- **Consumers pay off once producers suffice.** At 4 producers (4×4): 4 consumers 301,139 → 8 consumers
  250,210 = **+20%**; best config overall: **P4/C8, work phase 250,210 = 2.15× the P2/C2 baseline**.
- **Tile count helps even with the same active cores.** P4/C4 at 2×4 (340,633) vs 4×4 (301,139) = **+13%**,
  and P2/C2 at 1×4 (695,088) vs 4×4 (538,635) = **+29%** — more tiles = more cache banks under the same
  48-user lock/list working set (less per-bank contention), while spare cores idle at the barrier.
- **EOC minus work ≈ ~0.4–0.4M cycles everywhere**: the ELF load (~11.7 MB `.pdcp_src` over the wide AXI,
  ~180k) + boot + the final barrier/drain — the known loader artifact, same as the M1 kernel (R1).

## 3. The model crash this sweep found (and fixed) — core `c05b9450`

The **1×4 (4-core) config segfaulted the simulator** (SIGSEGV, no output). Root cause: the coalescer's
merge-group member mapping matched parked requests by **port alone** — but the coalescer input index is
the *port-class*, so different cores' lane-j accesses arrive with the **same** port (and one core can
queue two same-cycle same-port bursts). One req got claimed by two groups → responded **twice** → the
VLSU's `data_response` popped 4 args from an empty stack → SIGSEGV. Fix: match only unconsumed (`!done`)
requests so each parked request lands in exactly one group. Verified: coal_merge gate exact
(67×4/10×4/8×4, data_err=0), 16-core fdotp unchanged (55,440), the 4-core M48 run now passes
(1,002,001 cycles). **This is the class of bug only a new traffic pattern (48-user, 810 B PDUs) could
have exposed — exactly what these sweeps are for.**

## 4. Notes / caveats

- The kernel's self-check print (`[self test] SUMMARY`) appears only in the `_sc` build's log; all runs
  are retval=0 with zero `ERROR`/`Check Failed` lines (the kernel's own integrity paths).
- The `_g` build (`RLC_NODE_GUARD=1` debug instrumentation) not run — it's a debug variant of P4/C8.
- K1000 variant (1000 pkgs) not run (much larger loader + runtime); K10/K100/K300 (M1 single-user) remain
  from the earlier sweeps.
- Loader time (~180k cycles) is included in every EOC figure — subtract when comparing work phases.
