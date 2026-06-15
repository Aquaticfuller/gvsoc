# InSitu Cache — Structure Map (2026-06-15b) — after Phase-1 increment 1

Supersedes `insitu_cache_structure_map_2026-06-15.md`. Status legend: **✓ implemented + calibrated** · **≈ approximated / partial** · **◐ structural, implemented + validated but gated OFF** · **✗ not yet modeled** (→ Phase) · **N/A** out of scope.

> **Change since 2026-06-15:** the **structural `par_coalescer`** (Phase-1 increment 1) has **landed** as a real GVSoC component (`insitu_cache_par_coalescer.{cpp,py}`, core `040fdef3`). It is the structural extraction of the interco's inline `enable_input_coalesce` window: same-cycle/same-line read merge + output-accept arbitration. It is **gated default-OFF** (`use_structural_coalescer`); when on, the interco becomes a pure router (`defer_to_coalescer`) and one par_coalescer sits per controller. **Validated: all 19 calib traces are per-access byte-identical** between the default (interco-merge) and structural (par_coalescer) paths, so the extraction is faithful. The **default/production path is unchanged** (still the interco's inline merge) — hence the par_coalescer node is **◐** (built+validated, not yet the default).
>
> **Shared-L1 reminder (unchanged):** the L1 is shared, not private — the Tile L1 Xbar routes any core to any bank by address, extended cross-tile by the remote xbars.

---

## Unified hierarchy (badge = GVSoC model status; "model:" = what the model does)

```
CLUSTER                                                          model: single flat tile only — no cluster/group scale
│
├─ Inter-tile / remote-access xbar ("R" nodes)                   [✗ P2]   any CC → another tile's banks, by address
├─ Peripheral — cache_sync / L1D-flush CSRs + partition regs      [✗ P4]
├─ Refill AXI Mux 512b 16-to-1                                    [✗ P2]
├─ AMO / LR-SC tile shim (scalar lane, reservation table)        [✗ P5]
├─ Cluster Barrier                                               [N/A]
│
└─ GROUP (×N)                                                    [✗ P2 — model has none]
   ├─ LG Xbar 32b 4-to-4 · RG-to-T · Router                      [✗ P2]
   ├─ Bank Refill Xbar 512b 16×8 (→L2)                           [✗ P2]   model: simple L2 fan-in router [✓]
   ├─ AXI Mux · L2 I$ (RO) 8 KiB                                 [N/A]
   │
   └─ TILE (×4 per group)                                        model = ONE flat tile
      ├─ CC0..CC3 — 4 Spatz cores (Snitch + Spatz vector)        [≈ exist; model builds 2/tile, not a 4-CC tile]
      │     each drives 5 TCDM ports (1 scalar + 4 VLSU lanes)
      ├─ L1 I$ (RO) · AXI Interco · Tile Barrier                 [N/A]
      │
      ├─ ★ Tile L1 Xbar 32b (4+X)→(4+X) — SHARED-L1 FABRIC       [≈]
      │     • ANY core → ANY bank BY ADDRESS (shared, not private) ── model: hashed N→M interco [✓]
      │       (interco gains a route-only `defer_to_coalescer` mode for the structural path)
      │     • +X remote ports (→LG/→RG) for cross-tile sharing     [✗ P2]
      │     • programmable address mapping · runtime bank partition [✗ P2]
      │
      └─ L1 D$ = 4 address-interleaved SHARED BANKS (256 KiB/tile)  model: 4 controllers = the 4 banks [✓ sharing analog]
         │   one cache per core physically, but every bank reachable by every core via the xbar (NOT private)
         └─ per-bank cache = cachepool_cache_ctrl (one wide 512b cache):
            ├─ par_coalescer (hitmap · 512b wide-merge · rsp-split)  [◐ P1]  ◀── NEW: structural component landed,
            │      gated OFF, validated byte-identical to the interco merge. Today still does same-cycle/
            │      same-line READ merge only; wide-merge + response-split = later P1 increments.
            ├─ scalar bypass_xbar (2:1)                              [✗ P1]  model: scalar latency knob   [≈]
            ├─ 4-beat refill burst FSM                               [✗ P1]  model: single-slot install   [≈]
            └─ single-wide 512b cache core                           [✗ P1 structure; internals below:]
               ├─ tag array + decoder/encoder (states, hit/miss)     [✓]
               ├─ LRU / hash-way victim                              [✓]
               ├─ in-situ MSHR (pending track + same-line merge)     [≈ side-deque]
               ├─ forwarding buffer (RAW fast path)                  [≈ 1 tracker]
               ├─ refill/eviction + occupancy (install-pipe)         [✓ defer_refills]
               ├─ pseudo-dual banks + WR-conflict penalty            [✗ P6]  model: set_busy cyclestamp   [≈]
               ├─ SPM partition (division-remap + separate path)     [✗ P4]  model: capacity-shrink fold  [≈]
               └─ flush/sync FSM (7-state, 4 cache_sync ops)         [✗ P4]  model: dormant flush_all() stub
```

**Open-loop calibrated (unchanged):** warm hit 10/7 · cold miss ML+17 · miss/coalesce/evict thr ≤7% · ceiling ~0.86.
**Closed-loop:** vfadd 15/15, cyc=58001 ✓.

## Phase-1 progress

| Increment | Status |
|---|---|
| 1. Structural par_coalescer (skeleton + same-line read merge) | ✅ **DONE** (core `040fdef3`, gated off, validated) |
| 2. Structural response-split + per-port FIFO (rsp_spliter) | ✗ next |
| 3. Structural MISS coalescing (CSHR) | ✗ |
| 4. Scalar bypass 2:1 xbar (structural) | ✗ |
| 5. Single-wide 512b controller + 4-beat refill burst FSM | ✗ |
| 6. Production cutover (flip the factories to structural; retire enable_input_coalesce) | ✗ |

(Earlier sequencing also lists a pseudo-bank-array prep step and P3/P6 caps/conflict work; see `insitu_cache_dev_plan_2026-06-15.md`.)
