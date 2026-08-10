# P1.3 + P2.1 — B1: per-cell request serialization · C1: coalescer merge (shared-L1 contention)

**Date:** 2026-07-27 · **Status:** DONE, verified, committed
**Roadmap:** items P1.3 (gap B1) and P2.1/C1 of `prompt/cachepool_architecture_gap_review_2026-07-26.md` —
landed together per the review's sequencing invariant ("B1 and C1 must land *together*: serialization
without merge swings 4× pessimistic on unit-stride streams"). C2 (CSHR watchdog / cross-cycle window)
remains as P2.x polish.

---

## 1. The gaps

**B1 — no per-cell request serialization.** The deployed sync path resolved every request in-call
touching no shared state: up to 16 VLSU + 4 scalar lookups could complete at one cell in one cycle.
RTL: one 1-deep req_buf + pre-reader arbiter → **≤1 cache access/cycle/cell**. Per-cell hit
bandwidth over-predicted up to 4–5×.

**C1 — the coalescer merge missing.** The per-cell par_coalescer (RTL `cachepool_cache_ctrl.sv:344`)
was dormant (`cell_coalescer=False` in the deployed config), and the dormant component keyed its
window on the 64 B line (RTL keys on the **16 B part**, PartSplit=4), dropped the write merge, and
never propagated the wide access's latency to merged members. The moment B1's token exists, the
missing merge flips the model ~4× *pessimistic* on unit-stride hit streams (4 lanes = 4 serialized
lookups instead of 1 merged beat) and over-occupies the bank 4× vs RTL for other cores' traffic.

## 2. The fixes

**B1 (core):** a per-cell accept token in `run_request_sync`: `accept = max(now, cell_busy_until_);
inc_latency(accept − now); cell_busy_until_ = accept + 1`. Every lookup (read/write, hit/miss,
either input port — the RTL 2:1 bypass xbar serializes them into the one pipeline) consumes one
cell cycle; D1 clamp waits do NOT hold the cell (a PEND-stalled request waits in the xbar input
spill, re-arbitrating after the wait).

**C1 (cell coalescer, reworked + enabled):**
- **Part-granular key** — coalesce on the 16 B part (`part_bytes = line/4`; production folds
  PartSplit=4 → CoalescerDataWidth = 512/4 = 128b), not the 64 B line. `line/4` default in the tile;
  `part_bytes=line` = legacy.
- **Write merge** — same-cycle same-part writes batch (PENDING) and merge last-writer-wins into ONE
  wide part-write **when the merged byte mask covers the whole part** (the unit-stride store-stream
  case: 4 lanes × 4 B = one 16 B beat = one bank access). Partial-coverage groups forward each member
  individually (the core has no byte-enables — a partial wide write would clobber the holes).
- **Latency inheritance with batch-slip correction** — members inherit the wide access's latency
  (one merged bank access serves all) **minus the park→split real-cycle slip**: the calibrated core
  knobs reproduce the RTL ctrl's 10/67 *end-to-end, coalescer included*, so the batch window's cycle
  must not be charged a second time.
- **Word-granularity guard** — accesses wider than a word / part-spanning bypass the window entirely
  (RTL lanes are 32b).
- **Enabled in the deployed config** — `snitch_cluster.py` flips `cell_coalescer` to True (A/B:
  `CACHEPOOL_CELL_COALESCER=0`); the tile passes `part_bytes=line/4`.

### Bugs found by the gate traces (fixed before commit)

1. **Response-loopback loss (individual forwards).** Forwarding a parked member downstream with
   `output_.req()` pushed the coalescer's own response context onto the req — the upstream resp()
   then looped back into the coalescer's `resp_handler` and was dropped as unknown (writes vanished:
   `t_resp=-1`, watchdog abort). Fix: `req_forward()` (preserves the parked req's upstream context;
   a sync OK resp()s upstream, an async completion auto-routes). The wide group reqs keep `req()`
   intentionally (their resp returns to the coalescer for the split).
2. **D1 clamp state leak.** The clamp installed PEND lines at its *virtual* (clamped) cycle, flipping
   them VALID at the *real* current cycle — follower #1's clamp let followers #2/#3 take 12-cycle
   early hits (observed `67,77,12,13` instead of `67,77,77,77`). Fix: a clamped follower serves from
   its PEND line WITHOUT installing (line data is already memcpy'd at allocate); install happens only
   in real time (top sweep) or when a genuine miss needs the way.
3. **Pool-exhaustion double-serve** (latent from A2): the deferral re-batched the whole cycle
   including emitted members. Now marks consumed Pends.
4. **Build-graph trap:** `make build TARGETS="insitu_cache_calib"` alone DROPS the coalescer's
   `gen_*.so` from the build graph (the config-scanning `gapy components` runs the target Python
   without env vars, so `INSITU_CALIB_CELL_COALESCER=1` is invisible to it) and silently leaves the
   stale installed lib. Always build `TARGETS="insitu_cache_calib cachepool"` together — the
   cachepool config (coalescer on) keeps the lib fresh.

## 3. Verification (structural calib, BANKS=1, xbar_lat=0, ML=50)

New `coal_merge` trace (4 same-part cold reads / 4 warm reads / 4 full-part writes / read-back):

| block | B1 only (coal=0) | B1+C1 (coal=1) | meaning |
|---|---|---|---|
| 4 same-part cold reads | 67,77,77,77 (D1 clamps) | **67,67,67,67** | ONE refill serves all four |
| 4 same-part warm reads | 10,11,12,13 (B1 serializes) | **10,10,10,10** | ONE wide hit; merge cancels B1's per-lane charge |
| 4 full-part writes | 8,75,75,75 | **8,8,8,8** | ONE wide write, D2 ack; read-back correct |
| read-back | 10,11,12,13 | 10,10,10,10 | data_err=0 both |

Regression gates (coal=1): warm hit **67/10**, cold miss **67**, cold_stream **0.0143** — the
coalescer is exactly transparent at the calibrated boundary; pend_follower **67,73,9,73,10** (acc2
write-miss 9 vs direct 8 — +1 winfo/batch accounting, within tolerance; the merge block itself is
exact 8,8,8,8). coal=0 (B1 alone) isolated gates all byte-identical to pre-B1 (the token never
bites single-port traffic).

### Kernel sweep (16-core 4×4, cache ON — A1+E1+D1+D2+B1; **C1 NOT active**, see correction)

> **Correction (2026-08-10).** This sweep did **not** include C1. `cell_coalescer` defaults to
> `False` and `snitch_cluster.py` only sets it on the SINGLE-TILE path (env
> `CACHEPOOL_CELL_COALESCER`, default 1); the multi-tile **group** path never sets it. Verified by
> elaboration: a 1-tile/4-core v1 config instantiates the coalescers, a 4-tile/16-core one
> instantiates **zero**. So every 16-core number in this project — this table, the RTL-vs-model
> kernel diff, the RLC ±4% match, the J1 sweep — was produced **without** the coalescer, even though
> the RTL has it (`i_par_coalescer_for_spatz` in `cachepool_cache_ctrl.sv`). The C1 verification
> below (calib TB / `coal_merge`) stands; its *deployment at 16 cores* does not. The deltas in this
> table are the B1 effect alone, as the per-row notes in fact say.

All 9 retval=0, zero FAIL lines (spin-lock `result: 120; gold: 120`, byte-enable `PASSED`):

| Kernel | post-D1/D2 cyc | post-B1/C1 cyc | Δ |
|---|---|---|---|
| spin-lock | 24,079 | 26,636 | **+10.6%** (the B1 effect: contended lock/scalar traffic serializes per-cell) |
| load-store_M16 | 565,493 | 565,879 | +0.1% |
| fdotp-32b_M8192 | 48,880 | 48,902 | +0.0% |
| fdotp-32b_M32768 | 147,389 | 147,409 | +0.0% |
| gemv-opt_M512_N128_K32 | 154,121 | 154,172 | +0.0% |
| fmatmul-32b_M32_N32_K32 | 37,822 | 38,117 | +0.8% |
| fft-32b_M1024_N16 | 109,230 | 109,246 | +0.0% |
| linked-list_M1_N1350_K10 | 2,218,588 | 2,223,254 | +0.2% |
| byte-enable | 204,886 | 204,981 | +0.0% |

The streaming kernels stay flat (their bulk traffic bypasses the L1 via 0xA0000000 — the
recurring theme: cache-internal refinements gate on the calib TB until P2.13), while the
lock kernel finally shows real contention cost — the first kernel-level evidence that the
shared-L1 pipeline is now serialized like the RTL's.

## 4. Files

- `core/models/cache/insitu/insitu_cache_core.cpp` — B1 accept token; D1 clamp serve-without-install.
- `core/models/cache/insitu/insitu_cache_cell_coalescer.{cpp,py}` — C1 rework (part key, write
  merge, slip-corrected inheritance, word guard, req_forward fix, Pend done-marking).
- `core/models/cache/insitu/insitu_cache_tile.py` — `part_bytes=line/4`.
- `pulp/pulp/snitch/snitch_cluster/snitch_cluster.py` — `cell_coalescer` ON (+`CACHEPOOL_CELL_COALESCER`).
- `pulp/insitu_cache_calib/traces/coal_merge.trace` — the B1+C1 gate.

## 5. Follow-ups

- **C2** (P2.x): CSHR watchdog/occupy-map (cross-cycle same-part merges, lone-lane up-to-3-cycle
  hold), explicit +1/+1 req/resp spill terms, splitter backpressure hold.
- **B2** xbar per-output arbitration (the cell token caps the bank side; the xbar side still
  forwards free), **B3** AMO lane occupancy, **B4** resp/retr FIFO bounds.
- The write merge is full-part-only; partial-part store streams (strided scatters) fall back to
  per-member forwards (RTL still merges those — a modest pessimism until byte-enables exist).
