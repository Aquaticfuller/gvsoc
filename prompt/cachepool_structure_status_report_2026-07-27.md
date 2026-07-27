# CachePool GVSoC model — structure status report (16-core target)

**Date:** 2026-07-27 · **Scope:** `--target=cachepool` (16-core = 4 tiles × 4 cores, one group), post P1+E4+R1+R3+R4+R5+S1 build (parent `fa77723`).
**Status legend:** **a** = Done, same logic as RTL · **b** = In place, with an approximate model · **c** = Not implemented yet.
"Hardware-ready?" = for parts that exist in the current RTL: is the model a faithful, simulation-grade stand-in?

---

## 1. Tile level

### 1.1 L1 icache — **b** (wrong geometry)
- **Model:** ONE shared 8 KiB / 2-way / 32 B icache with 1-line L0s and a single refill port serving all 16 cores (`Hierarchical_cache`, `snitch_cluster.py`). Functional, data-correct.
- **RTL:** per-core icaches (`snitch_icache` per core, `cachepool_tile.sv:1469`, L0_LINE_COUNT=8).
- **Hardware-ready?** Functional but structurally far off — tight-loop fetch stalls mispriced (J2; config-only fix queued: per-tile icache + 8-line L0).

### 1.2 AXI interconnect — **b**
- **Model:** `narrow_axi` (8 B/cyc) + `wide_axi` (64 B/cyc) flat `Router`s; fixed-latency, no per-channel AXI arbitration/occupancy. Loader now rides wide_axi (R1).
- **Hardware-ready?** Approximate — topology/routing correct, timing idealized.

### 1.3 Tile barrier — **b**
- **Model:** counting barrier at PERIPH+0x10 that genuinely blocks (the fdotp root-cause fix), flat +11 release to everyone.
- **RTL:** two-level tile+cluster barrier (`cachepool_tile_barrier.sv`, ~2–4 cy tile-local release).
- **Hardware-ready?** Functionally right (blocks), structurally flat — per-barrier ±5 cy (J7).

### 1.4 snitch-spatz core-complex — **b** (well modelled; one known gap)
- **Model:** SnitchFast ISS + Ara (VLSU/VFPU/VSLIDE blocks) with scoreboard + element-granular chaining; **VLSU issue geometry now = RTL** (S1: 16 B/cyc lanes, 32 outstanding loads); A1 delayed-commit makes vector traffic consume cache latency; per-core `[ARA-STATS]` counters.
- **RTL:** Snitch LSU with **16 outstanding, stall-on-use**; model has 1-outstanding full-core stall on PENDING/DENIED and unlimited sync MLP (**J1 — the top remaining item**; explains fft-validate, load-store, linked-list residuals).
- **Hardware-ready?** Vector side yes; scalar-LSU geometry is the approximation (J1).

### 1.5 intra-Tile L1 dcache Xbar — **b** (routing exact; arbitration missing)
- **Model:** per-port-class xbars (`insitu_cache_xbar`): three-mode routing with modulo folding, MSB rotation (E1, validated), remote slot pinning — transcribed line-by-line from `tcdm_cache_interco.sv`; request-side +1 spill latency calibrated.
- **Missing:** per-output RR arbitration (B2) — same-bank same-cycle conflicts currently cost 0.
- **Hardware-ready?** Routing logic = RTL; timing approximate until B2.

### 1.6 Tile cache partition — **c**
- `l1d_part` / `l1d_xbar_config` / `private_start_addr` CSRs are scratch no-ops (flush-before-repartition unimplemented). `route.hpp` already has the mode table (all-private/all-shared/mixed + non-power-of-2 folds). **RTL uses it** (load-store runs phases half-half) — explains load-store's +53% (E3, queued).

### 1.7 Insitu cache — **b** (well modelled; datapath validated vs the RTL calib TB)
- **Done, same logic as RTL:** address decode + XOR hash-way (verified bit-for-bit), LRU credit scheme, PEND-line semantics with ready-cycle clamp (D1), write-miss early ack via winfo window (D2), per-cell 1-access/cycle serialization (B1), part-granular (16 B) coalescer with last-writer-wins full-part write merge (C1), AMO/LR-SC shim with chained RMW lane occupancy (B3 — spin-lock +1.5% vs RTL), MSB rotation (E1 — capacity A/B exact), refill single-outstanding occupancy gate (calib step 2), flush-all with real dirty writebacks (F1).
- **Calibrated vs RTL standalone TB:** warm hit 10 / stream 7, cold miss ML+17, write 8, cold-miss throughput 1/(ML+17), coal merges.
- **Remaining approximations:** CSHR watchdog/cross-cycle window (C2), resp/retr FIFO bounds (B4), MSHR subarray cap (D3), Knuth hash vs RTL polynomial for victim/set select (only visible on set-aliasing workloads).
- **Hardware-ready?** Yes for the deployed sync-slave datapath (validated); the per-cycle async path is bring-up only (not deployed).

### 1.8 Cache refill interconnect and ports — **b**
- **Model:** per-cell refill + evict ports; single-outstanding refill-occupancy gate (RTL `refill_read_outstanding` analog); fan-in via tile l2 `Router` → cluster wide_axi → backing stores. Optional 4-channel DRAMSys L2 behind a 1 KiB interleaver (R5; the RTL's own tb uses DRAMSys).
- **Hardware-ready?** Behaviorally right (occupancy); physical fabric is a flat fan-in in the default path.

## 2. Group level

### 2.1 Intra-group (local-group) L1 dcache Xbar — **b**
- The same per-port-class xbars, extended with remote-in slots (modulo folding, remote slot = target%2 / source%2 — validated). Arbitration (B2) pending as in 1.5.

### 2.2 L1 dcache NoC router — **b**
- **Model:** remote xbars (`insitu_cache_remote_xbar`) — the `cachepool_group` AXI-xbar analog; cross-tile routing with request hop = 1 (calibrated from CUT_ALL_PORTS).
- **Missing:** response-side PipeReg (RspReg=1 — J4, ~2–5% on remote-heavy kernels) and per-output arbitration.
- **Hardware-ready?** Structure in place; timing slightly optimistic.

### 2.3 Router remote-group to tile interconnect — **b**
- `remote_out[j][r] → rxbar[j] → tile[T].remote_in[j][r]` wiring with exact slot pinning (slot = tile×nr + r). Same latency/arbitration caveats as 2.2.

### 2.4 L2 icache — **b** (no dedicated module in RTL either)
- RTL has no L2 icache (fetch = per-core icache → AXI → DRAM). The model's single shared icache (1.1) plays a stand-in role — wrong geometry (J2).

### 2.5 AXI-to-TCDM — **b**
- Cores' AXI requests route to per-core private SPM memories via routers; no explicit reqrsp↔TCDM protocol bridge. SPM is flat 2 KiB/core (the RTL's private/aliased split is J3).

### 2.6 L1 dcache Bank refill mux — **b**
- Per-cell single-outstanding refill gate reproduces the RTL's refill port occupancy (`cachepool_cache_ctrl.sv:684`); physical mux = flat fan-in to the tile l2 router.

### 2.7 L2 NoC (L1 dcache refill) router — **b**
- **Model:** flat AXI router tree down to plain memories (default) or the 4-channel DRAMSys L2 (R5, matching RTL `NumL2Channel=4`, 1 KiB interleave). No mesh, no per-channel arbitration in the plain path; plain store now priced ML=50 (calibrated).

## 3. Cluster level

### 3.1 Cluster barrier — **b**
- Counting barrier that actually blocks (3.1 == the 1.3 mechanism at cluster scope); flat vs RTL two-level (J7).

### 3.2 Peripheral — **b** (well modelled for the used registers)
- Boot control, EOC, HW barrier, CLINT/MSIP wake, fake UART — all working (8/8 CI kernels boot/print/exit).
- CachePool L1D block (0x28..0x4c): **flush is now real (F1)** — COMMIT fans out to all 16 cells (dirty writebacks + invalidate + gating), FLUSH_STATUS spins on the slowest.
- Scratch/approximate: perf counters, CL_CLINT dead (J6, latent), register timing +1 vs ~11 (J5).

### 3.3 L1 dcache NoC router connection — **b**
- The group's internal NoC hookup (tiles ↔ remote xbars) is in place (2.2/2.3); SoC-side fan-out via wide_axi.

### 3.4 L2 NoC router connection — **b**
- wide_axi fan-out to the backing stores (plain ML=50) or the 4-channel DRAMSys L2 (R5).

## 4. Multi-group NoC (exists in the RTL `dev/multi-group`) — **c** (out of this model's scope)
- This 16-core target is a **single group** — there is no group↔group NoC in it. The multi-group topology is covered separately by the **`cachepool_v2` target** (256-core, FlooNoc-NI-based; own repo history). Within our single group, the tile↔tile NoC (2.2/2.3) is structurally faithful with the noted timing approximations.

## 5. Added parts (important, not in the list)

| Part | Status | Note |
|---|---|---|
| Boot / bootrom / loader | b+ | Patched bootrom (core/tile counts), MSIP wake, wide-AXI loader (R1); load time still a documented artifact (no backdoor loader) |
| SPM/TCDM | b | per-core private 2 KiB; RTL's private/aliased split = J3 |
| DMA (SnitchDma) | c (should gate) | instantiated but the RTL CI disables it (J9 — remove for this target) |
| Memory backing / DRAM | b | plain store ML=50 (calibrated, fdotp/gemv/byte-enable within ~6%) + DRAMSys DDR4×4 option |
| Clock/reset domains | b | single 10 MHz domain everywhere (constant-rate comparison only) |
| AMO/LR-SC shim | a− | B3 chained RMW occupancy; SC/LR reservation; the true-AMO-clears-reservation one-liner pending (Theme I in the review) |
| Coalescer (cell) | a−/b | C1 part-granular merge + full-part write merge validated; C2 window/watchdog pending |

## 6. Summary counts

- **a (same logic as RTL):** cell decode/hash/rotation/refill-occupancy/AMO (within 1.7), flush semantics (F1), xbar routing logic (within 1.5/2.1).
- **b (approximate):** everything else listed above — mostly timing/geometry approximations, each with a tracked item (J1–J9, B2, B4, C2, D3, E2/E3).
- **c (not implemented):** tile cache partition (1.6/E3), multi-group NoC (out of scope, §4), DMA gating (J9).

**Calibration cross-check (16-core, vs RTL QuestaSim):** gemv +1.0%, byte-enable −5.4%, fdotp_M32768 +15.0%, fmatmul −9.0%, spin-lock +12.3%, fdotp_M8192 −13.5%, fft compute −3.0%; outliers load-store (+53%, →1.6/E3) and linked-list (→J1).
