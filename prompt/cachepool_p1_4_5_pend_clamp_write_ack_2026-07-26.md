# P1.4 + P1.5 — D1: PEND-line ready-cycle clamp · D2: write-miss early ack

**Date:** 2026-07-26 · **Status:** DONE, verified, committed
**Roadmap:** items P1.4 (gap D1) and P1.5 (gap D2) of
`prompt/cachepool_architecture_gap_review_2026-07-26.md` — landed together (same machinery)

---

## 1. The gaps

**D1 — followers during a refill took an early hit.** The sync-slave miss path allocated
READ_PEND/WRITE_PEND and completed to VALID *in the same call* (refill data memcpy'd, line
visible immediately); only the misser's own response was stamped at issue+ML+penalty. A second
access to the same line during the refill window decoded a clean VALID hit and returned in
~10 cycles — at ML=50 a ~56-cycle gift per follower (×4 VLSU lanes sharing a line = a large
optimistic bias on every streaming kernel). The decode's `hit_pend`/`hit_conflit`/`all_pend`
branches (transcribed from the RTL) were dead, because lines never stayed PEND.

**D2 — write misses charged the full refill latency to the store.** RTL: a store's response
comes from the winfo FIFO pushed *at request acceptance* (`insitu_cache_tcdm_wrapper.sv:731`,
WRespFifoDepth=4) — a store acks ~8 cycles (hit or miss); the WRITE_PEND merge with the refill
happens inside the cache, invisible to the LSU. The model stamped resp_cycle−now (ML+17 ≈ 67)
on every store miss.

## 2. The fixes (sync-slave path only; the async open-loop path is untouched)

**D1 — lines stay PEND with a ready-cycle.** A miss now installs the refill *data* immediately
(so post-clamp followers read correct bytes) but keeps the line PEND with
`WayMeta.ready_cycle = resp_cycle` (the same resp_cycle the misser's latency and the
refill-occupancy gate are computed from — no second timing source). Three cooperating pieces:

- **Lazy install sweep** (top of `run_request_sync`, before decode): any PEND line in the
  accessed set with `ready_cycle <= now` becomes VALID (LRU complete; WRITE_PEND keeps dirty).
  So a tag-match always means "logically resident" and the victim scan never sees an
  install-overdue line as free.
- **Ready-cycle clamp loop** (after decode): `hit_pend` (same-type follower) and `hit_conflit`
  (opposite-type) wait in-call until the line's ready_cycle, install everything the wait
  reached, and re-decode — the follower then takes a normal hit (+hit latency, modelling the
  RTL's 1/cycle post-install drain). `all_pend` waits for the set's earliest ready line; a
  victim scan that lands on a not-yet-ready PEND way waits that line out the same way. Bounded
  (≤ ways+1 iterations, each installing ≥1 line).
- **Eviction safety**: a PEND line can never be victimized (the clamp installs it first; a
  WRITE_PEND victim is then just a normal dirty line and gets the ordinary writeback).

**D2 — store acks at the winfo latency.** Write hits and write misses now ack with
`structural_write_hit_latency_cycles` (new knob, **8** in `make_cachepool_512_config` = the RTL
warm-write reference; −1 falls back to the read-hit value → old behaviour). The write-miss path
still allocates WRITE_PEND + ready_cycle, applies the store data + functional WT + dirty
immediately, and keeps the refill-occupancy gate (`sync_refill_busy_until_ = resp_cycle +
install_tail`) — so a subsequent load still stalls for the rest of the refill (via D1), and
miss *throughput* is unchanged. Plus the winfo acceptance window: a store's ack drains ~2 cy
after acceptance, depth 4 — a 5th store in the window stalls until the oldest ack drains.

## 3. Verification (structural calib, BANKS=1, xbar_lat=0, ML=50)

New trace `pend_follower` (cold miss + same-line follower mid-window; cold write-miss;
read-after-write on the WRITE_PEND; post-ready read):

| access | pre-fix | post-fix | meaning |
|---|---|---|---|
| acc0 cold read-miss | 67 | **67** | misser latency unchanged |
| acc1 follower mid-window | ~10 | **73** | D1: clamped to ready+drain (no early hit) |
| acc2 cold write-miss | ~67 | **8** | D2: winfo ack |
| acc3 read-after-write | ~10 | **73** | clamp + written data returned (data_err=0) |
| acc4 post-ready read | 10 | **10** | clean hit |

Regression gates all exact: warm hit **67/10**, cold miss **67**, cold_stream throughput
**0.0143** @ML50 (refill-occupancy gate untouched), **data_err=0** everywhere; flat
async-controller path byte-identical (67/10 — shared header only gained a zero-init field).

16-core kernel sweep (4×4, cache ON) — all 9 retval=0, zero FAIL lines (spin-lock
`result: 120; gold: 120`, byte-enable `PASSED`):

| Kernel | post-E1 cyc | post-D1/D2 cyc | Δ |
|---|---|---|---|
| spin-lock | 24,001 | 24,079 | +0.3% |
| load-store_M16 | 565,490 | 565,493 | +0.0% |
| fdotp-32b_M8192 | 48,877 | 48,880 | +0.0% |
| fdotp-32b_M32768 | 147,383 | 147,389 | +0.0% |
| gemv-opt_M512_N128_K32 | 154,115 | 154,121 | +0.0% |
| fmatmul-32b_M32_N32_K32 | 37,858 | 37,822 | −0.1% |
| fft-32b_M1024_N16 | 109,226 | 109,230 | +0.0% |
| linked-list_M1_N1350_K10 | 2,215,363 | 2,218,588 | +0.1% |
| byte-enable | 204,873 | 204,886 | +0.0% |

**Why ~0 kernel movement (third P1 item showing the same pattern):** the CI kernels' cycle
counts are dominated by the *uncached* `.pdcp_src` stream path, which bypasses the L1 entirely
— the cached-region footprint (globals, result arrays, barrier lines) is too small for
cache-internal latency refinements to register. D2's store-ack improvement (67→8/miss) mostly
frees scoreboard entries off the critical path; D1's clamp only touches cached-region followers.
The decisive gates for these fixes are the calib-TB traces above (where they move latencies
6–8×); their kernel-level payoff arrives with **P2.13** (0xA0000000 through the cache), which
puts the streams under the L1 — at which point D1's early-hit suppression and D2's winfo acks
become first-order.

## 4. Files

- `core/models/cache/insitu/insitu_cache_decode.hpp` — `WayMeta.ready_cycle`.
- `core/models/cache/insitu/insitu_cache_core.cpp` — lazy-install sweep, clamp loop, winfo
  window, D2 ack on write hit/miss, PEND-preserving miss install.
- `core/models/cache/insitu/insitu_cache_config.py` — `structural_write_hit_latency_cycles`
  (−1 default; 8 in the 512 config).
- `core/models/cache/insitu/insitu_cache_core.py` — knob forwarding.
- `pulp/insitu_cache_calib/traces/pend_follower.trace` — the D1/D2 gate.

## 5. Follow-ups

- P2.12 (B4) bounds the resp/retr FIFOs against this machinery; P3.3 (D3) caps the MSHR at
  NumSubarray for >9-way pileups (the clamp loop is the hook point).
- The winfo window is evaluated after the clamp (a conflicted store is accepted late) — the
  RTL has the same ordering (the wrapper holds a stalled request out of the FIFO).
