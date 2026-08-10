# GVSoC-side Agent — Plan & Notes (response to `HANDOVER_GVSoC_AGENT.md`)

**Date:** 2026-08-10 · **Author:** GVSoC-side agent · **Status:** plan for review
**Reads with:** `HANDOVER_GVSoC_AGENT.md` (the RLC-side handover this responds to)

**Priority set by the user (2026-08-10):** make the **multi-group design work first**
(→ a new `cachepool_v3` target that merges the mesh with the calibrated cache), then discuss
SW-side next steps. Everything else in this file is context or queued.

---

## 1. What I verified against the handover (4 checks, all with results)

### 1.1 The handover's premise is validated — GVSoC matches RTL within ±4% on this kernel

The handover bets on "GVSoC for day-to-day work, no RTL sim", but nobody had diffed our GVSoC
numbers against its §2 RTL table. Done, on the binaries as rebuilt 2026-08-10 17:38 (results are
byte-identical to my 08-05 runs, so the comparison is exact):

| TC2 `M48_N800_K300` | RTL work-phase (§2) | GVSoC work-phase | Δ |
|---|---|---|---|
| 2P2C | 530,059 | 550,721 | **+3.9%** |
| 4P4C | 316,688 | 306,523 | **−3.2%** |
| 2P8C | corrupt (1 SB violation) | 514,686 **clean** | — |
| 4P8C | corrupt (deadlock) | 255,565 **clean** | — |

**Compare work-phase, not EOC.** GVSoC's EOC carries ~300 k cycles of ELF-loader that the RTL
flow doesn't (RTL 651,553 vs GVSoC 954,001 at 2P2C is almost entirely that). Work-phase =
`max(end cycle) − min(start cycle)` over the per-core prints.

±4% is the best real-kernel agreement in the GVSoC calibration project (for comparison: fdotp
+16%, load-store +81%). **Conclusion: RLC kernel iteration on GVSoC is trustworthy, and cycle
deltas from kernel changes can be believed at the few-percent level.**

### 1.2 P0 (C≥8 corruption): GVSoC is clean — plus a sharper inference than §5.3's

Handover §5.3 predicted GVSoC might not reproduce it and asked us to report that. Confirmed:
**P2_C8 and P4_C8 both run clean** (retval=0, zero FAIL/ERROR lines, work 514,686 / 255,565).

Sharpening it: **both simulators execute the same ELF.** So the "missing `memory`/vreg clobbers
let the compiler reorder" suspect (§6a) is weakened *as a static-miscompilation story* — a
mis-ordered binary would be equally mis-ordered on GVSoC. What survives is **dynamic exposure**:
§6b (SN scalar store racing the async vector copy) or §6c (a genuine RTL cache race).

Honest caveat: GVSoC's timing is far more forgiving than RTL (in-order sync-slave cache path,
delayed-commit VLSU), so it may simply fail to *expose* an ordering bug that is latent in the
binary. Evidence, not proof.

**Cheaper debug path than waveform-mining (offer):** push the GVSoC model toward RTL-level
concurrency and see if it breaks in a *debuggable* simulator —
`CACHEPOOL_VLSU_OUTSTANDING`, `CACHEPOOL_LSU_OUTSTANDING`, `CACHEPOOL_CELL_COALESCER=0/1`,
`CACHEPOOL_MEM_LATENCY` high, `CACHEPOOL_BANKS_PER_TILE` variations. If any point in that
envelope corrupts, root-cause with traces/printf instead of a 60 µs waveform. If nothing
corrupts across the envelope, that is a much stronger negative result for the RTL side.
*(Queued behind the v3 work per the user's priority.)*

### 1.3 Handover §2's kernel scaling ceiling: ~12–16 active cores (the retry storm)

Documented in `prompt/multiuser_llist_sweep_2026-08-05.md` §7. In plain terms:

- A consumer that finds its user's list empty **immediately retries** on the next loop iteration
  — the source comments say this is deliberate, to preserve the baseline's idle lock traffic.
- At 2–8 consumers that is harmless. At 48+ consumers, every consumer is doing a lock
  round-trip per iteration on a handful of shared lines. That traffic saturates the banks those
  lines live in, so the **producers' own writes can't get through** — the queues never fill, so
  the consumers keep finding them empty, so they keep retrying. **Livelock:** the machine is
  100% busy and does almost no useful work.
- Measured: at 64 active cores, **22.9 billion** read-hits on one flag line; at 256 active,
  **34.2 billion**; producer writes on the descriptor bank in the tens. I killed both runs
  after ~27 h; they cannot finish in any practical window.
- **Consequence for the plan:** handover §Step-2 acceptance level (b) ("one shared kernel across
  the mesh, producers/consumers spanning groups") **cannot work with the current kernel at high
  core counts, on any platform**. Level (a) (independent per-group kernels at 2P2C/4P4C sizes) is
  the right first target and is consistent with what completes. Level (b) needs a kernel change
  first: gate the failed-pop retry behind a list-nonempty hint, or stripe the descriptor stream.

**Why this should be shared with the Huawei side (Johannes):** he is designing a new kernel with
TTI scheduling and possibly lock-free deques. Both naturally avoid this storm (a TTI schedule
tells a core *when* to work instead of letting it spin; lock-free deques remove the contended
lock line). So (a) it is a concrete argument *for* his design direction, (b) if he doesn't know,
he may reuse the same retry pattern, and (c) for the A/B comparison it is essential context —
otherwise our baseline "loses" at high core counts for a reason that is a known kernel artifact,
not a platform limit.

### 1.4 `cachepool_v2` fidelity gaps (this is what forces the v3 decision)

| | `cachepool` (v1) | `cachepool_v2` |
|---|---|---|
| Topology | **1 group**, flat remote xbar (256 cores demonstrated 2026-08-06) | **X×Y groups + FlooNoc 2D mesh** ✅ |
| L1 cache model | **structural + all calibration** (E1/D1/D2/B1/C1/B3/F1/E3/J1) | flat `InsituCacheController` + `Coalescer` — **none of it** |
| `l1d_part` / `l1d_addr` / `l1d_xbar_config` | **implemented + RTL-validated** (E3.6) | **absent** → silent no-ops |
| L1D flush fan-out (F1) | implemented | absent |
| >32-core barrier | fixed 2026-08-05/06 (counting barrier) | already a counting barrier (immune) |

Two consequences: (1) any v2 scaling number is **not** comparable to the ±4%-validated 16-core
numbers; (2) **near-data placement (handover P2.1) cannot be measured on v2 at all**, because the
partition knobs don't exist there. Hence v3.

---

## 2. `cachepool_v3` — feasibility assessment

**Verdict: feasible, and the expensive parts already exist.** v3 = keep v2's cluster / group /
mesh / address-converter / peripheral skeleton, and **swap the per-tile L1 subsystem** for our
structural calibrated tile.

### 2.1 Why the split lands there

The hard, hard-won part of v2 is **not** the cache — it is the L1-NoC address-space transform and
the FlooNoc mapping (`cachepool_v2_l1_noc_address_converter`, the `period=` matching so every
cacheline tag resolves, the mirror window at 0xa0000000 so `.pdcp_src` traffic doesn't silently
drop and wedge an NI's single in-flight-burst slot). That machinery works and should be
inherited verbatim. The cache behind it is the swappable block.

### 2.2 Port-facade mapping (the encouraging part)

| v2 `CachepoolV2L1Subsystem` port | our structural tile |
|---|---|
| `pe_in{i}` (scalar, 1/core) + `vlsu_in{i}_{j}` (4 lanes/core) | `i_INPUT(i*5 + j)` — **exact count match** (`tcdm_ports_per_core=5`) |
| `refill` (composite L2: refill+evict+WT) | `o_L2` — **exact match** |
| `remote_local_in/out{i}` (intra-group tile↔tile) | tile's `remote_in/out_{j}_{r}` (per port-class j, slot r) — mapping decision needed |
| `remote_group_in/out{i}` (inter-group via NoC) | **new**: needs an off-group egress class (see 2.3) |
| — | `i_FLUSH(ctrl)`, `i_CONFIG_CORE/XBAR` — **new on the v2 peripheral** (see 2.4) |

### 2.3 The one genuinely new piece: a cross-**group** routing class

Today `RouteGeom::route_request()` (`insitu_cache_route.hpp`) returns *local bank* or
*remote-tile slot* — it models (tile, bank), with no group field. Two depths:

- **Thin (recommended for v3.0):** put a **group pre-decoder** in front of our xbars — if the
  address's group field ≠ my group, hand the request to v2's existing converter → NoC; else
  route into our structural group unchanged. route.hpp untouched; the mesh is a bolt-on at the
  group boundary, exactly where v2 already puts it.
- **Deep (v3.1+, only if needed):** extend `RouteGeom` with a group field so the structural
  xbars natively route (group, tile, bank). Required only for mesh-aware placement studies
  (near-data across groups); not for bring-up or for the multi-group capability gate.

### 2.4 Blockers to schedule explicitly

1. **v2 peripheral has no L1D register block** → E3 partition knobs and F1 flush fan-out are
   absent in v3 until ported from v1's `cluster_registers.cpp` (0x28–0x4c block + COMMIT
   fan-out + FLUSH_STATUS + the `push_config` broadcast). Known quantity — same code I wrote
   for E3.0–E3.3. **Needed before any near-data (P2.1) work on v3.**
2. **No RTL ground truth above 64 cores.** The RTL has *no* multi-group: `cachepool_pkg.sv`
   declares `NumGroups` but no module instantiates it, and `config/config.mk` errors out above
   `num_tiles=16`. So **v3 = calibrated cache + uncalibrated fabric** — state this on every
   number that crosses a group boundary. Cache-internal behaviour keeps the ±4% pedigree;
   mesh hop/contention timing does not.
3. **Wall-clock.** 256 cores of structural cells is 256 per-cycle FSMs plus the mesh. The v1
   256-core RLC run took ~25 min; v3 will be slower. Bring-up small (see 3.1) and keep the
   256-core config for gate runs only.
4. **Kernel ceiling** (1.3) caps what level (b) can ever show — plan level (a) first.

---

## 3. Plan

### 3.1 Bring-up ladder (each rung is a gate; don't skip)

| Rung | Config | Gate |
|---|---|---|
| R0 | v2 as-is, 2×2 groups × 1 tile × 4 cores (16c) | baseline: v2 boots + fdotp passes → reference point for the swap |
| R1 | **v3**, 1×1 group × 1 tile × 4 cores | structural tile inside the v2 skeleton; fdotp data-correct; no NoC involved |
| R2 | v3, 1×1 group × 4 tiles × 4 cores (16c) | intra-group remote xbars alive; fdotp + fmatmul correct; **cycle-compare vs v1 16-core** (should be close — same cache, different skeleton) |
| R3 | v3, 2×2 groups × 1 tile × 4 cores (16c) | **first cross-group traffic through the mesh**; data-correct; watch NI burst-slot + converter windows |
| R4 | v3, 2×2 × 4 × 4 (64c) | RLC TC2 2P2C/4P4C per-group instances (level a) |
| R5 | v3, 4×4 × 4 × 4 (256c) | full-scale capability gate; RLC level (a); **report as capability, not calibrated timing** |

### 3.2 Phases

- **P-A (now): v3 target skeleton + R1/R2.** New `pulp/cachepool_v3.py` + `pulp/pulp/cachepool_v3/`
  (fork v2's group/tile/cluster, swap the L1 subsystem for `InsituCacheTile`). Deliverable: R2
  green with a v1-vs-v3 cycle diff on the same 16-core workload.
- **P-B: cross-group (R3).** Group pre-decoder + converter/NoC wiring. Deliverable: R3 green,
  plus a documented cross-group latency figure (flagged uncalibrated).
- **P-C: peripheral parity.** Port the L1D block (E3 partition + F1 flush) onto the v3
  peripheral. Deliverable: the partition-aware load-store kernel (E3.6's) passing on v3 →
  unlocks near-data work at mesh scale.
- **P-D: scale gates (R4/R5) + RLC level (a).** Deliverable: multi-group capability report.
- **Then** (per the user): revisit SW-side next steps with the multi-group capability established.

### 3.3 Queued (not started, ordered)

1. C≥8 stress-hunt on GVSoC (1.2) — cheap, could close a real bug.
2. RLC baseline package as the shared A/B reference (the ±4% table + throughput/TTI +
   the ~12–16-core ceiling). Note: **forwarding-buffer stats cannot come from GVSoC** (that
   component is transcribed but not wired) — RTL-only column.
3. Near-data placement prototype (P2.1) — on v1 today, on v3 after P-C.

---

## 4. Notes, inherited pitfalls, and one design warning

- **Design warning for near-data placement (P2.1), from E3.5:** the RTL's lookup is
  **hash-way-only**, so a bank that receives *two* address-residue classes collapses to **≤2
  effective ways per set** on sequential streams. Measured on the calib TB: mixed partitions
  (m=2, m=3) lost their entire footprint on 2-class banks while 1-class banks kept everything.
  So a naive "one private arena per tile" split can *reduce* effective associativity and lose
  performance. Placement must keep an entity's footprint within one residue class per bank
  (or accept the collapse knowingly).
- **Build-env pitfall (handover §5.1) confirmed** — cache components are compiled at build time;
  group components are dropped from the build graph unless the *build* env carries the group
  topology. Same trap will apply to v3's knobs. Already in our `CLAUDE.md`.
- **`gvsoc_config.json` is never regenerated if present** — `rm -f` it between topology/knob
  changes or you silently simulate the old topology.
- **Handover §Step 0 is stale:** both PRs are pushed as of 2026-08-10
  (`Aquaticfuller/gvsoc#1` auto-closed as merged; parent `main` = `f511d7d`, core
  `insitu-cache` = `e0ed63d5`, pulp `insitu-cache` = `92f699f`).
- **Artifacts:** honouring handover §7 — run artifacts go under `reports/` (RTL repo) or
  `prompt/` (GVSoC repo), not `/tmp`. (Past sweeps' raw logs were in `/tmp`; the reports
  themselves are committed.)
- **Two copies of the handover exist** (kernel `doc/` and GVSoC `prompt/rlc_kernel_dev/`).
  Worth naming one canonical to avoid drift.

## 5. Open decisions for the user

1. **v3 depth:** thin group pre-decoder (2.3, recommended — gets multi-group working fastest) vs
   deep route.hpp group field (needed later for cross-group near-data studies). Start thin?
2. **v3 vs v2 coexistence:** new target `cachepool_v3` alongside v2 (recommended — v2 keeps
   working, no regression risk), or evolve v2 in place behind a flag?
3. **Share the retry-storm finding with Johannes** (1.3)? Recommend yes.
4. **Handover doc ownership** — I can patch §Step 0 + add these findings as a §8, or leave one
   canonical copy to the RTL-side agent.
