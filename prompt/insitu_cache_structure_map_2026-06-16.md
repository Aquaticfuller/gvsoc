# InSitu Cache — Structure Map (2026-06-16) — structural rewrite Steps 1–6 landed

Supersedes `insitu_cache_structure_map_2026-06-15c.md`. The model has **pivoted** from a
cycle-approximate latency overlay to a **structural rewrite** that transcribes the real RTL
FSM/datapath of every component (master plan: `insitu_cache_structural_plan_2026-06-16.md`). Latency is
to **emerge** from cycles-in-states, not from knobs; calibration is a final pass.

Legend: **✓ approximate model, implemented + calibrated (runs today)** · **◐ structural, runnable +
data-correct, gated OFF, UNcalibrated** · **▣ structural datapath transcribed + standalone-validated,
not yet wired into the runtime tick** · **≈ approximated / partial** · **✗ not yet modeled** (→ Step) ·
**N/A** out of scope.

> **Change since 2026-06-15c:** five RTL-faithful structural datapaths transcribed + standalone-validated
> (header-only, gated default-off, zero build impact). The bottom-up build order (decode → bank → fwd →
> core → coalesce → xbar/SPM/sync) now has **Steps 1–6 complete**; only **Step 7** (system composite +
> DDR4 refill + cluster synchronous-slave inline mode) and the **calibration pass** remain. The
> approximate path (`✓`) is untouched and stays the default: vfadd 15/15 cyc=58001, fmatmul mean-Δ 3.9.
>
> **Shared-L1 reminder:** L1 is shared, not private — the Tile L1 Xbar routes any core to any bank by
> address, extended cross-tile by the remote xbars. The structural `insitu_cache_route.hpp` now models
> this routing for real (all-private / all-shared / mixed partition modes + MSB rotation).

---

## Unified hierarchy (badge = GVSoC model status)

```
CLUSTER                                                          model: single flat tile (approx) — structural composite = Step 7
│
├─ Inter-tile / remote-access xbar ("R" nodes)                   [▣ Step6] route_request remote-slot tile%NumRemotePort
│                                                                   + response remote-return; composite wiring = Step 7
├─ Peripheral — cache_sync / L1D-flush CSRs + partition regs      [▣ Step6 sync_fsm + route CSRs] · controller wiring = Step 7
├─ Refill AXI Mux 512b 16-to-1 → L2/DDR4                          [✗ Step7]  model: simple L2 fan-in router [✓]
├─ AMO / LR-SC tile shim (scalar lane, reservation table)        [✗ Step7]
├─ Cluster Barrier                                               [N/A]
│
└─ GROUP (×N)                                                    [✗ Step7 — model has none]
   ├─ LG/RG remote xbar 4-to-4 (source-tile-mod-N slot)          [▣ Step6 route] · composite = Step7
   ├─ Bank Refill Xbar 512b 16×8 (→L2) + NAPOT channel decode    [✗ Step7]
   ├─ AXI Mux · L2 I$ (RO) 8 KiB                                 [N/A]
   │
   └─ TILE (×4 per group)                                        model = ONE flat tile (1-tile); structural composite = Step7
      ├─ CC0..CC3 — 4 Spatz cores (Snitch + Spatz vector)        [≈ exist; model builds nb_core/tile]
      │     each drives 5 TCDM ports (1 scalar + 4 VLSU lanes)
      ├─ L1 I$ (RO) · AXI Interco · Tile Barrier                 [N/A]
      │
      ├─ ★ Tile L1 Xbar 32b — 5 per-port-class xbars — SHARED L1  [▣ Step6 insitu_cache_route.hpp]
      │     • ANY core → ANY bank BY ADDRESS (shared, not private)  ── route_request: addr_bank/addr_tile decode [▣]
      │     • +remote ports (→LG/→RG) for cross-tile sharing        ── remote-slot routing [▣] · composite [✗ Step7]
      │     • programmable address mapping (private/shared/mixed)    ── 3 modes + modulo fold [▣]
      │     • MSB address rotation (hide routing bits from tag)      ── rotate_addr/unrotate_addr [▣]
      │     • runtime bank partition (private ↔ shared)              ── num_private_cache modes [▣]
      │     • 1-cycle req spill + RR arbiter                         [✗ → calibration timing]
      │     (approx model today: hashed N→M interco [✓])
      │
      └─ L1 D$ = per-core SHARED BANKS (cachepool_cache_ctrl, one wide 512b cache):
         ├─ par_coalescer (hitmap · 512b wide-merge · rsp-split)    [▣ Step5 insitu_cache_coalesce.hpp]
         │      same-line/same-type N→1 wide merge + last-writer-wins + read-split, validated;
         │      CSHR FSM/watchdog/per-port FIFOs/window policy = calibration. (approx: ✓ latency-trick)
         ├─ scalar bypass_xbar (2:1, coalescer|scalar → 1 port)     [▣ Step6 BypassXbar]  (approx: ≈ latency knob)
         ├─ SPM partition (integer div/mod set remap + restore)     [▣ Step6 insitu_cache_spm_remap.hpp]
         │      tag=line/cache_sets, set=line%cache_sets+spm_sets; identity when no partition.
         │      (approx model: capacity-shrink fold [≈])
         ├─ flush/sync FSM (7-state, 4 cache_sync ops)              [▣ Step6 insitu_cache_sync_fsm.hpp]
         │      IDLE/READ_BANK/INIT/CHECK_PEND/FLUSH/INVALID/FINISH; 20-cyc drain interlock; set-walk
         │      with per-dirty-way write-through eviction; sync_block_upstream. (approx: dormant stub)
         └─ single-wide 512b cache core (insitu_cache_core.cpp)     [◐ Step4 — runnable, data_err=0, UNcalibrated]
            ├─ 2-stage pipeline + per-cycle ClockEvent FSM           [◐]  latency emerges (over-predicts → calib)
            ├─ tag array + decoder/encoder (states, hit/miss)        [▣ Step1 insitu_cache_decode.hpp]
            │      real hash-way = lowtag^lowset (replaces Knuth hash); SOP classify; LRU 4-case.
            ├─ in-situ MSHR (pending readers list, num_subarray)     [◐ Step4]  reader-list, single-outstanding refill
            ├─ forwarding buffer (read-suppress/write-absorb/RAW/WB) [▣ Step3 insitu_cache_fwd_buffer.hpp]
            │      single-entry; double-buffered _q/_d + N-entry = calibration. NOT yet in core data path.
            ├─ pseudo-dual banks + WR-conflict penalty               [▣ Step2 insitu_cache_bank_array.hpp]
            │      bank_select=low log2(BankFactor) bits; per-cycle write scoreboard → read retry +1.
            └─ refill/eviction + occupancy (install-pipe)            [◐ Step4]  single-outstanding install + drain
```

**Approx model (✓) calibrated baseline (unchanged):** warm hit 10/7 · cold miss ML+17 · miss/coalesce/
evict thr ≤7% · ceiling ~0.86 · vfadd 15/15 cyc=58001 · fmatmul mean-Δ 3.9.

## Structural rewrite progress (bottom-up; build gate = functional + structural, NOT cycle-match)

| Step | Component (file) | Status |
|---|---|---|
| 1 | Decoder/encoder datapath (`insitu_cache_decode.hpp`) | ▣ **DONE** core `2c201da6` — standalone-validated |
| 2 | Pseudo-dual-port bank (`insitu_cache_bank_array.hpp`) | ▣ **DONE** core `d6d244b8` — standalone-validated |
| 3 | SRAM forwarding buffer (`insitu_cache_fwd_buffer.hpp`) | ▣ **DONE** core `d0abdeed` — standalone-validated |
| 4 | Cache core (`insitu_cache_core.{cpp,py}`) | ◐ **DONE (first runnable)** core `07203629`/`05e856b2` — data_err=0, UNcalibrated |
| 5 | par_coalescer datapath (`insitu_cache_coalesce.hpp`) | ▣ **DONE** core `54815e22` — standalone-validated |
| 6 | xbar route + SPM remap + flush/sync FSM (`insitu_cache_route.hpp`, `_spm_remap.hpp`, `_sync_fsm.hpp`) | ▣ **DONE** core `4c9fcfef` — 51-check self-test passes |
| 7 | System composite (tile/group/cluster + remote xbar + DDR4 refill + AMO/peripheral + **cluster sync-slave inline mode**) | ✗ **next** |
| — | **Calibration pass** (wire validated headers' timing into the tick; diff per-access + region_cyc vs `rtl_ref_1t_2026-06-16`) | ✗ final |

All structural components gated default-off (`use_structural_core`, `use_structural_coalescer`); the
approximate path stays default so closed-loop CI (vfadd) and the open-loop calib numbers stay green.
Full plan + must-fixes: `insitu_cache_structural_plan_2026-06-16.md`.
