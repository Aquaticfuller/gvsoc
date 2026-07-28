# InSitu Cache — Structure Map (2026-06-18) — all component datapaths transcribed; open-loop structural calibration started (b.0)

Supersedes `insitu_cache_structure_map_2026-06-16b.md`. Legend:
**✓** approximate model, implemented + calibrated (runs in the default runtime today) ·
**◐** structural, runnable + data-correct, gated OFF, calibration in progress ·
**▣** structural datapath transcribed + standalone-validated, **NOT wired into any runtime** ·
**≈** approximated / partial · **✗** not yet modeled · **N/A** out of scope.

> **Changes since 2026-06-16b:**
> 1. **Pre-calibration gap audit** (adversarially verified, 38 agents — `insitu_cache_precalibration_gap_audit_2026-06-16.md`): the definitive wiring truth — **transcribed ≠ wired**. Of the 7 structural-rewrite header components, only `decode.hpp` + `bank_array.hpp` are `#include`d by any compiled `.cpp` (the structural core); the other five (`fwd_buffer`, `coalesce`, `route`, `spm_remap`, `sync_fsm`, `amo`, `l2_addr`) are wired into nothing. Even `use_structural_core=True` still uses the **approximate** hash interco + old coalescer.
> 2. **Spatz-compatibility finding** (adversarially verified): the v1 **scalar** LSU already handles async `resp()`; the closed-loop blocker is only the Spatz **VLSU** (`trace.fatal` on non-OK). Open-loop async works as-is → closed-loop later needs only a sync-slave mode (sufficient).
> 3. **b.0 calibration (core `0c297356`, pulp `5d78298`):** the structural core's **refill latency now EMERGES** (captures the responder's stamped latency, defers install, serializes misses) and a **deadlock was fixed** by decoupling refill install from the request pipeline. Cold miss now scales with MemLatency (56@ML50 / 106@ML100); 13/13 respond, `data_err=0`. Direction: calibrate the structural model **open-loop only** for now (closed-loop/Spatz deferred).
>
> **Shared-L1 reminder:** L1 is shared, not private — any core reaches any bank by address (intra-tile via 5 per-port-class xbars, cross-tile via remote xbars). The faithful `route.hpp` models this, but it is **not wired** — the runtime still uses the hashed approximate interco.

---

## Unified hierarchy (badge = GVSoC model status)

```
CLUSTER                                                  model: single flat tile (approx) — structural composite NOT built
│
├─ Inter-tile / remote-access xbar ("R" nodes)           [▣ route.hpp] remote-slot routing transcribed; NOT wired; no composite
├─ Peripheral — cache_sync/L1D-flush CSRs + partition    [✗ MISSING] no CSR block, no flush controller, no l1d_busy gating
├─ Refill AXI Mux 512b 16→1 → L2/DDR4                     [✗ Step7]   model: flat l2_router fan-in [✓]
├─ AMO / LR-SC tile shim (scalar lane j=4)               [▣ amo.hpp] FSM+ALU+reservation transcribed; NOT wired; runtime has no AMO metadata
├─ Cluster L2 RR response arbiter (NumTiles×NumMst)      [✗ MISSING]
├─ Cluster Barrier                                       [N/A]
│
└─ GROUP (×N)                                            [✗ MISSING — model has no group/cluster composite]
   ├─ LG/RG remote xbar 4→4 (source-tile-mod-N slot)     [▣ route.hpp] transcribed; composite ✗
   ├─ Bank Refill Xbar 512b 16×8 + NAPOT channel decode  [▣ l2_addr.hpp] scramble/NAPOT transcribed; NOT wired
   ├─ AXI Mux · L2 I$ (RO) 8 KiB                          [N/A]
   │
   └─ TILE (×4 per group)                                model = ONE flat tile (1-tile only)
      ├─ CC0..CC3 — 4 Spatz cores × 5 TCDM ports          [≈ exist; model builds nb_core/tile]
      ├─ L1 I$ (RO) · AXI Interco · Tile Barrier          [N/A]
      │
      ├─ ★ Tile L1 Xbar — 5 per-port-class xbars (SHARED) [≈ runtime: 1 hashed InsituCacheInterco]
      │     • any core→any bank by address                 ── faithful route.hpp [▣ NOT wired]
      │     • remote ports (cross-tile)                     ── [▣ NOT wired] · composite ✗
      │     • programmable map / MSB rotation / partition   ── [▣ NOT wired]
      │     • runtime: hashed N→M approximation             [≈ wired, default]
      │     • dynamic_offset: model default 2 vs RTL 14     ⚠ calibration trap
      │
      ├─ scalar bypass_xbar (2:1)                          [▣ BypassXbar in route.hpp] NOT wired; runtime: scalar latency knob [≈]
      │
      └─ L1 D$ = per-core SHARED BANKS (cachepool_cache_ctrl, one wide 512b cache):
         ├─ par_coalescer (CSHR · 512b wide-merge · split)  [▣ coalesce.hpp] datapath transcribed; NOT wired
         │      runtime: old approximate InsituCacheCoalescer / inc1 ParCoalescer [≈]
         ├─ write-through merger + downstream WT FIFO        [✗ MISSING] issue_write_through emits 1 store/cyc;
         │      wt_fifo_depth (def 4) is DEAD config — governs write-through store BW (critic's catch)
         ├─ SPM partition (integer div/mod remap + restore)  [▣ spm_remap.hpp] NOT wired; runtime: power-of-2 capacity fold [≈]
         ├─ flush/sync FSM (7-state, 4 ops, 20-cyc drain)    [▣ sync_fsm.hpp] NOT wired; runtime flush = 0-cycle stub; cluster never drives i_FLUSH
         └─ single-wide 512b cache core (insitu_cache_core)  [◐ runnable, data_err=0, calibration in progress]
            ├─ 2-stage pipeline + per-cycle ClockEvent FSM    [◐]  7-state enum collapsed to stall-retry (now: stall stays latched)
            ├─ tag array + decoder/encoder (hit/miss/LRU)     [▣→wired] decode.hpp IS in the core path (real XOR-fold hash)
            ├─ in-situ MSHR (pending reader list)             [◐]  reader-list; subarray/MRP accounting partial
            ├─ refill / eviction + single-outstanding         [◐ b.0] ★ refill latency now EMERGES (scales w/ ML, misses serialize)
            │      refill install DECOUPLED into maybe_install_refill() (priority bank op, own path) — RTL-faithful, deadlock-free
            ├─ pseudo-dual banks + WR-conflict penalty        [≈] bank_array.hpp wired for WR-conflict; access-ctrl FSM not modeled
            ├─ forwarding buffer (read-suppress/RAW/WB)        [▣ fwd_buffer.hpp] NOT wired into the core data path
            └─ write mode / winfo FIFO                         [≈] scalar rate, OFF by default (write_commit_cycles=1)
```

## Component-datapath transcription status (the microarchitecture inventory)

| Step | Component (file) | Transcribed | In runtime? | Validation |
|---|---|---|---|---|
| 1 | decoder/encoder (`insitu_cache_decode.hpp`) | ✅ | ✅ structural core | hash-way + classify + LRU, g++ |
| 2 | pseudo-dual-port bank (`bank_array.hpp`) | ✅ | ◐ partial (WR-conflict only) | classify + scoreboard, g++ |
| 3 | forwarding buffer (`fwd_buffer.hpp`) | ✅ | ❌ not wired | read-suppress/absorb/WB/RAW, g++ |
| 4 | **cache core** (`insitu_cache_core.{cpp,py}`) | ✅ | ◐ **runs, b.0 calibration started** | 13/13 respond, data_err=0, cold-miss scales w/ ML |
| 5 | par_coalescer (`coalesce.hpp`) | ✅ | ❌ not wired | wide-merge + split, g++ |
| 6 | route + SPM + sync (`route/spm_remap/sync_fsm.hpp`) | ✅ | ❌ not wired | 51-check g++ |
| 7 | AMO + L2 (`amo/l2_addr.hpp`) | ✅ | ❌ not wired | 38-check g++ |

**Missing mechanisms (not transcribed at all):** write-through merger + WT FIFO; group/cluster composite; peripheral/CSR/flush-controller/l1d_busy; DRAMSys DDR4 + NAPOT channel split. **Out of scope (correct):** seq-coalescer family, par_coalescer_extend_window, non_coalescer, channel/AXI adapters, tcdm_id_remapper/id_buffer.

## Calibration status (open-loop; closed-loop/Spatz deferred)

- **b.0 DONE** — refill latency emerges + deadlock fix + harness async-measurement fix. Cold miss scales with MemLatency; misses serialize (~+53/miss, RTL ~+55); default controller path byte-unchanged.
- **b.1 NEXT** — tune per-tick step counts vs the RTL reference: cold-miss isolated **ML+6 → target ML+17**; then warm-hit 10/7, sustained throughput 0.86, gap sweep. Needs the phase traces (only `sample.trace` ships; `gen_traces.py` produces the rest).
- **b.2** — wire + calibrate the structural coalescer (multi-port coalesce numbers).
- **Deferred** — route/xbar, SPM, flush/sync, AMO, L2 scramble/NAPOT, group/cluster, peripheral, and the cluster sync-slave mode (needed only for closed-loop, and sufficient when added).

Anchors: gap audit `insitu_cache_precalibration_gap_audit_2026-06-16.md`; master plan `insitu_cache_structural_plan_2026-06-16.md`; RTL ref `ManyRVData_rebase/reports/cache_calib/` (warm hit 10/7, cold miss ML+17, 1-port hit thr 0.86, miss thr serialized).
