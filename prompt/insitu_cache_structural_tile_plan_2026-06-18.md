# Structural Tile/Group Composition — Build Plan (2026-06-18)

From a 9-agent design workflow (5 RTL+model readers → synthesis → 3 adversarial reviewers). All three
reviewers returned **sound=false** with concrete must-fixes; those are folded in below. Goal: build the
RTL-faithful structural **tile** (then **group**), wiring the transcribed `route`/`coalesce`/`amo` headers
+ the structural core, gated behind `structural_tile` (default off; fallback = the current flat tile).

## 1. Verified RTL tile structure (the blueprint)

- **5 per-port-class crossbars**, NOT one hashed interco: `cachepool_tile.sv:604` `gen_cache_xbar` — one
  `tcdm_cache_interco` per lane `j∈[0,5)`. Each xbar-j: 5 inputs (4 local cores' lane-j + 1 remote-in) ×
  5 outputs (4 local banks + 1 remote-out). Input port `p` → core `p/5`, lane `p%5`.
- **Coalescer is INSIDE the cache cell**, not the tile: `cachepool_cache_ctrl.sv:344` instantiates
  `par_coalescer` on the **4 VLSU lanes** (ports `[NumPorts-2:0]`); the **scalar lane** (`NumPorts-1`) goes
  through an **internal 2:1 `reqrsp_xbar`** (scalar-bypass | coalescer-aggregate → 1 bank port).
- **AMO only on lane j=4** (scalar), one per controller (4/tile): `cachepool_tile.sv:658`. VLSU lanes bypass.
  Order at RTL: `xbar_j → (lane4: spatz_cache_amo) → req spill (Bypass=0, +1cyc) → controller`.
- **4 controllers/tile** (`NumL1CtrlTile=4`), each `cachepool_cache_ctrl` with `NumPorts=5`, 4-way/128-set/
  512b/BankFactor=2, one refill master each.
- **Refill/evict**: per controller, **inverse-MSB-rotated** to the NoC address, `user.bank_id=cb+1`;
  **eviction rides the refill channel** (`write=1`) — there is NO separate evict port. Refills matched on
  return by **address re-decode** (the model's existing mechanism), not a bank_id field.
- **Group** (`cachepool_group.sv`): `NumTiles=4` tiles + **5 remote xbars** (`reqrsp_xbar`, one per
  port-class, `NumInp=NumOut=NumTiles*NumRemotePortCore`). **Source-tile-mod-N slot pinning**
  (`group.sv:285-295`): request → `target_tile*N + (source_tile % N)`; response returns on the same slot.
- **Single-tile** (`num_tiles==1`): remote ports present but inactive (route forces local). Build the tile
  STANDALONE first; add remote wiring with the group.

## 2. ⚠ The architectural tension the reviewers surfaced (decision needed)

The **sync-slave mode** required to drive the structural core from the Spatz **VLSU** (which `trace.fatal`s
on async) **degrades the cache cell's cross-lane fidelity** — and this is a degradation of *our* model, not
just Spatz timing:

- The VLSU issues all lanes in **one event**, each `req()` resolving (returning OK) **before** the next
  lane issues (`spatz_vlsu.cpp:250-335`). So under sync delivery, same-cycle multi-lane accesses arrive
  **sequentially**, and the cache cannot see them as concurrent.
- Consequence: the **par_coalescer cannot batch** (it needs a same-cycle vector), the **bank WR_CONFLICT
  scoreboard** smears across lanes, and **AMO atomicity back-pressure** (`core_ready=0` to stall peers) is
  unmodelable in-call. The reviewers also showed the proposed "virtual-cycle FSM loop" sync mechanism would
  **re-entrant-`resp()` crash** (the VLSU binds no resp handler) and must instead use the controller's
  **analytic** latency compute (`controller.cpp:574-598` — one-shot, no FSM tick, no resp).

**The structural TILE itself (5 xbars + coalescer + AMO + cores) is the SAME build either way.** What
differs is the validation/drive path:

- **Open-loop multi-port trace replay** (async core): can deliver genuinely same-cycle multi-lane accesses
  → exercises and validates the faithful coalescer + bank-conflict + xbar contention at **full fidelity**.
- **Closed-loop Spatz** (sync core): runs real kernels, but the cache cell's cross-lane contention is
  **approximated** (sequential delivery), and the coalescer effectively can't merge.

## 3. Corrected build plan (must-fixes folded in)

Components to build (each gated; fallback = flat tile):
1. **`InsituCacheXbar`** (`insitu_cache_xbar.{cpp,py}`, wraps `route.hpp`) — one per-port-class crossbar,
   5-in × 5-out, real BankSel/TileID routing + MSB `rotate_addr`. Tile instantiates 5.
2. **Structural cache CELL composite** (matches `cachepool_cache_ctrl`): `par_coalescer` (wraps
   `coalesce.hpp`) on the 4 VLSU lanes + an internal 2:1 bypass (`route.hpp BypassXbar`) for the scalar
   lane → one bank port → `InsituCacheCore`. *(must-fix: coalescer is internal to the cell, not the tile.)*
3. **`InsituCacheAmo`** (`insitu_cache_amo_shim.{cpp,py}`, wraps `amo.hpp`) — on lane 4 only, between
   `xbar_4.out(cb)` and the cell's scalar input; `core_ready` back-pressures xbar_4.
4. **`InsituCacheCore` sync mode** (extend) — use the controller's **analytic** latency compute (NOT a
   virtual-cycle tick loop): resolve in-call, `inc_latency`, return OK; never `resp()`/`save()`; neutralize
   ALL clock/event touchpoints (`schedule_tick`, `refill_resp_handler`, tick reschedule); max-iter cap with
   a fallback latency. Async path unchanged (open-loop calib untouched).
5. **`structural_tile` branch** in `insitu_cache_tile.py` — wire 5 xbars + 4 cells + 4 AMO + spill + 4
   refill fan-out (+ tied-off remote ports). Same `i_INPUT/o_L2/i_FLUSH` facade → no `snitch_cluster.py`
   change for single-tile.

Wiring must-fixes: **scalar-lane remap** (GVSoC port 0 = scalar → RTL lane 4: `j=(p%5==0)?4:(p%5)-1`);
**refill matched by addr re-decode** (no bank_id field exists); **eviction → same refill port**;
`dynamic_offset` decision (model 2 vs RTL reset 14); spill = +1-cyc req latency knob (Phase A).

## 4. Build order

0. Config flags (`structural_tile`, `inline_sync_`, `num_tiles`, `num_remote_port_core`, `tile_id`, spill).
1. `InsituCacheXbar` + standalone routing/rotation round-trip test.
2. Structural cache cell composite (coalescer + bypass + core) + multi-port data-correctness test.
3. `InsituCacheAmo` shim + LR/SC + true-AMO unit test.
4. `structural_tile` branch → **validate OPEN-LOOP multi-port** (data correct + contention exercised).
5. Sync-slave mode (analytic) → **closed-loop vfadd** on the structural tile (documented-approximate).
6. **Group**: `cachepool_group.py` (4 tiles + 5 remote xbars + source-mod-N) + multi-tile data correctness.
7. *(Phase B)* `cachepool_cluster.py`: L2 4-channel split (`l2_addr.hpp`), peripheral CSRs (`dynamic_offset`
   reset 14), fold `spm_remap.hpp` + `sync_fsm.hpp` into the core.

## 5. Top risks (from review)

- Re-entrant `resp()` crash if sync mode reuses `drain_outputs` (use analytic compute instead).
- `rotate_addr`/`unrotate_addr` must be a perfect inverse or refills corrupt silently.
- Group **source-mod-N** slot pinning (use source%N, not target%N) — wrong → drops cross-tile responses
  only when S%N≠T%N (passes single-tile, fails some multi-tile).
- `IO_REQ_DENIED` to the NB_OUTSTANDING-off scalar LSU hangs it — sync mode must always resolve to OK.
- Fallback regression: the gated branch must leave the flat path byte-identical.
