# P1.2 — E1: MSB address rotation (fixes the 2^N per-bank capacity collapse)

**Date:** 2026-07-26 · **Status:** DONE, verified, committed
**Commits:** core (rotation wiring + core-side unrotation) · pulp (calib A/B knob + structural dyn_offset)
**Roadmap:** item P1.2 (gap E1) of `prompt/cachepool_architecture_gap_review_2026-07-26.md`

---

## 1. The gap (E1)

`insitu_cache_tile.py` hardcoded `enable_rotation=False`, so the xbar's MSB rotation
(`insitu_cache_xbar.cpp:105-110`) was dead. Banks received the raw address: with
BankSel=`addr[7:6]` (+ TileID=`addr[9:8]` at 4 tiles) those routing bits are *constant for any
given bank* — but they also sit inside the set-index field `addr[13:6]`, so a bank could only
use sets whose frozen bits matched:

- single tile (N=2): 64 of 256 sets usable → **16 KiB effective of 64 KiB per bank** (4×);
- 4-tile group (N=4): 16 of 256 sets usable → **4 KiB of 64 KiB per bank** (16×).

First-order *miss-rate* corruption: any cached footprint between the collapsed and the true
capacity thrashes on conflict misses the RTL never has. Invisible to the (capacity-insensitive,
single-bank) calib TB — hence not caught by the 10/67 references.

## 2. The fix

The RTL `tcdm_cache_interco` rotates the N routing bits above `dyn_offset` to the address MSB
before a request reaches its local bank (`rotate_addr`, already transcribed + standalone-validated
in `route.hpp`), so bank tags/sets live in *rotated* space and the routing bits cannot alias into
the set index. What was missing:

1. **Turn it on** — `InsituCacheTileConfig.enable_rotation` (default **True**), passed to the
   structural tile's per-port-class xbars. Guard: rotation requires
   `dyn_offset == log2(cache_line_bytes)` (it must not move line-offset bits) — otherwise the
   tile prints a warning and disables it.
2. **Unrotate on every L2-side egress** — banks store tags/sets of rotated addresses, so every
   address that leaves toward the NoC must be restored (`route.hpp::unrotate_addr` with the same
   N). Implemented in `insitu_cache_core.cpp` as a single helper
   `l2_addr()` (identity when `rotate_bits=0`), applied at all six egress points:
   - sync path: refill (`set_addr(l2_addr(addr_line(addr)))`), dirty-victim writeback
     (`old_line` reconstructed from rotated tag/set), `functional_write_mem`, and the
     refill-failure bypass (save/unrotate/restore around `refill_itf_.req(req)`);
   - async path: refill issue (FIFO + `pending_refill_addr_` deliberately stay **rotated** —
     `install_refill()` re-decodes set/way from them), evict-FIFO issue.
   Each bank receives its N via new `rotate_bits` / `rotate_dyn_offset` / `rotate_addr_width`
   properties, computed by the tile per `route.hpp::bits_to_rotate` (all-shared →
   bank_bits+tile_bits; all-private → bank_bits; mixed per-bank).
3. **Rotation happens exactly once.** Cross-tile requests rotate only at the *destination*
   tile's port-class xbar when they route local (the remote xbar routes global addresses
   unmodified — verified in source). So a single fixed N per bank is correct for every ingress
   path, local or remote.

Note: rotation does not change *which* bank/tile a line routes to (routing always uses the
global address) — only which set it lands in inside the bank.

## 3. Verification

### 3.1 Decisive capacity A/B (the E1 gate)

Structural calib tile (4 banks × 4-way × 256-set × 64 B = 64 KiB/bank), new trace
`capacity_2sweep_2048` (two sweeps of 2048 sequential lines = 512 lines/bank — fits the true
1024-line capacity, thrashes the collapsed 256-line one):

| | sweep 1 (cold) | sweep 2 (re-read) | data_err |
|---|---|---|---|
| rotation OFF (pre-E1) | 0/2048 hits | **0/2048 hits** (100% conflict miss) | 0 |
| rotation ON (E1) | 0/2048 hits | **2048/2048 hits** | 0 |

Exactly the predicted behaviour: pre-E1 the footprint can't survive a re-sweep; post-E1 every
line is resident. Rotation+unrotation is data-exact (`data_err=0` both ways).

### 3.2 Regression gates

- Structural calib BANKS=1 (`xbar_lat=0`): **67/10 exact** — N=0 → `l2_addr` identity, byte-
  identical to pre-E1.
- 4-core fdotp_M32768 (N=2, all-private branch): retval=0, 148,212 cyc (vs 148,227 post-A1).
- Full 16-core sweep (N=4, all-shared branch): **9/9 retval=0, zero FAIL lines**
  (spin-lock `result: 120; gold: 120`, byte-enable `PASSED`).

### 3.3 Kernel cycle impact: ≈0 — and why that is *expected* here

| Kernel | post-A1 16c | post-E1 16c | Δ |
|---|---|---|---|
| spin-lock | 24,001 | 24,001 | 0 |
| load-store_M16 | 567,257 | 565,490 | −0.3% |
| fdotp-32b_M8192 | 48,877 | 48,877 | 0 |
| fdotp-32b_M32768 | 147,383 | 147,383 | 0 |
| gemv-opt_M512_N128_K32 | 154,115 | 154,115 | 0 |
| fmatmul-32b_M32_N32_K32 | 37,858 | 37,858 | 0 |
| fft-32b_M1024_N16 | 109,226 | 109,226 | 0 |
| linked-list_M1_N1350_K10 | 2,215,363 | 2,215,363 | 0 |
| byte-enable | 204,873 | 204,873 | 0 |

Rotation IS live in these runs (`gvsoc_config.json`: `rotate_bits=2/4, dyn_offset=6` on every
cell) — but the CI kernels' bulk streams sit in the **uncached** `.pdcp_src` region at
0xA0000000 (verified via readelf: 256 KiB there; `.dram` is *empty*), which bypasses the L1
entirely in the current model. The L1D's cached-region footprint is a few hundred bytes of
globals + result arrays — nothing that can thrash. (load-store's −0.3%: its node region *is*
cached, so its set distribution really did re-map — direct evidence rotation is active.)

Consequence: E1's kernel-level payoff arrives with **P2.13** (route 0xA0000000 *through* the
cache as the RTL does) — from that point on, E1 is what keeps per-bank miss rates comparable
to RTL at all. Landing it first keeps the P2.13 A/B clean.

## 4. Files

- `core/models/cache/insitu/insitu_cache_core.{cpp,py}` — `l2_addr()` + 6 egress applications;
  `rotate_bits/_dyn_offset/_addr_width` properties.
- `core/models/cache/insitu/insitu_cache_config.py` — `InsituCacheTileConfig.enable_rotation=True`.
- `core/models/cache/insitu/insitu_cache_tile.py` — rotation on + per-bank N + dyn_offset guard.
- `pulp/insitu_cache_calib/__init__.py` — structural-tile `dynamic_offset=6` (line-granular
  BankSel; the flat DUT's 2 is a flat-interco artifact) + `INSITU_CALIB_ENABLE_ROTATION` A/B knob.
- `pulp/insitu_cache_calib/traces/capacity_2sweep_2048.trace` — the capacity gate.

## 5. Follow-ups

- **P2.13** (0xA0000000 through the cache) is where E1 becomes kernel-visible; re-run this
  doc's sweep then and *expect* fdotp/gemv miss counts to drop vs a no-rotation control.
- Flush-by-address-range (when the cache_sync FSM lands, Step 6) must form its writeback
  addresses through the same `l2_addr()` — the current flush port is an accept-OK stub.
- The mixed private/shared N branch (`n_priv` between 1..n_ctrl-1) is implemented but not
  exercised by any cachepool config (all-shared at 16-core, all-private-equivalent at 1 tile).
