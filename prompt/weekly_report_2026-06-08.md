# Weekly Report — GVSoC InSitu L1 Cache Model

**Period:** 2026-06-01 (Mon) → 2026-06-08 (Mon)
**Engineer:** Zexin Fu
**Area:** Cycle-approximate GVSoC performance model of the CachePool InSitu L1 data
cache, calibrated against the RTL standalone testbench.

---

## TL;DR

This week the GVSoC InSitu-cache model went from "primary metrics matched" to
**calibrated against the RTL standalone testbench across the full phase suite**. Built
the GVSoC-side calibration harness (twin of the RTL `cache_calib` TB), mirrored its new
phases, closed every *throughput* and *headline-latency* gap, and rigorously bounded the
one remaining gap (coal_cold's outstanding/latency *shape*) — proving via a design↔verify
loop that it cannot be closed without an unproven, high-risk refactor, so it is scoped
rather than forced. Also rebased both dev branches onto upstream and bumped the engine.

**Calibration scorecard at week end (GVSoC vs RTL):**

| Metric | GVSoC | RTL | Status |
|---|---|---|---|
| Warm read hit (isolated / streaming) | 10 / 7 | 10 / 7 | ✅ |
| Hit injection-gap sweep (gap 0/1/2/3/7) | 7/8/9/10/10 | 7/8/—/10/10 | ✅ exact |
| Cold miss latency (BL4 / wide-BL1) | ML+17 / ML+13 | ML+17 / ML+13 | ✅ exact across ML sweep |
| coal_warm (4-port, warm) thr / lat | 3.12–3.37 / 7 | 3.28 / 7 | ✅ |
| Warm write lat / write-stream thr | 8 / 0.478 | 8 / 0.489 | ✅ |
| Read-after-write same word | 7 | 7 | ✅ |
| cold_stream (wide) thr / lat / out | 0.254 / 95 / 32 | 0.243 / 100 / 32 | ✅ |
| coal_cold (wide) **throughput** | 0.496 | 0.467 | ✅ (+6%) |
| evict (wide) throughput / mem_wr | 0.166 / 1024 | 0.177 / — | ✅ |
| Memory traffic (coal_cold mem_rd) | 32 | 32 | ✅ |
| coal_cold **out / latency** (shape) | 128 / 146 | 56 / 82 | ⚠ open (coupled; see below) |

All throughputs and headline latencies match; the lone open item is coal_cold's
outstanding-count and per-access-latency *shape*.

---

## What was done (by day)

### Mon 06-01 — Calibration harness + RTL-update tracking
- **Adopted the dev-log convention** into the repo's `CLAUDE.md` (running
  `prompt/WORKLOG.md`, newest-first) so weekly reports assemble from the log + `git log`.
- **Built the GVSoC-side calibration testbench** — the twin of the RTL `cache_calib`
  standalone TB (one `cachepool_cache_ctrl` + a deterministic fixed-latency refill
  responder), so both engines run the *same* trace through the *same* memory-timing model
  and we diff the per-access latency:
  - `insitu_calib_mem` — serializing fixed-latency refill memory (`mem_busy_until`).
  - `insitu_cache_calib` target — trace-replay driver + per-access/aggregate CSV monitor,
    shared `port,rw,addr,size,delay` trace schema, single-controller DUT geometry
    (5 ports, 4-way × 256-set = 64 KiB = one RTL controller).
  - Trace suite generator (`gen_traces.py`).
  - Primary metrics matched out of the gate: warm hit 10, cold miss ML+17 (exact across
    ML∈{10,50,100,200}), serialized-refill miss throughput.
- **Tracked an RTL update:** the shipping `cachepool_512` default flipped to the
  *production* cache (folded + hash-way + forwarding-buffer ON). Updated the model's
  default config to match (`make_cachepool_512_config` now production; added a
  `conventional` variant) and refreshed the architecture doc.

### Tue 06-02 — Mirror new RTL phases, close gaps, rebase
- **Mirrored 7 new RTL calib phases** (warm-write, read-after-write, cold/warm 4-port
  coalesce, dirty-fill / writeback-miss eviction) and added **memory-traffic counters**
  (`mem_rd`/`mem_wr`) via an end-of-sim hook. coal_cold `mem_rd=32` and evict
  `mem_wr=1024` reproduce the RTL traffic structure (MSHR-merge collapses 128 same-line
  accesses to 32 refills).
- **Closed the tractable calibration gaps:** write path (early write-ack + write-commit
  backpressure → warm write 10→8, write-stream 0.877→0.478), forwarding buffer
  (read-after-write 13→7), writeback overlap (evict 0.0126→0.0189). All gated; only the
  production config opts in.
- **Infra:** committed all WIP, rebased both `insitu-cache` dev branches onto upstream
  `master` (no conflicts), and **bumped the engine** `a8c57439→a6d92918` (required —
  upstream core's `memory_v3`/`fst_dumper` need the `IoV2Sync` signature). Verified clean
  build (116 targets) + calibration unchanged post-rebase.

### Wed 06-03 — Wide-refill experiment + miss-throughput occupancy model
- **Wide single-beat refill (BurstLength=1) experiment** mirroring the RTL
  `THROUGHPUT_EXPERIMENT.md`: an `INSITU_CALIB_WIDE_REFILL` toggle pipelines refills and
  binds on the 32-outstanding requester budget. Cold miss latency → ML+13 (exact),
  max_outstanding → 32, sustained plateau ≈ 0.49 (matches the doc's Little's-law plateau).
- **Miss-throughput occupancy model** (gated `defer_refills` + a single `refill_drain`
  cyclestamp; default OFF = inline = the Spatz path): closed wide-mode miss-heavy
  throughput from 1.4–2.8× over to **within ~7%** (cold_stream 0.254 vs 0.243, coal_cold
  0.494 vs 0.467, evict 0.166 vs 0.177). Grounded by a research+design multi-agent
  workflow and **adversarially verified (GO)** — the review caught and removed 3 dead
  knobs and confirmed the Spatz path stays byte-identical and no new non-OK status leaks.

### Thu 06-04 — Input coalescer, hit pipelining, and the coal_cold deep-dive
- **Input par-coalescer** (interco same-cycle same-line read-hit merge): closed the last
  headline throughput gap, **coal_warm 0.06 → 3.12 acc/cyc** (RTL 3.28). Gated default-OFF;
  Spatz/microbench byte-identical.
- **Streaming read-hit pipelining:** modelled the RTL hit pipeline fill/drain so a
  streaming hit costs **7** and an isolated hit **10**, via a per-controller warmth
  gradient. Verified **exact** against the RTL injection-gap sweep (added `bw_hit_gap*`
  traces → 7/8/9/10). coal_warm latency followed to 7 for free.
- **coal_cold occupancy refactor — rigorously bounded.** The remaining coal_cold gap
  (out 128 vs 56, lat 146 vs 82) was investigated exhaustively: 3 incremental attempts +
  a designed deferred-completion refactor + a 3-round design↔verify loop (all
  adversarially verified). **Verdict: definitive NO-GO**, with *proofs* (not assertions):
  1. Deferred completion is a **measurement no-op** — the calib latency is determined at
     issue (`t_resp = t_issue + full_latency`); coal_cold latency scales lockstep with
     MemLat (ML+96.5), a per-line install-ramp tail, not a deferrable stagger.
  2. Pre-dirtying (to match RTL's `mem_wr=32`) **regresses** it (0.31 thr / 169 lat).
  3. An accept-throttle **breaks coalescing** (DENYs cold followers; port-0 race).
  4. throughput/latency/out are **one coupled knob** (D-sweep confirms D=3 is the joint
     optimum — helping coal_cold drags cold_stream off its exact match).
  Conclusion: throughput already matches; the out/latency residuals are coupled RTL-shape
  metrics whose only convergent fix is an unproven Phase-B controller same-line
  MSHR-collapse + install cap. Documented the four proofs and scoped the Phase-B item;
  **no risky code landed.**

---

## Commits this week

`core` (insitu-cache) and `pulp` (insitu-cache) on the `Aquaticfuller/*` forks; parent on `main`.

| Repo | SHA | Subject |
|---|---|---|
| core | `233850f4` | calibration memory model + timing knobs |
| core | `6347ea65` | wide-refill memory mode + miss-throughput occupancy model |
| core | `5f8c243f` | model input par-coalescer in the interco |
| core | `edfc99d2` | model streaming read-hit pipelining (10 → 7) |
| pulp | `3d15e5d` | calibration + microbench testbench targets |
| pulp | `f80254b` | wide-refill toggle + outstanding-budget driver |
| pulp | `a39275a` | preload coal_warm via the scalar port |
| pulp | `2282baa` | hit-pipeline injection-gap sweep traces |
| pulp | `cd04829` | document coal_cold mem_wr=0 is by design |
| parent | `1e0586a`/`e1c7342`/`b920e3f` | docs + reports + upstream rebase + engine bump + pointers |
| parent | `7e32327` | occupancy model + wide-refill calibration (docs + submodule bumps) |
| parent | `d2091d1` / `2eb3f7b` | par-coalescer / streaming-hit pointer bumps + docs |
| parent | `57e137a`/`3f56e62`/`5778953`/`d012d3a` | Change-B (coal_cold) investigation + NO-GO docs |

**Push status:** the 06-02 and 06-03 rounds were force-with-lease pushed to the forks; the
06-04 work (par-coalescer, streaming-hit, coal_cold docs) is **committed locally and not
yet pushed**, at request — ready to push on the word. The parent `main` is committed
locally throughout (submodules-only push preference).

---

## Open items / next

- **coal_cold out (128 vs 56) + latency (146 vs 82):** the one open calibration gap.
  Coupled RTL-shape metrics; convergent fix is a Phase-B controller same-line MSHR-collapse
  + ~14-line install cap (gated, defer_refills-only) — **scoped, unproven** (could overshoot
  throughput), deliberately not implemented. (calib report §13.)
- **Saturation single-port hit ceiling** ~0.91 vs RTL 0.865 (a sub-cycle accept-rate item,
  unmasked by the now-correct streaming latency).
- **Scalar bypass** — low value (the isolated scalar latency already matches; the sample
  trace's contention is memory-side, which RTL would also show).
- **Spatz end-to-end runtime validation** (run a real workload with `use_insitu_cache=True`).
- **Push** the 06-04 local commits to the forks.

Full detail and reproduction numbers: `prompt/insitu_cache_calib_report.md` (§1–§13) and
`prompt/WORKLOG.md`.
