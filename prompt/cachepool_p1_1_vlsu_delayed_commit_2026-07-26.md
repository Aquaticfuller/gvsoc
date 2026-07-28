# P1.1 — A1: VLSU delayed-commit (vector traffic consumes cache latency) + the SoC-DRAM bandwidth fix

**Date:** 2026-07-26 · **Status:** DONE, verified, committed
**Commits:** core `bab9e078` (A1 delayed-commit) · pulp `6b7cf09` (bandwidth fix) · pulp `44ad448` (calib xbar knob)
**Roadmap:** item P1.1 (gap A1) of `prompt/cachepool_architecture_gap_review_2026-07-26.md`

---

## 1. The gap (A1)

The Spatz VLSU (`core/models/cpu/iss/src/ara/spatz_vlsu.cpp`, `CONFIG_GVSOC_ISS_USE_SPATZ`
variant of `AraVlsu`) committed every `IO_REQ_OK` burst to the vector-register scoreboard **at
issue time**, ignoring the latency stamped on the request by the interconnect
(`req->get_full_latency()` was read nowhere on the OK path).

Through the InSitu cache — whose sync-slave structural core stamps hit/miss latency **on** the
OK return — this made all vector loads/stores effectively **~0-cycle**:

- chained consumer instructions could read vector elements before the data had logically
  arrived (a correctness hazard in principle, masked in practice by the kernels' barriers);
- none of the carefully calibrated cache hit/miss latency (steps 1–4) showed up in kernel
  cycle counts — the model's vector traffic bypassed the very thing we calibrated;
- kernel cycles were therefore systematically optimistic on every VLSU-heavy kernel.

## 2. The fix

Ported the **Ara variant's delayed-burst pattern** (which the `#else` branch of `ara.hpp`
already had) to the Spatz variant:

- `ara.hpp` — added `delayed_bursts` / `delayed_bursts_timestamps` queues to the
  `CONFIG_GVSOC_ISS_USE_SPATZ` `AraVlsu` class.
- `spatz_vlsu.cpp` — on `IO_REQ_OK`: if `get_full_latency() > 0`, hold the burst in
  `delayed_bursts` with timestamp `now + latency` and count it in
  `slot.nb_pending_bursts`; the args (slot, port, vreg, size) stay on the request. If
  latency is 0, keep the old issue-time commit (args popped immediately, req recycled).
- `fsm_handler` — at the top, drain **ALL** eligible delayed bursts (not one per firing:
  the VLSU issues up to `nb_ports` bursts/cycle, so a 1/cycle drain would artificially
  serialize memory-bound streams) through the existing `data_response` — the exact same
  completion path async PENDING/DENIED bursts use (arg pops, req recycle,
  `nb_pending_bursts--`, `insn_commit(vreg, size)`).

Net effect: a vector load's elements become visible to the scoreboard at
issue + cache/memory latency — vector traffic now *consumes* the calibrated latency.

## 3. What it exposed: the SoC-DRAM bandwidth divergence (the real bug underneath)

First post-fix runs collapsed **~3.5× slower** on streaming kernels (fdotp M8192
24,000→85,995; M32768 93,552→279,209), with per-burst `get_full_latency()` values growing
without bound (39+ and climbing). The delayed-commit logic itself was sound — it was the
first thing to actually *pay* the latencies the SoC memory was stamping, and those stamps
were diverging.

Root cause: `memory.cpp`'s bandwidth model keeps a per-instance busy-stamp
(`next_packet_start`); each request of `size` bytes occupies
`duration = ((size-1) >> width_log2) + 1` cycles, and a request arriving while busy gets
`latency += next_packet_start − now`. Both SoC backing stores in `cachepool.py` were at
**`width_log2=2` (4 B/cycle)** — an ~8× under-provision against the ~32 B/cycle aggregate
VLSU stream of a 4-core tile. The stamp ran further and further ahead of real time, so
latencies grew linearly with traffic volume: a bandwidth model that had silently
degenerated into an unbounded queueing delay.

Fix (pulp `6b7cf09`): `width_log2` 2→**6** (64 B/cycle) on **both** `mem` (cached DRAM) and
`uncached` (the 0xA0000000 region). Burst latencies immediately bounded (max ~13) and the
collapse disappeared. Note this is still an idealized fixed-latency store — the realistic
DRAM timing point remains DRAMSys (P3.1) — but at least its bandwidth term no longer lies.

## 4. Verification

### 4.1 Calib TB (regression gate for the cache model itself)

`gvsoc --target=insitu_cache_calib`, traces `warm_hit_isolated` / `cold_miss_isolated`
(RTL references: warm hit **10**, cold miss **ML+17** = 67 @ ML=50):

| path | xbar_lat=0 | xbar_lat=1 (default since core `0f32f605`) |
|---|---|---|
| async calibrated controller | **67 / 10** ✓ exact | 67 / 10 (flat tile has no xbar) |
| structural (tile + inline sync, BANKS=1) | **67 / 10** ✓ exact | 68 / 11 (+1 = the intended RTL `tcdm_cache_interco` spill-register hop) |

- A1 touches ISS-only files; the calib TB (trace-replay, no ISS) is provably unaffected —
  confirmed by exact reproduction of the references.
- The structural 68/11 at the new xbar=1 default is **not a regression**: it is step-4's
  calibrated interco hop, which the RTL *standalone* calib TB (one ctrl, no interco) does
  not include. New pulp knob `INSITU_CALIB_XBAR_LAT` (`44ad448`) selects the boundary:
  0 for the 1:1 RTL-TB diff (10/67), 1 for production fidelity (11/68 at the driver).
- **Methodology traps (re-)learned:** (1) `gvsoc` needs the py312 shim on `PATH` or the
  target Python dies on `str | None` — silently, if stdout is redirected, leaving stale
  CSVs to be misread as results; (2) target Python is *copied* into
  `install/generators/` at build time (`copy_if_different`) — source edits need a
  `make build` to take effect; (3) always `rm gvsoc_config.json` between knob changes.

### 4.2 Kernel runs (16-core 4×4, cache ON, full steps-1–4 calibration + A1)

Post-A1 4-core spot checks: fdotp M8192 49,763 / M32768 148,227 · gemv-opt 150,588 ·
fmatmul 23,129 · spin-lock 8,561 (`result: 6; gold: 6`) · byte-enable PASSED 198,705 — all
data-correct, burst latencies bounded (max ~13).

Full 16-core sweep (4 tiles × 4, cache ON), all retval=0, zero FAIL lines, positive
markers where the kernel prints one (spin-lock `result: 120; gold: 120`, byte-enable
`PASSED`):

| Kernel | pre-A1 16-core cyc | post-A1 16-core cyc | Δ | driver of the change |
|---|---|---|---|---|
| spin-lock | 26,879 | 24,001 | −10.7% | bandwidth (small; AMO/scalar-dominated) |
| load-store_M16 | 1,108,280 | 567,257 | −48.8% | **bandwidth** (serial-miss kernel) |
| fdotp-32b_M8192 | — | 48,877 | — | (no pre-A1 16c baseline) |
| fdotp-32b_M32768 | 87,346 | 147,383 | +68.7% | **delayed-commit** (VLSU stream) |
| gemv-opt_M512_N128_K32 | 89,481 | 154,115 | +72.2% | delayed-commit (VLSU stream) |
| fmatmul-32b_M32_N32_K32 | 48,765 | 37,858 | −22.4% | bandwidth (store-heavy, small-M) |
| fft-32b_M1024_N16 | 57,934 | 109,226 | +88.5% | delayed-commit (VLSU stream) |
| linked-list_M1_N1350_K10 | 4,312,955 | 2,215,363 | −48.6% | **bandwidth** (pointer-chasing = serial misses) |
| byte-enable | 210,777 | 204,873 | −2.8% | mixed, near-flat |

**Reading the table — two opposing effects, both fidelity fixes, and the pre-A1 baseline
was polluted by both bugs:**

1. **A1 delayed-commit (makes streaming kernels cost more).** Pre-A1, VLSU bursts
   committed at issue (~0-cycle), so fdotp/gemv/fft cycle counts were a lower bound that
   ignored the cache entirely. Post-A1 they pay the calibrated cache + memory latency at
   the scoreboard → +69…+89%. This increase is the *intended* effect — the first
   end-to-end numbers that include the cache on the vector path.
2. **Bandwidth divergence removed (makes miss-heavy kernels cost less).** The pre-A1
   baseline ran with `width_log2=2`, where the memory busy-stamp diverged under VLSU
   streams — and the *cache refill path* pays that memory latency on every miss even
   pre-A1. So serial-miss kernels (load-store, linked-list) were inflated by an
   ever-growing fake queueing delay; with `width_log2=6` the miss latency is bounded and
   they drop ~49%.

The pre-A1 numbers were therefore neither consistently optimistic nor pessimistic — each
kernel sat at a different mix of the two bugs. The post-A1 column is the new baseline for
the RTL cycle-count diff (remaining calibration item).

## 5. Files

- `core/models/cpu/iss/include/cores/ara/ara.hpp` — delayed-burst queues on the Spatz `AraVlsu`.
- `core/models/cpu/iss/src/ara/spatz_vlsu.cpp` — OK-with-latency hold + fsm drain-all.
- `pulp/cachepool.py` — `width_log2` 2→6 on `mem` + `uncached`.
- `pulp/insitu_cache_calib/__init__.py` — `INSITU_CALIB_XBAR_LAT` override.

## 6. Follow-ups

- The delayed-commit now exercises `get_full_latency()` on every burst — any other
  interconnect component stamping pathological latency will now be *visible* in kernel
  cycles (that's a feature: it surfaced the bandwidth bug within one run).
- P1.2 next (E1 MSB address rotation). P3.1 keeps the real DRAM-timing answer on DRAMSys.
