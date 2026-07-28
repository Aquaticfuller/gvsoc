# InSitu Cache — Pre-Calibration Structural Gap Audit (2026-06-16)

**Question:** before starting calibration, is any structure left not-properly-implemented?
**Answer: yes — substantially.** Every *component datapath* is transcribed + standalone-validated, but
the *integration* is almost entirely still ahead: only **2 of 18** audited structures actually run their
RTL logic in a runtime path, and even those run only on the **open-loop calib testbench**, not the
closed-loop cluster. Several mechanisms are **missing entirely** (write-through merger, peripheral/flush
controller, group/cluster composite), and a few **approximations would silently bias calibration**.

Method: 18 structures, each **read → adversarially re-verified** by an independent agent (38 agents), plus
an RTL-universe enumerator and a completeness critic. All wiring claims confirmed by `grep`/`#include`.

---

## Verified status table

| # | Structure | Status | In runtime? |
|---|---|---|---|
| 1 | decode/encode (`insitu_cache_decode.hpp`) | **faithful_wired** | yes — but only via structural core on the **calib** path |
| 2 | pseudo-dual-port bank (`bank_array.hpp`) | approximated | partially (WR-conflict only; access-ctrl FSM not modeled) |
| 3 | forwarding buffer (`fwd_buffer.hpp`) | **faithful_not_wired** | no (`#include`d by nothing) |
| 4 | core 2-stage pipeline + 7-state FSM | approximated | structural core wired (calib only); FSM collapsed to retry |
| 5 | in-situ MSHR | approximated | structural core only; subarray/MRP accounting partial |
| 6 | refill/eviction + single-outstanding | approximated | **refill latency does not emerge** (the known finding) |
| 7 | par_coalescer CSHR (`coalesce.hpp`) | **faithful_not_wired** | no — tile runs old approximate coalescer/interco |
| 8 | rsp splitter / non_coalescer | **faithful_not_wired** | no |
| 9 | programmable xbar + rotation (`route.hpp`) | **faithful_not_wired** | no — **no config path runs it, even structural** |
| 10 | SPM remap (`spm_remap.hpp`) | approximated | controller does a power-of-2 fold; faithful div/mod not wired |
| 11 | flush/sync FSM (`sync_fsm.hpp`) | **faithful_not_wired** | no — flush is a 0-cycle stub; cluster never drives i_FLUSH |
| 12 | AMO / LR-SC (`amo.hpp`) | **faithful_not_wired** | no — runtime carries no AMO metadata at all |
| 13 | L2 scramble/NAPOT + DDR4 (`l2_addr.hpp`) | stubbed_partial | no — refill hits a flat responder; no scramble, no DRAMSys |
| 14 | tile composite (`cachepool_tile`) | approximated | flat single tile, 1 hashed interco (not 5 per-port-class) |
| 15 | group/cluster composite | **missing** | no group/cluster layer exists |
| 16 | peripheral / CSR / flush ctrl / l1d_busy | **missing** | nothing modeled |
| 17 | cluster synchronous-slave mode | **faithful_wired** | yes — but lives ONLY in the approximate controller; **structural core lacks it** |
| 18 | write mode / winfo FIFO | approximated | scalar rate, **disabled by default** (write backpressure absent in cluster cfg) |

Counts: approximated ×7 · faithful_not_wired ×6 · faithful_wired ×2 · missing ×2 · stubbed_partial ×1.

**Headline reframe:** "all component datapaths transcribed" is true, but *transcribed ≠ in the runtime*.
Of the 7 structural-rewrite header components, **only `decode.hpp` + `bank_array.hpp` are `#include`d by
any compiled `.cpp`** (the structural core). The other five (`fwd_buffer`, `coalesce`, `route`,
`spm_remap`, `sync_fsm`, `amo`, `l2_addr` = seven headers) are `#include`d by nothing. And even
`use_structural_core=True` still instantiates the **approximate** `InsituCacheInterco` (hash router) +
old coalescer — so routing/coalescing/SPM/flush/AMO/L2 are approximate-or-absent on every path today.

---

## A. Calibration BLOCKERS (must close before structural calibration is meaningful)

1. **No closed-loop driver for the structural model.** The structural `InsituCacheCore` is async
   park+resp only (`core.cpp:199-207`); it has no synchronous-slave run-to-completion mode, and
   `use_structural_core` is set in exactly one place — the calib testbench, behind
   `INSITU_CALIB_STRUCTURAL_CORE` (default off). `snitch_cluster.py` has **zero** references to it. So the
   headline closed-loop `region_cyc` calibration can today run **only on the approximate controller**.
   → add the sync-slave inline mode (master-plan must-fix #1) + wire `use_structural_core` into the cluster.
2. **Six faithful components are wired into nothing** (`fwd_buffer`, `coalesce`, `route`, `sync_fsm`,
   `amo`, splitter). You cannot calibrate the timing of a component that is not in the runtime path.
3. **`route.hpp` is not gated behind anything** — even the structural path uses the hashed approximate
   interco (`tile.py:99`). The 5 per-port-class xbars, MSB rotation, and the +1 wrapper spill are absent.
4. **Refill latency does not emerge** (corroborates the prior finding): the structural core discards the
   sync responder's stamped `inc_latency` (cold miss ≈ pipeline cycles) and over-serializes on the async
   responder. Must be fixed under BOTH responder modes (no up-front knob).
5. **Flush/sync is a 0-cycle stub everywhere.** `controller.flush_all()` returns OK instantly; the cluster
   never binds `insitu_cache.i_FLUSH`; `sync_fsm.hpp` is `#include`d by nothing; `block_upstream`/`l1d_busy`
   is consumed by nothing. Any `cache_sync` kernel is undercounted by the full set-walk + 20-cycle drain.

## B. MISSING mechanisms (not modeled at all)

6. **Write-through merger + its downstream WT FIFO** (`write_through_merger.sv` + `i_cache_req_fifo_wt`,
   depth `WriteThroughFifoDepth`). *The critic's catch — a whole active datapath the audit's coalescer
   units missed.* `issue_write_through()` emits one store at a time; the `wt_fifo_depth` config (default 4)
   is **read but never used** (dead config). Governs write-through store bandwidth / store-miss throughput
   to DRAM — a dominant axis the RTL calib TB exercises. Close before any write-heavy calibration.
7. **Group/cluster composite** — no `cachepool_group.py`/`cachepool_cluster.py`; model is one flat tile.
   No inter-tile remote xbar, no source-tile-mod-N routing, no cluster L2 RR response arbiter.
8. **Peripheral / CSR block** — no `dynamic_offset`/`l1d_private`/`private_start_addr`/SPM-size CSRs, no
   tile-granular flush controller, no `l1d_busy` TCDM gating (a material flush-time stall).
9. **DRAMSys DDR4 on 4 channels** — refill hits the flat `InsituCalibMem`; no scramble, no NAPOT channel
   split, no per-channel DDR4 banks/rows/refresh. `dramsys.{cpp,py}` exists but is not bound to `o_L2`.

## C. Approximations that would SILENTLY BIAS calibration (fix or scope explicitly)

10. **`dynamic_offset` default mismatch:** runtime interco default = **2** (`interco.cpp:85`); RTL live
    reset = **14** (`cachepool_peripheral.sv:87`; CSR resval=0). This changes which bank/controller each
    access hits → bank-conflict/coalescing cycle counts. Reconcile before interco calibration.
11. **Write backpressure is OFF by default:** `write_commit_cycles` default = 1 disables the gate
    (`controller.cpp:418`); only the calib config sets 2. The default cluster config models **no** write
    serialization. RTL has two write-side structures (`req_fifo_wt` accept + `winfo_fifo` depth-4 drain)
    collapsed here into one scalar rate.
12. **SPM is a power-of-2 fold**, not the RTL non-power-of-2 integer div/mod (`spm_remap.hpp` unwired);
    mis-distributes lines whenever `cache_partition_set_for_cache` is not a power of two.
13. **Bank access-ctrl FSM** (ACCESS_THROUGH/STALL + `wb_active`) and the **7-state core FSM** are
    collapsed into retry-next-tick; **MRP** linked-list and **PartSplit>1** paths are stubbed (OK only if
    the calib DUT has `ENABLE_MULTI_READ_PEND` undefined and `DataPartSplit=1` — confirm).

## D. Correctly out of scope (recorded for honesty)

- Alternative coalescer styles: `seq_coalescer_*`, `par_coalescer_extend_window`, `non_coalescer`
  (canonical CachePool config selects `par_coalescer_top` equal-window).
- Channel/AXI adapters: `decouple_channels_adapter`, `decouple_queue_sync`, `cache_to_axi`,
  `reqrsp_to_axi`.
- `tcdm_id_remapper` / `id_buffer` (RobDepth/NumEntry=64 outstanding-ID tracking) — not instantiated in the
  active config, **but** this is the structural home of the §13 `max_outstanding` miss-throughput gap; if
  miss-throughput calibration diverges, this finite-ID backpressure is the suspect.
- `amo_conflict_o` (DMA-vs-AMO conflict detector) — partial; only matters with concurrent DMA + atomics.

---

## Recommended pre-calibration work order

1. **Decide the calibration target first:** (a) calibrate the *approximate controller* against the RTL
   numbers (fastest path to closed-loop region_cyc — it is the only thing wired to the cluster), or
   (b) calibrate the *structural model*, which first requires the sync-slave mode + wiring
   `use_structural_core`/`route.hpp`/coalescer into the cluster. These are different projects.
2. If (b): close blockers 1–4 (sync-slave + wire the structural path end-to-end + refill-latency
   emergence) — without them there is no structural runtime to calibrate.
3. Fix the silent-bias traps 10–11 regardless of target (they corrupt *any* calibration).
4. Add the WT merger (6) before write-heavy kernels; add flush/peripheral (5,8) before any `cache_sync`
   kernel; add group/cluster + DDR4 (7,9) before multi-tile / DRAM-bandwidth calibration.

Sources: workflow `wf_f26afc64-b6c` (38 agents, adversarially verified). Prior context:
`insitu_cache_structural_plan_2026-06-16.md`, `insitu_cache_structure_map_2026-06-16b.md`,
`insitu_cache_refill_latency_finding` (memory).
