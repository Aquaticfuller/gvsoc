# GVSoC InSitu-Cache Model — Development Log

> Newest entries at top. Convention defined in `CLAUDE.md`

---

## 2026-08-25 ~08:55 +0200 — #42 FIXED (strided/indexed vector ops) — a real latent bug, but no workload we own exercised it

**Fix.** `core/models/cpu/iss/isa_gen/isa_rvv_timed.py`: 24 instructions retagged —
`vlse{8,16,32,64}.v` gain `vload_strided`, `vsse*` gain `vstore_strided`, `vluxei*`/`vloxei*` gain
`vload_indexed`, `vsuxei*`/`vsoxei*` gain `vstore_indexed`.

**Key implementation point: the specialised tag is ADDED, not substituted.** `ara.cpp:441-457`
assigns `block_id` from the *generic* `vload`/`vstore` tags, while `spatz_vlsu.cpp::isa_init()`
registers the generic `block_handler` first and the specialised one **after** — so dual-tagging lets
the specialised handler win while block dispatch still works. Replacing the tag (as a naive reading
of the issue suggests) would have broken `block_id` assignment instead.

**Verified active, not assumed.** Added an env-gated diagnostic (`VLSU_TAG_DEBUG=1`) printing the
per-tag instruction counts at `isa_init`:

```
[VLSU-TAG] vload -> 49   vstore -> 36
[VLSU-TAG] vload_strided -> 8    vstore_strided -> 8
[VLSU-TAG] vload_indexed -> 16   vstore_indexed -> 16
```

Previously all four specialised counts were **0** while `spatz_vlsu.cpp` registered handlers against
them — the handlers existed and could never fire. (Counts are 2x the source instructions because the
generated ISA defines them in two subsets; handler assignment is idempotent.) Kept the diagnostic:
env-gated, zero cost, and it is exactly the check that distinguishes "fix applied" from "fix active".

**Behaviour is byte-identical across the suite — and that is the correct outcome, not a failed fix.**
Disassembly counts of strided/indexed instructions in the workloads we run:

| kernel | vlse | vsse | vluxei | vsuxei |
|---|---|---|---|---|
| `byte-enable` | 0 | **4** | 0 | **4** |
| `fdotp-32b_M32768` | 0 | 0 | 0 | 0 |
| `cache-test-vector` | 0 | 0 | 0 | 0 |
| `cache-line-rw-smoke` | 0 | 0 | 0 | 0 |
| `bandwidth` | 0 | 0 | 0 | 0 |

**Only `byte-enable` uses them at all**, stores only, and it passes 14/14 with an identical trace
cycle count (252,494) before and after. So this is a **latent** bug fixed — real, and it would have
silently corrupted any kernel using a non-trivial stride (the RLC kernels do), but invisible to our
current suite.

**Two claims from the 08:40 entry corrected in place:**
- *"#42 plausibly explains the fdotp residue"* — **wrong.** fdotp contains zero strided instructions;
  its geometry stride is pointer arithmetic over unit-stride `vle32.v`. The 77 % residue is still
  unexplained.
- *"#42 undermines the byte-enable calibration anchor"* — **overstated.** The anchor stands: the
  0.87x ratio is byte-identical across the fix.

So the 08:10 calibration conclusion — error confined to the refill path, established by the sign flip
— is **unaffected**, which is the more important of the two corrections.

**Regression:** `cache-line-rw-smoke` PASS on v1 and v3; `byte-enable` 14/14 PASS; `fdotp` unchanged.


---

## 2026-08-25 ~08:40 +0200 — EIGHT open GVSoC bugs filed upstream against our model (with root causes and fixes)

**`github.com/pulp-platform/ManyRVData/issues` has 12 open issues and 8 of them are GVSoC bugs in
our model**, filed by an external user (`jpf-h`) who has been running it. Each carries a diagnosed
root cause and a proposed fix. We had not looked.

| # | title | status in our tree |
|---|---|---|
| #43 | `vmv.v` tracks a wrong dependency on `v0` | **PRESENT** — `vmv.v.x` uses `Format_OPV`, `vmv.v.i` uses `Format_OPIVI`; no `Format_VMV_X`/`_I` |
| #42 | strided/indexed vector loads execute with **unit stride** | **PRESENT — confirmed** |
| #40 | AMO unit busy-time includes the requester's queueing time | not checked |
| #39 | three 64-tile scale bugs (`and.cpp` 32-bit shift; `cache_sync` init; xbar requester-side fill) | not fully checked |
| #38 | `LR.W` returns its value in the wrong register | not checked |
| #37 | ISS HTIF pollers generate timed fabric traffic, saturating a cache bank at high core counts | not checked |
| #36 | only one icache for all tiles (RTL has one per tile) | not checked |

**#42 confirmed in source and it is the serious one.** `isa_rvv_timed.py` tags `vlse8/16/32/64.v`,
`vsse*`, `vluxei*`, `vsuxei*`, `vloxei*`, `vsoxei*` all as plain `vload`/`vstore`. Meanwhile
`spatz_vlsu.cpp:168-180` registers handlers for `vload_strided`, `vstore_strided`, `vload_indexed`,
`vstore_indexed` — **tags that no instruction carries** (`grep -c` = 0, as is `vothers`). So the
strided and indexed handlers exist and are never invoked, and **every strided/indexed vector memory
op executes as unit-stride**: silent data corruption, no diagnostic.

**Direct consequences for today's work:**

1. ~~**It plausibly explains the `fdotp` 64-core residue**~~ — **WRONG, disproven 08:55.** `fdotp`'s
   disassembly contains **zero** `vlse`/`vsse`/`vluxei`/`vsuxei` instructions. It is not a strided
   kernel; the geometry stride is done with pointer arithmetic and unit-stride `vle32.v`. The 77 %
   residue remains unexplained.
2. ~~**It undermines the `byte-enable` calibration anchor delivered at 08:10.**~~ — **overstated,
   see 08:55: the anchor STANDS.** byte-enable does use strided/indexed stores, but its results and
   cycle count are byte-identical before and after the fix, so the 0.87x ratio is unaffected. That kernel's sub-tests
   are exactly `vsse16.v` (strided) and `vsuxei16.v` (indexed). It reported `[PASS]` on our model —
   which, if both the store and the verifying load degrade to unit-stride *consistently*, is a
   **vacuous pass**: self-consistent and wrong. The 0.87x cycle ratio may therefore be measuring
   different work than the RTL performed. The `bandwidth` 14.2x is unaffected (no strided ops), but
   the **sign-flip argument now rests on a suspect second point** and must be re-established.
3. **#39's second bug is the exact fatal we hit this session** — `cache_sync` uninitialised causing
   "Trying to decrease zero stalled counter" at high core counts. We debugged that blind.
4. **#37 (HTIF polling saturating a shared bank, scaling with core count)** is a timed-traffic source
   we never accounted for, and is a candidate contributor to the hangs and shared-bank contention we
   have been attributing elsewhere.
5. **#36 (single icache for all tiles)** matters for any instruction-fetch-sensitive measurement at
   64 tiles.

**Assessment.** These change our priority ordering. Three of them (#42, #39, #37) touch results we
produced today, and #42 in particular is a correctness bug of the same class as the cross-line
truncation — silent, data-corrupting, and invisible to our own regression suite. They also come with
fixes already worked out, which makes them cheap relative to the refill-path work.

**Recommended order:** #42 first (correctness, cheap, invalidates measurements), then #39 and #37
(both explain observed failures at scale), then the refill-path MLP/channel work, then #36/#38/#40/#43.


---

## 2026-08-25 ~08:10 +0200 — 64-CORE CALIBRATION ANCHORED: the error is confined to the refill path (the sign flips)

**First full-occupancy RTL-vs-model calibration, and the headline result of the session.** Both
kernels at 64 cores on `cachepool_fpu_4g`, in-kernel stamps (not EOC, which includes a boot sequence
that differs between engines):

| kernel | character | RTL | GVSoC | GVSoC/RTL |
|---|---|---|---|---|
| `bandwidth` | memory-bound, **exercises the refill path** | 2,058 cyc (32/load) | 29,122 (455/load) | **14.2x SLOW** |
| `byte-enable` | L1-resident, all-shared, **no refills** | 289,468 | 252,494 | **0.87x — 13 % FAST** |

Plus the earlier RLC anchor (4 active cores, latency-bound, L1-resident after warm-up): mean
**+14.8 %**, fast pair within **0.6 %**.

**The sign flip is the result, not the ratios.** A uniformly-slow model cannot be 14.2x slow on one
kernel and 13 % *fast* on another. So **there is no global constant to hunt**: the entire error is
confined to the refill path, and the L1 / cache-pipeline / crossbar / ISS modelling is in decent
shape. That is a much stronger conclusion than parity on both would have given, and it came from a
single L1-resident kernel because the alternative hypothesis predicted 14x for it.

**Search space, now supported rather than speculative** — all three are refill-path mechanisms:

| cause | evidence | vs RTL |
|---|---|---|
| MLP = 1 per controller | `insitu_cache_core.cpp:1098` | `spatz_max_trans=32`, `snitch_max_trans=16`, `NumAxiMaxTrans=64` |
| 4 channels -> 1 backing store | `cachepool_v3_system.py:264` | 4 independent DRAMSys HBM2 controllers |
| flat 50-cycle latency | `memory.Memory(latency=50)` | HBM2 with row buffers + bank-level parallelism |

**Falsifiable target for the fix**, from their measured counters and independent of which mechanisms
sum to the gap: **335 AR transactions in 2,241 kernel cycles -> effective concurrency >= 7.5 at
L=50** (a lower bound). If MLP and channels are fixed and 32 cycles/load is still out of reach,
there is a fourth mechanism and this diagnosis was incomplete.

**Recommended order (pending user authorisation):** (1) lift the MLP gate — bounded, the MSHR already
tracks multiple pending lines, but **re-run the correctness suite, not just timing**: MLP=1 serialises
refill *ordering*, so lifting it enables interleavings that have never executed here; (2) give each
channel its own backing store — a configuration change worth ~4x on its own; (3) re-measure against
the >= 7.5 concurrency target.

**Secondary observation, low priority:** the 13 % optimism on `byte-enable` is a real but small
separate question, and the first evidence we have that any part of the model runs *fast*.

**Also delivered to the RTL side, and it grew:** their CI performance suite is **4 of 4 unrunnable**
on its own target config — `fdotp_M65536` (109 scalar-FP instructions), `gemv_M1024_N128_K32` (101),
`fmatmul_M1024_N32_K32` (162), `fft-32b_M1024_N16` (93), with `configs.sh` pinning
`CONFIGS="cachepool_fpu_4g"`, the config they trap on. Root cause visible in the flavour file:
`spatz_fpu_en` / `spatz_num_fpu` enable Spatz's **vector** FPU and nothing there enables the
**scalar** Snitch FPU. So "fpu" in that config name means vector FP only, and the suite's headline
kernels have never been compatible with the config CI runs them against. Third real bug this session
surfaced by our engine running what theirs cannot (after `vmsgtu.vx` and the `fmatmul` trap).


---

## 2026-08-25 ~07:40 +0200 — RETRACTED: our fmatmul numbers are for a program that cannot run on the target

**Scalar floating point does not execute on CachePool RTL at all.** The RTL session ran
`fmatmul-32b_M1024_N64_K64` and got **64 illegal-instruction traps** at `flw ft3, 0(a7)` — one per
core, every core wedged in snRuntime's unhandled-exception `while(1)`. At `M32_N32_K32`: **8 traps,
8 active cores**. The count tracks `active_cores = min(num_cores, M/kernel_size)` exactly, so it is
not size-dependent, not a boundary case and not a race — **every core traps on the first scalar FP
instruction it reaches**.

Cross-checked against the binaries that DO pass on RTL (`bandwidth`, the RLC payload check, legacy
TC1): **zero `flw`, zero `fsw`, zero scalar `fadd`/`fmul` in all three.** Nothing else either of us
has run this session contains a single scalar FP instruction, which is why this never surfaced.

**Consequence for us: our `fmatmul` numbers are deleted, not caveated.** 86,610 / 69,084 were cycle
counts for a program that cannot execute on the hardware being modelled. Struck in the 02:45 entry.

**Two hypotheses raised and both refuted — worth recording because both were plausible:**
1. *"Our ISS ignores `mstatus.FS`"* — **false.** `core/models/cpu/iss/include/isa/rvf.hpp` raises
   `ISS_EXCEPT_ILLEGAL` when `mstatus.fs == 0`, and the `CONFIG_GVSOC_ISS_NO_MSTATUS_FS` opt-out is
   defined only for `magia`, `magia_v2`, `siracusa` and `pulp_cores` — **not** the snitch/spatz/
   cachepool path. Our check is live; under the same architectural state we raise the same exception.
2. *"Their runtime leaves `mstatus.FS` Off"* — **false**, refuted by them from `snitch.sv:2829`:
   Snitch computes `mstatus` on read and hardwires `mstatus.fs = XDirty` whenever `FP_EN`. There is
   no stored FS bit for software to leave Off.

**So the divergence is real but its mechanism is still open on their side.** `cachepool_cc.sv:64`
declares `parameter bit RVF = 1` and `:136` `FPEn = RVF | RVD | XF16 | XF8`, and the generated config
says `isa: "rv32imafd"` — so the hardware is *described* as supporting scalar FP while rejecting it.
Note `cachepool_tile.sv:1484` passes `.RVF(RVF)` with **no `RVF` declared in that file**, so the value
comes from an import; that is where the inconsistency will be.

**Deliberately NOT changing our model yet.** The obvious "fix" — disable scalar FP in our Snitch to
match — would be **matching a bug** if their configuration is simply inconsistent. Until they
establish which behaviour is intended, our model stays as-is and the fmatmul numbers stay deleted.

**Calibration cost:** `fmatmul` was the L1-resident cross-check that would have tested whether the
`bandwidth` 14.2x lives entirely in the refill path. No fmatmul number is available from RTL at any
shape. Substituting `byte-enable` + `cache-line-rw-smoke` — both all-shared and L1-resident — which
answer the same question far more cheaply.

**Value returned the other way:** `fmatmul-32b_M1024_N32_K32` is in *their* CI list
(`util/auto-benchmark/configs.sh`), so either CI runs a config where scalar FP works or CI has been
failing on it. Second real bug this session surfaced by our engine running something theirs cannot —
the first was `vmsgtu.vx`.


---

## 2026-08-25 ~07:10 +0200 — FIRST 64-CORE RTL CALIBRATION: `bandwidth` is 14.2x slow; MLP-of-1 is the primary but NOT the only cause

**The RTL reference batch finally ran** (escalated after five deferrals). First and highest-priority
kernel, `bandwidth`, on `cachepool_fpu_4g` = 64 cores, `l1d_part(4)` = **all private**:

| | RTL | GVSoC | ratio |
|---|---|---|---|
| total cycles | 2,058 | 29,122 | **14.2x** |
| cycles/load | 32 | 455 | **14.2x** |

Provenance checked before comparing (the 06:40 lesson): two independent runs of ours, both launched
at `2 2 4 4` = 64 cores, byte-identical output. Binary assumption and machine agree. The gap is real.

**Primary mechanism — memory-level parallelism of 1.** `insitu_cache_core.cpp:1098`:

```c
// one refill issue per tick, single-outstanding: gate on refill_pending_ (async in flight),
if (!refill_pending_ && !refill_spill_valid_ && refill_ready_cycle_ < 0 && !miss_fifo_.empty()) {
```

**Each cache controller allows exactly ONE outstanding refill.** The synchronous path does the same
explicitly (`sync_refill_busy_until_ = resp_cycle + install_tail_cycles_`). That gate was calibrated
against the standalone `insitu_cache_calib` testbench, whose responder is **deliberately serialising**
— correct there, carried into the full 64-core system unchanged, where the RTL has
`spatz_max_trans = 32` / `snitch_max_trans = 16` / `NumAxiMaxTrans = 64` and overlaps many refills.
That is how RTL reaches **32 cycles/load, below a single DRAM latency**; our model cannot go below
one memory latency per miss per controller by construction.

**But MLP=1 is NOT the whole gap — corrected after doing the arithmetic.** With `_MEM_LATENCY = 50`:

```
MLP=1 at ML=50 predicts   ~65 cycles/load  (50 + ~15 pipeline)
observed                   455 cycles/load
unexplained residue        ~7x
```

So there are **at least two compounding mechanisms**: the MLP-of-1 gate, and roughly another 7x of
downstream serialisation not yet identified — candidates are the 17->1 group refill mux (1 req/cycle)
and the single shared `memory.Memory` backing store behind all channels. Initially reported to the
RTL session as "found it, single mechanism"; that was an over-claim and was corrected.

**Independent confirmation of the mechanism, from their measured counters:** the RTL run reports
**335 AR transactions in 2,241 kernel cycles**. Serialised at latency L the kernel could not finish
in under 335·L, so effective concurrency is **>= 7.5 at L=50** (a lower bound — it assumes zero hit
time and no other overlap). No MLP-of-1 model can produce 32 cycles/load against 335 DRAM round
trips, whatever the mesh does.

**Second-order consequence, and it must not be conflated: the L2 refill mesh is UNTESTED, not
validated.** With MLP capped at 1 there is at most one line in flight per controller, so the mesh has
never carried concurrent traffic — no contention, no arbitration pressure, no queueing. Today's mesh
A/B deltas (+4.4 %, +7.7 %) were measured through a path that serialises to one miss at a time.
"The mesh looked fine" and "nothing ever loaded the mesh" are different statements.

**Which of our numbers this inflates:** every miss-heavy result, including the async-vs-sync
comparisons and the mesh A/B. **Least affected: the RLC calibration (+14.8 %)**, which is L1-resident
after warm-up and latency-bound rather than throughput-bound. That RLC lands at +14.8 % while this
lands at +1320 % is a consistency check on the diagnosis, not a coincidence.

**Not purely a calibration fix — their point, and it is right.** An MLP of 1 also *serialises refill
ordering*, so lifting the gate enables interleavings that have **never executed** on this model and
can expose reordering / MSHR-merge bugs. The correctness suite must be re-run, not only the timing
comparisons.

**Recommended next work (pending user decision):** lift the MLP gate ahead of the visibility bug.
The MSHR already tracks multiple pending lines (`miss_fifo_`, per-line `mshr_[]`), so the structure
exists and the gate is an artificial limit on top of it — a bounded change on a lower-risk surface
than address rotation / barrier ordering. Then re-measure `bandwidth` and hunt the residual ~7x.


---

## 2026-08-25 ~06:40 +0200 — PROCESS FAILURE: we ran 64-core binaries at 4/8/16 cores for hours

**`snrt_cluster_core_num()` is baked into the ELF.** Every CachePoolTests binary is built for
`config=cachepool_fpu_4g` = **64 cores**. Running one on a 4-, 8- or 16-core model does not give a
4/8/16-core run — the software still believes it has 64 and partitions work accordingly. Only the
cores that exist then execute, so the machine computes a **fraction** of the workload, correctly.

**The tell was printed on every single run and neither of us read it.** fdotp's own geometry line is
identical at every config:

```
lmul:8, elem:128, offs:8192, iter:4
```

`elem_jump_per_round = elem_per_round * num_cores`, so 8192/128 = **num_cores = 64** in runs where
4 and 16 cores existed.

**What it invalidates — the visibility bug's density curve.** `cache-basic` partitions by
`lines_per_core = ceil(256/num_cores)` = 4, so with N cores only 4N of 256 lines are ever checked.
Every error count was divided by 8192 as though all were:

| cores | errors | lines actually checked | REAL density | previously reported |
|---|---|---|---|---|
| 4 | 247 | 16 | **48.2 %** | 3.0 % |
| 8 | 701 | 32 | **68.5 %** | 8.6 % |
| 16 | 1718 | 64 | **83.9 %** | 21.0 % |
| 64 | 3894 | 256 | 47.5 % | 47.5 % |

Only the 64-core figure was ever right — the one config where the binary's assumption matched the
machine. **There is no low-density corner.** The "clean corner" technique, the standing rule struck
at 05:00 (for a different and also correct reason), and the RTL session's probability model all
rested on a curve that does not exist.

**What it does NOT invalidate:**
- The **visibility bug is still real** — `cache-basic` fails at 48 % density at the *correct* 64-core
  config while `cache-stress` passes.
- The **layout experiment** and the **M8/M48 contrast** both compared the same binaries at the same
  config, so they were internally consistent and stand.
- The **RLC/AM work** — but **NOT for the reason first written here.** The original claim ("always run
  at 64 cores") was false: the entity ladder, the TC2 runs and both layout arms were all run at
  **4 cores**. They survive for a different and better reason, verified by grepping the kernel:
  **the RLC kernel never calls `snrt_cluster_core_num()`.** Its only topology calls are
  `snrt_cluster_core_idx()` (a core's own id) and `snrt_cluster_core_per_tile()` (for `l1d_part` and
  the cross-tile guard, and 4 cores/tile in every config we ran). Dispatch is by the data header's
  **literal** `producer_core_ids = {0,1}` / `consumer_core_ids = {2,3}` arrays, so cores 0-3 take
  exactly their assigned roles and cores 4-63 were never assigned anything. Nothing is partitioned by
  the baked count — structurally unlike `cache-basic` (`lines_per_core = ceil(256/num_cores)`) and
  `fdotp` (`elem_jump_per_round = elem_per_round * num_cores`), which both silently under-cover.
  That the runs terminated also shows `snrt_cluster_hw_barrier()` does not consult the baked count.

**And it dissolves most of the fdotp "failure".** Coverage is N/64:

| cores | predicted coverage | observed Calc / 209.38 |
|---|---|---|
| 4 | 6.25 % | 19 % |
| 16 | 25 % | **26 %** |
| 64 | 100 % | 77 % |

The 16-core match settles it: fdotp at 4 and 16 cores was **our misuse**, not a defect. Only the
64-core point (77 %) is a real residue, and fdotp's check is separately unpassable by construction
(`fp_check(result[0], dotp_result * measure_iter)` where the loop does not accumulate across
iterations — verified independently by the RTL session; a one-line bug in their test).

**Also established by direct trace, refuting a plausible hypothesis:** watching the `result[]` line
(`0x800037c8`, all four entries in one 64 B line) showed the reduction is **arithmetically perfect** —
core 0's own partial 27.818 + result[1..3] (-87.505, -8.694, 108.705) = **40.3239**, exactly the
reported Calc. All accesses went to a single bank (`ctrl_3`), so routing is correct and cross-core
reads of `result[]` are working. The RTL session's "stale `result[]` reads" hypothesis is refuted.

**Rule to carry: verify the manipulated variable actually moved.** We varied core count for hours
and never checked whether the software noticed. Concretely for this repo: **the CachePoolTests
binaries are 64-core builds; do not run them at other core counts** unless rebuilt for that config,
and check the kernel's own geometry print before trusting any core-count sweep.


---

## 2026-08-25 ~06:05 +0200 — RESOLUTION: layout inert (ladder is not ours); RTL confirms the truncation bug WAS ours

**Two symmetric results closed the "whose bug" question in both directions.**

**1. The RLC ladder is NOT our bug — the 05:45 entry's hypothesis is disproven.** A two-armed layout
experiment on the RTL session's frozen binaries, 4 cores:

| rung | baseline | +320 B shift | stride 124 -> 128 |
|---|---|---|---|
| M16 (failing) | grants=0 | grants=0 | grants=0 |
| M32 (passing) | grants=3 | grants=3 | grants=3 |

**A failing rung fails regardless of layout; a passing rung passes regardless of layout.** Our
visibility bug is address-dependent, so if it were driving the ladder, perturbing every address
would have moved at least one rung. It moved neither. The non-monotonicity (pass at 8/12/32, fail at
16/24/48) is a real property of their kernel.

I proposed that hypothesis, asked for the arm that could falsify it, and it did. Worth noting the
first arm alone would NOT have settled it: testing only whether a *failing* config can be rescued
does not test the claim that a *passing* config's success is fragile. Both arms were needed.

Also narrowed for them from their own descriptor histogram: **M16 and M32 have identical package
parity splits (14 even / 10 odd) and opposite outcomes**, which rules out work distribution too.

**2. RTL confirms the payload corruption WAS ours.** Their `M1_N1350_K4_..._tbchk` completed on
hardware: 1 grant, 4 PDUs, header fields + transport-block offsets + SN continuity + segment
continuity + **byte-exact payload**, 0 mismatches, `tosend=0 sent=4`, `[EOC] retval = 0`.

So `rlc_memcpy8` is correct, the unaligned `e8/m8` base works on Spatz's VLSU, and **our
`verify_mask=0x80` payload failures were the cross-line truncation bug in full** — 231 XLINE events
writing the answer, as the `align_ok=0x0` signature indicated. That call was made before the
evidence existed and is now confirmed by an engine that does not share the defect.

**Net position on our two defects after the night:**
- **Cross-line truncation** — confirmed by an independent engine to be real and to have corrupted a
  correctness verdict. Still unfixed (splitting a straddling access is an FSM change); now loud.
- **Cross-core visibility** — still unfixed, still disqualifies shared-data questions, but its blast
  radius is now *bounded*: it did not cause the RLC ladder. That is worth knowing, because the 05:45
  entry assumed the opposite.

**Caveat carried forward for them (not ours):** their RTL PASS has `segments=0` — four 1360 B SDUs
fit one 8192 B grant, so SI=FIRST/MIDDLE/LAST, the SO field, the partial-SDU cursor and cross-grant
`so_next` chaining were never exercised. The payload question is answered; segmentation is not.


---

## 2026-08-25 ~05:45 +0200 — the RLC "entity count" result is probably our own bug; label axes by what they PHYSICALLY change

**Two sweeps, and the second broke the conclusion the first suggested.**

Sweep 1 — same `M48` binary, varying core count (i.e. varying our visibility bug's density from ~3 %
to ~95 %, holding layout fixed):

| cores | grants | completed_sweeps | XLINE |
|---|---|---|---|
| 4 / 8 / 16 / 64 | 0 | 0 | 0 |

Perfectly flat. Read at the time as "core count irrelevant, entity count everything".

Sweep 2 — the entity ladder at 4 cores, six builds differing only in `ACTIVE_USER_NUMBER`:

| M | 8 | 12 | 16 | 24 | 32 | 48 |
|---|---|---|---|---|---|---|
| grants | 4 | 5 | **0** | **0** | **3** | **0** |
| XLINE | 63 | 63 | 0 | 0 | 60 | 0 |

**Non-monotonic — M32 works while M16 and M24 fail.** Not a threshold, not accumulation, no rule in
entity count at all. (`XLINE` tracks `grants` exactly at every rung, so the pattern is corroborated
through the bug-independent channel; it is not a misread.)

**The likely explanation is ours, not the kernel's.** What the ladder physically varies is not
"entity count" but the **`.data` layout** — the RTL session measured it growing smoothly 21.5 →
44.7 KB, so every rung places `rlc_ctx[]`, `rlc_am_ent[]` and the list heads at different addresses.
Our visibility bug is deterministic **and address-dependent**. A deterministic address-sensitive
corruption sampled at six layouts produces exactly this shape: arbitrary pass/fail with no rule in
the nominal parameter. A kernel bug genuinely keyed on entity count should be monotonic or at least
have a comprehensible rule.

That also retro-weakens sweep 1: it held layout **fixed** and varied cores, so both sweeps are
consistent with "outcome is determined by layout, and M is what changes layout" — a hypothesis
neither sweep was built to test.

**Lesson worth carrying: we labelled the axis by the parameter we varied rather than by what it
physically changed, and those were not the same thing.** Three hypotheses have now died on this
thread (gather cost, stale-read density, entity count); all three died to controlled contrasts
rather than to better theories, and this one died because the "control" was not controlling what its
name implied.

**Discriminating experiment proposed to them:** two `M16` binaries differing only in `.data` layout
(a few hundred bytes of padding ahead of `rlc_ctx[]`). Both fail → layout is not the variable and
M16 has a real kernel problem. One passes → the outcome is layout-determined, it is our bug, and the
entire ladder says nothing about their kernel.

**Bearing on our priorities.** If the padding test comes back "layout", then a substantial part of
this investigation was chasing an artefact of the visibility bug — which is further argument that
fixing it is the highest-value work available, not a nice-to-have.

> **RESOLVED 06:05 — it did NOT come back "layout". This entry's hypothesis is disproven; see the
> 06:05 entry.** Layout is inert in both directions and the RLC ladder is a real property of the
> RTL-side kernel, not our corruption.


---

## 2026-08-25 ~05:20 +0200 — technique: our own instrumentation is an independent channel when the model's shared-data path is untrustworthy

**Problem.** The 05:00 entry established that GVSoC cannot answer cross-core shared-data questions at
any configuration while the visibility bug is open. That appeared to disqualify the engine from the
RLC investigation entirely, since every kernel counter is cross-core shared data.

**It does not, and the reason generalises.** Counters *inside our model* — the XLINE truncation
counters added at 02:20 — are per-cache-instance, incremented in C++, and **never read across cores
by the kernel**. They are on the other side of the interface from the bug, so they are trustworthy
even when everything the kernel reports is not.

**Worked example.** Two runs of the RTL session's controlled pair at 4 cores:

| target | entities | kernel says | XLINE |
|---|---|---|---|
| `M8_N1350_K24_tbchk` | 8 | grants=4, sweeps completed | **63** |
| `M48_N1350_K24_tbchk` | 48 | grants=0, no sweep completed | **0** |

A grant means a payload copy; a payload copy means unaligned accesses; unaligned accesses truncate.
So **`XLINE: 0` confirms `grants=0` through a channel with no dependence on the corrupted reads** —
and `XLINE: 63` confirms the contrary for the control. The kernel's own `grants` counter is
untrustworthy here; the conclusion is not.

Combined with a second bug-independent fact — the run *terminated normally* rather than being killed,
which our harness observes directly — this yielded a solid conclusion from an engine that cannot be
trusted about the kernel's own state: **the consumers exited without ever opening a grant**, i.e. a
premature exit rather than a hang or slowness. That was a third possibility outside the two branches
the RTL session had posed, and it redirected them from the sweep/gather path to the idle predicate.

**Rule worth keeping.** When the model's data path is known-unreliable for a class of question, look
for a *model-internal* counter whose value is implied by the answer. It is not a weaker substitute
for a kernel counter — it is measured on the opposite side of the failing interface, which can make
it stronger. Also holds in reverse: it is why the earlier `tbchk` payload verdict had to be
discarded (231 XLINE events) while its *grant-progress* integers stayed readable.

**Also recorded:** a `.s` listing next to each ELF, plus an immutable frozen-ELF directory with an
md5 manifest, is what makes "what exactly did I run" answerable. A previous result was destroyed
because the binary was rebuilt between the run and the verification; `md5sum -c` before a run costs
nothing and removes the whole class of problem.


---

## 2026-08-25 ~05:00 +0200 — CORRECTION: there is no "clean corner" for the visibility bug

**Supersedes the "generalisable rule" in the 04:40 entry, which was wrong and has been struck there.**

**The error.** I treated `XLINE: 0` on a 4-core / 1-tile run as evidence that the run was trustworthy
for shared data. It is not. Those are **two different defects**:

- `XLINE` counts **cross-line truncation** (02:20 entry). Zero events means that bug did not fire.
- The **shared-data visibility bug** (03:30 entry) is a separate defect with its own density curve:
  ~~**3 % at 4 cores / 1 tile**, 21 % at 16, 95 % at 64~~ **— THESE NUMBERS ARE WRONG, see the 06:40
  entry.** The real densities are 48 / 69 / 84 / 48 %; there is no low-density corner at all.

So a 4-core run is a *lower-density* corner, never a clean one, and `XLINE: 0` says nothing about it.
Every shared-data conclusion I drew from "clean corner" runs inherits a ~3 % corruption floor.

**Second error, pointed out by the RTL session and worth recording as a general trap:
a deterministic simulator corrupts deterministically.** I read a byte-identical result across two
builds as evidence the code path had not changed. Two identical traces are equally consistent with
"nothing changed" and with "the same corruption happened twice" — **identity does not discriminate**
in a deterministic engine with a known corruption. Compounding it, the binary I tested (mtime
04:27:33) had already been replaced by 04:37:21 by the time I went to verify its contents, so what
it actually contained is now unknowable.

**The decisive argument, from the RTL side.** The TC2 counters are self-contradictory with the report
having been printed at all: `rlc_am_report()` only runs after a 64-core barrier, which consumers only
reach by exiting a loop gated on `rlc_am_idle()` (every queue empty), and `rlc_am_sweeps` increments
before that return. So any printed report implies `completed_sweeps >= 1`, `last_entity = 47`,
`tosend = 0`. We observed `0`, `26`, and `2..10`. **No value of any kernel variable makes those
consistent** — it requires the cross-core reads themselves to be unreliable, which is exactly our bug.

**Consequence: TC2 cannot be diagnosed on this engine at all** until the visibility bug is fixed, at
any core count. Not "with caveats" — the instrument cannot produce a trustworthy reading of
cross-core state. Stopped spending runs on it; the RTL `M48_N1350_K24` control is the path.

**Corrected rule.** While the visibility bug is open, GVSoC cannot answer questions about
**cross-core shared data** at any configuration. `XLINE: 0` clears truncation only. Per-core-private
data (e.g. `cache-stress`, which passes at every scale) remains sound, and so does anything read
from a single core's own writes. That is the real envelope, and it is narrower than what the 04:40
entry claimed.


---

## 2026-08-25 ~04:40 +0200 — technique: use the low-density corner to separate our bug from someone else's

**Situation.** The RTL session correctly challenged a finding I had relayed from a 64-core run,
pointing out that the counters I was reading (`rlc_am_ent[]`, list heads) live in `.data` at
0x8000_xxxx — **below the l1d_addr boundary, therefore shared** — i.e. exactly the class corrupted by
the cross-core visibility bug (03:30 entry). Their control-flow argument was sound: `u0` reporting
`plan_calls=1` while `u30`/`u32` reported 0 could not be explained by any single value of the gate
between them, which is the signature of *partial visibility* rather than a real kernel state.

**Technique that resolved it.** The visibility bug's error density is strongly config-dependent —
3 % at 4 cores / 1 tile, 95 % at 64 cores. So **re-run the same binary in the low-density corner and
check whether the finding survives.** Confirm the corner is genuinely clean first (`XLINE: 0` on the
run, per the 03:30 counters), then read the result.

Outcome: the 64-core dump was indeed contaminated (their challenge was right, and I withdrew it),
but at 4 cores the counters were **self-consistent** — a contiguous attempted prefix, exactly the
coherent shape their argument predicted trustworthy data would have — and the underlying finding
**survived, 7 for 7**: every attempted entity returned an empty peek against a `tosend` of 2-10. A
3 %-density corruption cannot zero out seven of seven uniformly.

**Generalisable rule while the visibility bug is open:** ~~any GVSoC result about shared data is only
trustworthy if it either (a) comes from a low-core-count config with `XLINE: 0` confirmed on that
run, or (b) survives being re-run there.~~ **WRONG — SUPERSEDED, see the 05:00 entry.** This
conflated two different defects: `XLINE: 0` clears the *truncation* bug only. The shared-data
visibility bug is still at ~3 % density at 4 cores / 1 tile, so there is no config that is clean for
it. Do not relay shared-data observations as findings at any core count.

**Also established (for the RTL session, their side):** `M8_N1350_K24` works — grants open and sweeps
complete — at *both* 4 and 64 cores, while `M48_N800_K300` wedges at both. Same code, same
producers/consumers. So their TC2 failure is a function of **entity count**, between 8 and 48, and
is not the AM path, not ownership, and not our simulator.


---

## 2026-08-25 ~03:30 +0200 — cross-core shared-data visibility is broken, and it is NOT a v3 regression

**What.** `cache-test-scalar` / `cache-test-vector` fail on GVSoC with mismatch counts that escalate
with machine size. The test is a pure cross-core write-visibility check: core 0 writes 256 lines,
barrier, every core reads back its own slice.

**The test is entitled to the coherence it assumes** — verified from both sides:
- `basic_buf` is at `0x80003f40`, i.e. cacheable shared DRAM, **below** the `L1D_ADDR` private
  boundary (0xA000_0000);
- neither test calls `l1d_part`, `l1d_xbar_config` or `l1d_addr`, so the reset configuration applies;
- `cachepool_peripheral_reg.hjson`: `L1D_PRIVATE resval = 0` → **zero private banks, all shared**
  (confirmed independently by the RTL session).

In that configuration there is exactly one home bank per address cluster-wide and cross-core
visibility is architecturally guaranteed. So this is a **model defect**.

**Scale (deterministic — 247 reproduced exactly on a repeat run):**

| config | mismatches | checks | density |
|---|---|---|---|
| 4 cores, 1 tile | 247 | 8192 | 3 % |
| 8 cores, 2 tiles | 701 | 8192 | 8.6 % |
| 16 cores, 4 tiles | 1,718 | 8192 | 21 % |
| 64 cores | 3,894 | 4096 | **95 %** |

`cache-stress` PASSes at every scale. Stress is per-core data; basic is shared. **The failure is
specific to shared data.**

**Elimination chain — five hypotheses tested, all refuted:**

| hypothesis | test | result |
|---|---|---|
| cross-line truncation | uncapped XLINE counter | **0 events** → not it |
| per-bank storage corruption | `INSITU_SHADOW=1` (per-bank last-written vs served) | **0 mismatches** while the test reported 247 in the same run → banks are internally consistent |
| address→home routing | `BANKS_PER_TILE` = 1 / 2 / 4 | **identical 247** every time; with one bank there is no routing at all → not it |
| async completion path | `CACHEPOOL_V3_SYNC_CACHE=1` | 240 vs 247 (4c), 1492 vs 1718 (16c) → marginal, not the cause |
| a v3 regression | **v1 (`cachepool`) at 16 cores** | **v1 fails too: 1,266 mismatches** → predates v3 entirely |

**The v1 result is the important one.** This is not something today's work introduced, not the L2
mesh re-anchoring, and not the async conversion. It is present in the long-standing *calibrated*
model, which means **the model has never been validated for cross-core shared-data correctness** —
every kernel in our own regression suite either uses per-core data or is small enough to stay in the
3 %-density corner.

**Retracted:** my earlier "address→home routing gives different homes depending on the requester"
call. It was a reasonable read of the tile/group scaling, but the `BANKS_PER_TILE=1` result refutes
it — `route_request()` takes an address-pure branch when `num_tiles == 1`, and the failure persists
there unchanged.

**Still open — what it actually is.** Remaining candidates, all shared by v1 and v3: the cluster-wide
peripheral barrier's ordering semantics (does it release before prior stores are globally visible?),
a per-core write buffer somewhere upstream of the shared bank, or the ISS store path. The
core-count scaling fits a barrier/ordering story best; the bank-count invariance rules out anything
in bank selection.

**Bearing on the calibration.** The RLC anchor runs 4 cores on one tile — the 3 %-density corner —
so the +14.8 % result is probably lightly affected rather than invalidated. But **no full-core GVSoC
number involving shared data should be trusted until this is understood**, and the RTL session has
been told so, including that the AM `verify_mask=0x80` payload diagnosis may be this rather than the
truncation bug.


---

## 2026-08-25 ~02:45 +0200 — full-core (64-core) survey: GVSoC side established, RTL anchor requested

**Motivation.** User: "can you run more calibration with full cores in use?" — a fair challenge to the
+14.8 % RLC result, which activates only **4 of 64 cores** and is latency-bound pointer chasing.

**Blocking fact: there is no current full-core RTL reference for anything.** The only current anchor
is `reports/rlc_64core_baseline_2026-08-24` (4 active cores). The full-core reports under
`ManyRVData_rebase/reports/` are May-2026, branch `zexin/sync-flush-fixes`, 16-core, and most tests
timed out — useless against today's RTL (multi-group landed later, in `044e768`). **Requested a
64-core batch on `config=cachepool_fpu_4g` from the RTL session; they agreed** and queued it behind
their in-flight payload-correctness runs. So this round establishes the GVSoC side only.

**Occupancy is a property of the PROBLEM SIZE, not the target.** This is the main practical finding
and it invalidates the naive reading of "run at 64 cores":

| kernel | active cores | GVSoC cycles |
|---|---|---|
| `fmatmul-32b_M64_N64_K64` | **16** | 15,571 first / 10,355 steady |
| `fmatmul-32b_M128_N128_K128` | **32** | 65,260 / 55,939 |
| `fmatmul-32b_M1024_N64_K64` | **64** | ~~86,610 / 69,084~~ **RETRACTED, see 07:40** |
| `cache-vector-rw` | **1** | 5,854 |
| `bandwidth` | (random-load, 64 iters x 64 elems) | 29,122 total, 455/load |

So `fmatmul-32b_M1024_N64_K64` is the genuine full-occupancy compute kernel and is the one to
calibrate against; the smaller fmatmul sizes silently use a quarter or half the machine.

**`bandwidth` exists and works.** `insitu_cache_structure_map_2026-08-11b.md` records "a memory-bound
workload at full scale is what would actually test channel bandwidth, and the kernel set does not
contain one". That is **wrong** — `test-cachepool-bandwidth` is exactly that kernel (random-load,
2%o utilisation, 455 cycles/load). It is now the top request in the RTL reference batch, because it
is what would validate the re-anchored L2 refill mesh.

**Failures at 64 cores (GVSoC), none of them the truncation bug:**

| kernel | result |
|---|---|
| `cache-test-scalar` | **FAIL** — `cache-basic: 3894 mismatches`; `cache-stress` PASSes |
| `cache-test-vector` | **FAIL** — `vcache-basic: 3824 mismatches`; `vcache-stress` PASSes |
| `fdotp-32b_M32768` | **Check Failed** (also fails pre-change, see the 02:10 entry) |
| `gemv_M256_N128_K32` | **ABORT**, exitcode -6 (SIGABRT) |
| `byte-enable`, `cache-line-rw-smoke`, `cache-vector-rw` | PASS |

The basic/stress split in both cache-test kernels is suggestive — the stress phase passes while the
basic phase mismatches by ~3900 — but not investigated this round. Not attributable to a
regression on our side either: the CachePoolTests binaries were rebuilt in the RTL tree on
2026-08-24, so no trustworthy pre-rebuild baseline exists for these.

**XLINE contamination check: 0 events on every kernel above.** So the cross-line truncation bug
(02:20 entry) does **not** touch the standard suite — it is specific to unaligned multi-byte
accesses such as the RLC AM payload copy. The cache-test failures are therefore a *separate*
defect, not a symptom of it.

**Cross-session.** Relayed TC2's `steps=1 completed_sweeps=0 last_entity=38/48` (both consumers
wedged inside their first sweep, on entities they own) which ruled out their sweep-cost hypothesis;
they then found a plan-buffer aliasing bug by inspection (`rlc_am_plan_pool` indexed by consumer,
so 24 TC2 entities share one `rlc_plan_t`). They also corrected one of my data points: the wq
build's `last_entity=0` was an uninstrumented counter, not an observation.


---

## 2026-08-25 ~02:20 +0200 — DATA-CORRUPTION BUG FOUND: cross-line accesses are silently TRUNCATED

**Severity: highest defect found so far.** Higher than either ISS gap, because it silently corrupts
data on ordinary unaligned accesses and reports success.

**The bug.** `core/models/cache/insitu/insitu_cache_core.cpp::exchange_line_data()`:

```c
uint32_t off = req->get_addr() & (cache_line_bytes_ - 1);
uint32_t n   = req->get_size();
if (off + n > cache_line_bytes_) {
    ... warn (first 12 only) ...
    n = cache_line_bytes_ - off;      // TRUNCATE -- tail bytes silently DROPPED
}
```

Any access straddling a 64 B line boundary loses its tail. On a **write** the tail never reaches the
cache; on a **read** the requester's buffer keeps stale bytes. `IO_REQ_OK` is returned either way --
there is no error, no retry, and no split into the second line.

**It fires on real code.** The RTL session's RLC AM downlink kernel:

```
[XLINE] cross-line access addr=0x2c0003f size=4 off=63 (line=64) wr -> TRUNCATED
```

`off=63, size=4` -> `n = 64-63 = 1`: **three of every four bytes discarded**. 12 events shown, but
**12 is the warning cap, not the count** -- there is no counter for the real total.

**Why it went unseen for so long.** Three compounding reasons, all worth fixing independently:
1. the warning is capped at 12 events and there is no aggregate counter;
2. it goes to stderr, and the `gvsoc` wrapper **swallows stderr** -- only
   `install/bin/gvsoc_launcher --config=...` shows it;
3. no kernel in our own regression suite issues unaligned multi-byte accesses, so nothing we run
   routinely triggers it.

**Evidence it is the cause of the observed corruption** (RLC AM payload, `verify_mask=0x80`,
headers all correct):
- `first_diff_byte=13`, **not 0**. The RTL session's own discriminator: truncation predicts a
  non-zero first difference at the distance to the next 64 B boundary; a broken unaligned vector
  base would corrupt from byte 0.
- `align_ok=0x3` and `align_bad=0xe` **overlap at destination offset 1** -- the same alignment both
  passes and fails, which argues against a base-address bug and for "depends where this payload
  crosses a line".
- The scalar-byte-copy control (`_scpy`) emits **zero** XLINE events, exactly as predicted: a 1-byte
  access can never satisfy `off + n > 64`.
- Identical `verify_mask` across reference planner / scan-C / vectorised / C=1 -- i.e. independent
  of everything except the shared store path.

**NOT FIXED.** Splitting a straddling access into two line lookups (each of which may independently
hit, miss, or be pending) is a real change to the core FSM, not a one-liner -- raised with the user
as the top defect rather than done unilaterally. **Interim mitigation worth doing regardless:** make
the truncation loud (uncapped counter, reported at `stop()`), since today it is both wrong and
invisible.

**Also found this round (model fidelity, opposite direction).** We implement `vmerge.vvm`; Spatz's
RTL **decodes it and no lane executes it** -- verified independently in
`hardware/deps/spatz/hw/ip/spatz/src/`: `spatz_simd_lane.sv`, `spatz_ipu.sv` and `spatz_vfu.sv`
contain zero references to VMERGE, VMSEQ, VMSGTU, VMSLTU. The lane implements only VADD VAND VMACC
VMADC VMADD VMAX VMAXU VMIN VMINU VMSBC VMUL VMULH VMULHSU VMULHU VOR VSLL VSRA VSRL VSUB VXOR.
So a kernel using `vmerge.vvm` **passes on our simulator and silently corrupts on hardware** -- a
false green. That is a worse class of defect than the missing compares (which fail loudly), and it
is the ISS issue to raise first.

**Cross-session status.** RLC AM now runs end to end on GVSoC once the kernel stopped emitting
`vmsgtu.vx`: `grants=3 pdus=16 published=3 sent=3`, all header fields / SN / SO / continuity
correct, payload-only failure. TC2 (`M48_N800_K300_P2_C2`) runs and terminates (1,275,150 cyc) but
plans almost nothing -- `u47: plan_calls=0` with 48 entities and 2 real consumers, reported to them
as a remaining owner-partition problem. TC2 `P4_C8` still running here; theirs timed out at 5400 s
on RTL.


---

## 2026-08-25 ~01:55 +0200 — MODEL GAP FOUND: the RVV integer-compare family is missing from our timed ISA

**How it surfaced.** Bringing up the RTL session's new RLC AM downlink on GVSoC (see the ~01:15
entry). Their vector planner reported `plan_ok=0` *and* `plan_zero=0` with `plan_calls>0`, which
brackets the failure inside `rlc_plan_compute` — they suspected an infinite loop in their RVV code.
It is not their bug.

**Root cause — ours.** An instruction trace on the stuck core
(`/cachepool_v3_soc/cachepool_v3_cluster/group_0_0/tile_0/pe2`) shows it is not spinning in the
planner at all: it **traps** and lands in snRuntime's default handler `__snrt_isr` at `0x80004ec0`,
which is `jal 0, 0` — a deliberate infinite self-loop. GVSoC's own decoder trace names the cause:

```
pc: 0x80000ba0  Got opcode (opcode: 0x7a82c057)
Unknown instruction
Executing illegal instruction
Raising exception (id: 2)          <- mcause 2, Illegal Instruction
```

Their disassembly maps `0x80000ba0` to **`vmsgtu.vx v0, v8, t0`**.

**Scope of the gap.** `core/models/cpu/iss/isa_gen/isa_rvv_timed.py` (the Spatz/Ara timed path)
defines 238 vector instructions and the **entire vector integer compare family is absent**:
`vmseq`, `vmsne`, `vmsltu`, `vmslt`, `vmsleu`, `vmsle`, `vmsgtu`, `vmsgt`. The mask-logical ops
appear to be missing as well. Present and working: `vmin/vmax/vmul/vmacc/vmadd`, `vmerge.vvm`,
`vmv.*`, and the full reduction set including `vredminu.vs`. So the missing piece is specifically
**the compare that produces a mask into v0** — every other instruction in their idiom exists.

**Consequences worth remembering.** Any RVV kernel using a masked-compare idiom currently dies with
an illegal instruction on this model, and because snRuntime's default ISR is a silent spin loop,
**it presents as a hang, not as a fault**. That is a very expensive failure mode to debug from the
outside: the RTL session spent two rounds hypothesising infinite loops, `vsetvli` returning 0, and
a stack overflow before the trace settled it. If a kernel ever "hangs" on this model, check
`pe*/decoder` for `Unknown instruction` before anything else.

**Method note (reusable).** The `gvsoc` wrapper swallows trace output; `install/bin/gvsoc_launcher
--config=gvsoc_config.json` does not. `grep -a -B 60 -m 1 "<handler symbol>"` on the launcher's
stdout gives the pre-trap instruction window cheaply, and the `pe*/decoder` + `pe*/exception`
trace channels carry the cause code directly — no need to instrument the ISR to read `mcause`.

**Status.** Reported to the RTL session with instructions to stop work on the planner and to check
whether Spatz's *RTL* decoder accepts `vmsgtu.vx` (if it does not, they have a genuine kernel
problem the host test cannot catch, since that compiles the C twins). **Not fixed** — adding
instructions to the simulator's ISA is a scope decision for the user, raised and pending.

**Unaffected:** this is orthogonal to the cache calibration work; no cachepool_v3 kernel in our own
suite uses the compare family.


---

## 2026-08-25 ~01:15 +0200 — RLC AM downlink bring-up on GVSoC (cross-session, RTL agent) + agreed TTI convention

**Context.** The RTL-side session (`ManyRVData_rebase`, branch `dev/rlc-next`) asked this session to
bring up its new RLC **AM downlink** path on GVSoC, because GVSoC iterates ~1000x faster than their
RTL sim. Their tree stayed read-only from here — they rebuilt their own software; nothing was
written into `ManyRVData_rebase` by this session.

**AGREED TTI CONVENTION (use this wording verbatim on both sides so it does not drift):**

> One TTI = one grant opportunity per entity. Primary metric is **bytes/cycle**:
> `(grant_bytes * grants) / kernel_cycles`. Optional wallclock-flavoured figure uses
> **TTI = 5,000 cycles**, a 1:100 scaling of 500 us at 1 GHz.

Rationale: bytes/cycle removes the ~1000x sim-speed gap from the comparison entirely and neither
side needs a TTI loop to produce a comparable number. Defining the TTI in microseconds would force
one side to burn 500k cycles per data point for no extra information.

**Results (64 cores = 2x2 groups x 4 tiles x 4 cores, matching their `cachepool_fpu_4g`).**

Round 1 — all three AM targets ran and terminated but reported `grants=0 pdus=0 segments=0`, so
both of the kernel's self-check lines ("plan vector-vs-reference ... PASS", "transport-block check
... PASS") were **vacuous**. Reported as such rather than as green; they confirmed that was the
right call and it stopped them building on a false positive.

Round 2 — with their counters + a stack fix (640 -> 128 B frame) in:

| target | plan_calls | peek_empty | peek_max | plan_zero | grants | tosend |
|---|---|---|---|---|---|---|
| C2_G8192 | 1 | 0 | 2 | 0 | 0 | 101 |
| C4_G1024 | 1 | 0 | 2 | 0 | 0 | 101 |
| C4_G8192 | 10 | 9 | 1 | 0 | 0 | 101 |

This falls through **all three** of their diagnostic branches (not dispatch — `plan_calls>0` and both
consumer cores printed; not producers — `peek_empty=0`, queue had SDUs; not the planner refusing —
`plan_zero=0`). So the break is between "plan returned non-zero" and "grant opened". Flagged two
leads: `peek_max=2` against `tosend=101` (i.e. `list_peek_n` under-reads a 101-deep queue by ~50x),
and `plan_calls=1` with 101 still queued (i.e. `rlc_am_idle()` goes true before any grant opens).
Their stack fix did not change the outcome, so it is crossed off.

**Anchor protection (our side).** Their rebuild also regenerated the legacy `_M1_N1350_K100`
binary that this session's calibration anchor is measured against. Re-ran it: **149,248 / 149,678 /
195,098 / 195,370 — bit-identical to the pre-rebuild run**, so the 2026-08-25 02:10 calibration
result (fast pair within 0.6 % of RTL) is unaffected. Worth repeating this check whenever they
rebuild, given that the 2026-08-24 rebuild is what silently invalidated the older fdotp baselines.

**Caveat passed to them:** our 2-2 core asymmetry (~149k vs ~195k where their RTL's four cores agree
within 40 cycles) means GVSoC AM cycle numbers are indicative only, and core-to-core spread from
this model must not be read as real until that defect is closed.

**Also learned from them:** the `_P2_C4` targets set `CONSUMER_CORE_NUM=4` while the data header's
consumer list still has only 2 entries, and dispatch follows the list — so C2 and C4 currently run
the *same* core count. No genuine C=1-vs-C>1 contrast exists yet, which is why a concurrency bug
still cannot be separated from a planner/copy bug.


---

## 2026-08-25 ~02:10 +0200 — calibration boundary correction: resp_latency_cycles 8 -> 0 (RLC +60.8 % -> +14.8 %)

**Motivation.** Follow-up to the 00:30 entry: close the +60.8 % gap against the RTL's own 64-core
RLC baseline, which the sweep had shown was dominated by `resp_latency_cycles`.

**Files touched:**
- core: `models/cache/insitu/insitu_cache_core.{cpp,py}`, `models/cache/insitu/insitu_cache_config.py`
  — new `hit_latency_floor` knob (default 0 = off) + `hit_ready_cyc()`.
- pulp: `pulp/cachepool_v3/cachepool_v3_system.py` — `resp_latency_cycles` 8 -> 0.
- parent: `prompt/rtl_multigroup_comparison_2026-08-25.md` §4b.

**Hypothesis tested and REJECTED.** The first theory was that the 8 cycles were double-counted
*inside* the cache core — added at the pipeline tail on top of time already spent queueing in
`in_q_`/stage-0/stage-1/bank conflicts/MSHR. Implemented `hit_latency_floor`: eligibility becomes
`max(now, accept_cyc + floor)` instead of `now + addend`, so prior queueing counts toward the
target rather than adding to it. If the core were the double-counting site this collapses the gap.
It did not — floor=10 gave 215,331/215,623 vs addend=8's 213,587/214,306 (floor 7 -> 192 k,
floor 14 -> 248 k). The core's own arrival-to-completion occupancy is therefore small.

**Actual root cause.** The RTL's 10-cycle warm read-hit is what the **core observes end to end**;
the model's matching 10 was measured at the **cache core's internal boundary**. The model still
spends its own real time in the tile crossbar, AMO shim and remote crossbar on the way in and out
(~8 cycles) — exactly what `resp_latency_cycles` was adding a second time. The earlier
"HIT min = 10, exactly the RTL reference" fit compared the wrong two quantities.

**Change.** `cfg.controller.resp_latency_cycles` 8 -> 0 for cachepool_v3. `miss_extra_cycles` stays
at 5 and still lands right: in-core miss ~ML+8 plus the same ~8 of interconnect ~= ML+16 against
the RTL's ML+17 = 67.

**Verification** (RLC `M1_N1350_K100`, 64 cores, same binary both engines):

| | RTL | before | after |
|---|---|---|---|
| fast pair | 150,175 / 150,183 | 213,587 / 214,306 | **149,248 / 149,678** |
| slow pair | 150,175 / 150,215 | 267,201 / 271,136 | 195,098 / 195,370 |
| mean vs RTL | — | +60.8 % | **+14.8 %** |

Fast pair now within **0.6 %** of RTL. Regression: `cache-line-rw-smoke` PASS on v1 and v3,
`byte-enable` 14/14 PASS on v3. **v1 is unaffected by construction** — it runs the synchronous path
where `resp_latency_cycles` was already 0, and `hit_ready_cyc()` reduces to the old expression when
the floor is disabled (default).

`hit_latency_floor` is kept at 0. It is the more faithful formulation of what a latency reference
means and is free when off, but it is not the fix and needs re-fitting before being enabled.

**Open.** The residual +14.8 % is now dominated by the 2-2 core asymmetry (cores 0,1 ~149 k vs
cores 2,3 ~195 k, where RTL's four agree to within 40 cycles). The fast pair is already at parity,
so closing the asymmetry would bring the mean close to RTL. Suspect: bounded accept queue
(`in_q_cap_`) / `admission_stall_q_` re-admission order.

**Harness note.** These kernels do not reach `stop()` in this harness, so the core's own
`[INSITU-CORE] served_lat_avg / HIT min / MISS min` report could not be captured this round — the
boundary conclusion rests on the end-to-end RLC anchor and the floor A/B, not on a fresh in-core
measurement. Stale `gvsoc_launcher` processes accumulate from such runs; kill with
`pkill -x gvsoc_launcher` (NOT `pkill -f "gvsoc_launcher --config"`, which matches the calling
shell's own command line).


---

## 2026-08-25 ~00:30 +0200 — L2 refill mesh re-anchored to the multi-group RTL; RLC calibration round

**Motivation.** User: "check the rtl design and the latest commits in `ManyRVData_rebase`, here we
have the multi cluster rtl, and you can compare your model against it, and calibrate target on it."
The RTL tree gained multi-group support (`044e768`), a 4×4/2×2 FlooNoc config pair, a NoC profiling
TB with captured logs, and a 64-core RLC baseline — i.e. exactly the anchors that were previously
listed as the calibration blocker.

**RTL surveyed** (read-only): branch `dev/rlc-next` @ `2f51034`.
`config/floonoc_cachepool_{4,16}g.yml`, `config/cachepool_{4g,fpu_16g}.mk`, `config/config.mk`,
`hardware/src/cachepool_pkg.sv`, `hardware/src/cachepool_group_noc_wrapper.sv`,
`hardware/tb/cachepool_noc_profiling.sv`, `hardware/deps/floo_noc/hw/floo_router.sv`,
`noc_profiling/session_0/`, `reports/rlc_64core_baseline_2026-08-24/`,
`reports/amo_lrsc_fix_2026-08-24/FINDINGS.md`.

**Files touched (pulp):**
- `pulp/cachepool_v3/cachepool_v3_cluster.py` — L2 mesh rebuilt; `l2_channel_granule` 256 → 1024.
- `pulp/cachepool_v3/cachepool_v3_system.py` — `l2_size` 0x0100_0000 → 0x2000_0000.

**Files added (parent):**
- `prompt/rtl_multigroup_comparison_2026-08-25.md` — full comparison + calibration report.
- `prompt/insitu_cache_structure_map_2026-08-25.md` — new dated structure map.

**What / why.**
1. **L2 refill mesh was structurally wrong.** The model built a `(nb_x+2)×(nb_y+2)` grid with the
   groups on the interior and `2*(nb_x+nb_y)` = **16** channels around the whole perimeter. The RTL
   builds an `nb_x×nb_y` grid with the group on each node's **Eject** port, and **8** channels
   hanging off the *unused mesh direction* of the edge routers — West of column x=0 (hbm0-3), East
   of column x=max (hbm4-7). North of row 0 / South of row max are tied off. Now modelled as NIs
   with **no router of their own** one column outside the group grid: `floonoc.cpp`'s
   `get_router_neighbour()` returns the NI directly when the neighbour node has no router, so a
   channel costs **zero** extra hops — exactly like RTL's `floo_tcdm_chimney`. (Same pattern as
   `pulp/pulp/chips/magia/soc.py`.)
2. **Channel granule 256 B → 1024 B.** RTL `cachepool_pkg.sv::getDramCTRLInfo` decodes
   `addr[ConstantBits+ScrambleBits-1 : ConstantBits]` with
   `ConstantBits = clog2(L2BankBeWidth * Interleave) = clog2(64*16) = 10` → the channel is
   `addr[12:10]`. `scrambleAddr()` afterwards makes each channel's view contiguous — a pure address
   rewrite with no timing consequence, so the model keeps the flat address.
3. **DRAM 16 MiB → 512 MiB** (`dram_addr 0x8000_0000` / `dram_len 0x2000_0000` from `config.mk`).
   The old 16 MiB window made the ELF loader **reject the RLC binaries outright** (working set at
   0x9900_0000): `Received error during copy (addr: 0x99000000 ...)`. This is what unblocked the
   whole calibration comparison.

**Verification.**
- Generated `gvsoc_config.json` at 4×4 groups dumped and checked: `dim 6 × 4`, **16 routers**
  (group nodes only), 24 NIs (16 groups + 8 channels), 8 mappings, `chan0..3` at x=0 y=0..3 and
  `chan4..7` at x=5, `base=c*0x400 size=0x400 period=0x2000` — i.e. exactly `addr[12:10]`.
- **Per-hop latency measured from the RTL profiling logs** (format decoded from
  `cachepool_noc_profiling.sv`; packets matched by `(addr, write, src_id)`): router **transit**
  min = p50 = **2 cycles** across three independent router/direction pairs; router-output →
  neighbour-input = **0 cycles** (links are combinational). **The model's 2 cyc/hop and
  `router_input_queue_size=2` are confirmed correct against RTL**, not assumed.
- L1 per-controller geometry confirmed identical to RTL (4-way × 256 entry/way × 64 B = 64 KiB,
  `BankFactor=2`, 4 ctrl/tile = 256 KiB/tile).

**Calibration — RLC `M1_N1350_K100`, 64 cores, 4 active cores, same binary both engines:**

| | RTL | model (default) | model @ `resp_lat=0` |
|---|---|---|---|
| fast pair | 150,175 / 150,183 | 213,587 / 214,306 | 149,248 / 149,678 |
| slow pair | 150,175 / 150,215 | 267,201 / 271,136 | 195,098 / 195,370 |
| mean | 150,187 | **+60.8 %** | +14.8 % |
| core spread | **40** | 57,549 | 46,122 |

Ruled out as causes: the **L2 mesh** (mesh on vs off = 0.8 % on this kernel) and the **AMO lane**
(`INSITU_AMO_WINDOW` 0/4/8/18 → *bit-identical* results). The dominant lever is
`resp_latency_cycles`: ≈ **8,100 cycles of runtime per cycle of the constant** on this
latency-bound pointer-chasing kernel, and at 0 the fast pair matches RTL to **0.6 %**.

**Deliberately NOT changed:** `resp_latency_cycles` stays at 8. It is what makes the *isolated* hit
latency come out at the RTL-measured 10 cycles, so lowering it would trade one RTL anchor for
another. The two results together diagnose a **structural** bug: the 8 cycles are additive with
time the closed-loop path already spends (plausibly once per cache core traversed, so a remote
access pays it more than once). The fix is to make it a **floor on total served latency** rather
than a tail addend at `insitu_cache_core.cpp:888`. That is now the top open item.

**Second, independent defect found:** a clean **2-2 core asymmetry** (~46 k cycles) that survives
every `resp_lat` value, where RTL's four cores agree to within 40 cycles. Excluded: the tile
crossbar (`insitu_cache_xbar.cpp`, a pure combinational router with no arbitration) and the
cache core's stage-0 arbiter (arrival-order FIFO). Suspect: the bounded accept queue (`in_q_cap_`)
and `admission_stall_q_` re-admission order.

**Not a regression, but noted:** `fdotp_M32768` fails its internal data check at 256 cores — and
fails identically on the **pre-change** build (stashed + rebuilt to confirm: `Calc 613.09` before
vs `635.41` after, `Exp 628.15`). The CachePoolTests binaries in the RTL tree were rebuilt
2026-08-24, so previously recorded passing numbers were measured against *different binaries* and
should not be trusted as a baseline until re-established.

**Follow-ups:** `prompt/rtl_multigroup_comparison_2026-08-25.md` §6 — the `resp_latency_cycles`
floor fix, the 2-2 asymmetry, the L1 NoC instance count (RTL runs
`NumTilesPerGroup × NumNoCPortsPerTile` parallel meshes + a per-tile 5→x concentration xbar; the
model runs 5), and the `NumLGPortCore` / `NumRemoteGroupPortCore` split (RTL 4g: lg=4, rg=1).

> §"Development log (for weekly reports)". Append on every meaningful
> change and **always** when committing (any submodule or the parent).
> Weekly reports (`prompt/weekly_report_<date>.md`) are assembled from this
> file + `git log`, not from memory.

## 2026-08-11 21:xx +0200 — CORES_PER_TILE=2 multi-group hang: characterised as a BOOT issue, not cache/NoC

**No code change** — diagnosis only, deliberately stopping short of a fix (see the judgement call at
the end).

**It still reproduces** with everything current (tunnel routing, P3, P4): 2x2 groups x 1 tile x **2**
cores hangs on byte-enable, which passes at 4 cores/tile.

**It is not frozen — it is a software spin.** 110.9M instructions retired and simulated time reaching
110.9M cycles in a 200 s window, so the engine is fine.

**Where the cores are: PC 0x1038, forever.** From `bootrom_cachepool.dump` that is the bootrom's
`<exception>` handler:

```
00001038 <exception>:
    1038:  wfi
    103c:  j 1038 <exception>
```

And **zero runtime peripheral accesses** — all 72 traced peripheral events are elaboration-time. So the
cores never read BOOT_CONTROL, never reach the barrier, and never leave the ROM.

**Why that is a trap, not the boot WFI.** The bootrom's sequence is:

```
1004: lw t1,120(t1)      # mtvec <- 0x1038
1008: csrw mtvec,t1
1018: csrwi mie,15       # enable MSIP
101c: wfi                # wait for the wake
1020..102c:              # then compute cluster_base + size + 0x20  (BOOT_CONTROL)
1030: lw t2,0(t2)        # read the entry point
1034: jr t2              # and jump to it
```

`mtvec` is 0x1038, so an interrupt that is **taken** vectors to the exception handler instead of the
core resuming after the `wfi`. The intended behaviour is the opposite: with `mstatus.MIE` clear, a
pending MSIP wakes WFI *without* being taken, and execution continues at 0x1020. Our cores are parked
at 0x1038, so at this configuration the MSIP is being taken as a trap.

Note 0x1038 is also the ROM's default `entry_addr` (0x1070 holds 0x1038), so "jumped to the default
entry" and "trapped" land in the same place — but the absence of ANY peripheral access rules out the
former: a core that reached 0x1030 would have read BOOT_CONTROL through the peripheral.

**So the fault is in boot / interrupt delivery at this core count, not in the cache, the crossbars or
either NoC.** That is the useful conclusion, because it says where NOT to look.

**Next step if it is ever wanted:** compare MSIP delivery between 2 and 4 cores per tile — whether the
wake is a level that stays asserted (so a second interrupt is taken after the first wake) versus a
pulse, and what `mstatus.MIE` is at the wake. The v3 loader drives one `o_START` into every core's
`msip` port, so a level/pulse mismatch would plausibly behave differently as the fan-out width changes.

**Judgement call: stopping here.** This is a degenerate, non-target configuration — CLAUDE.md already
records `CORES_PER_TILE>=2` as marginal, every target config uses 4, and all 8 kernels pass at 4 cores
per tile up to 256 cores. Spending further time here would buy a configuration nobody runs, while the
genuinely blocking item (RTL anchors) sits untouched. Recorded as characterised-not-fixed rather than
quietly dropped.

## 2026-08-11 20:xx +0200 — #34 step 4: the miss side calibrated against the RTL, per class

**Commits:** core `c492974c` "insitu: calibrate the miss side against the RTL, measured per class" ·
pulp `454a474` "cachepool v3: adopt the calibrated miss-side term"

**Measure per class before adding a knob.** A hit and a miss cannot share one response-latency
constant, so the core now reports served latency separately for hits and for accesses that waited on a
refill, with the **minimum** as well as the mean — the RTL figures are ISOLATED costs, and a mean
overstates them once several accesses queue behind one refill. On byte-enable at 1 group x 4 tiles x 4
cores:

| class | measured (min / mean) | RTL reference | verdict |
|---|---|---|---|
| HIT | **10** / 10.2 | 10 isolated (7 streaming) | **already exact** |
| MISS | **62** / 64.2 | MemLatency + 17 = **67** | 5 cycles short |

The hit side needed nothing, which **independently confirms `resp_latency_cycles = 8`** — the earlier
blended average of 10.76 could not distinguish hit from miss, so that agreement was weaker evidence
than it looked.

**Sweep of the new `miss_extra_cycles`** (via `INSITU_MISS_EXTRA`): 4 -> min miss 66, **5 -> 67**,
6 -> 68, with min hit unchanged at 10 throughout — so the two sides are genuinely independent. Default
5, and 0 whenever `inline_sync_miss`. Implementation: `resp_done_cyc_` now holds each entry's READY
cycle rather than its completion cycle, so hit and miss carry different delays through one queue.

**Kernel effect** (1 group x 4 tiles x 4 cores, all data-correct): fdotp_M8192 31,719 -> 32,183,
load-store_M16 155,109 -> 157,664, byte-enable 257,586 -> 257,731, spin-lock 73,799 -> 73,824.
v1 cachepool 16-core exact on all four reference kernels (49,001 / 154,001 / 225,001 / 76,628).

**What changed about the basis of the calibration — this matters more than the numbers.** The isolated
hit and miss costs are now anchored to **the RTL's own figures** rather than to the synchronous path.
Against sync the deltas are now fdotp +3.4%, byte-enable +1.9%, spin-lock -3.9%, load-store -9.4%, and
some of those moved slightly further from sync while moving ONTO the RTL reference. That is the right
trade: the sync path is itself only partly RTL-calibrated (v1's load-store over-predicts RTL by 52%),
so matching it was never the goal.

**#34 remaining on my side:** the L1/L2 NoC hop costs, the 256 B channel granularity and the L2 I$
geometry are still placeholders with no reference; and `xbar_latency_cycles` / `hop_latency_cycles`
(both 1) are live on the sync path but dead on async, needing a structural equivalent rather than
deletion. **Blocked on the user:** RTL anchors for a v3-comparable configuration — without them the
placeholders above cannot be resolved at all.

## 2026-08-11 19:xx +0200 — calibration refresh caught a sync-path regression I had introduced in P3

**Commit:** pulp `585817a` "cachepool v3: keep the synchronous path flat — the refill mux and L2 mesh
are async-only"

**The regression.** The 17->1 refill mux always answers `IO_REQ_PENDING`, but the synchronous-slave
cache requires its refill to answer **OK inside the same call**: `inline_sync_miss` completes the miss
there and returns OK to the core. With a queueing arbiter in that path the sync arm died — the ISS
aborted with **"Trying to decrease zero stalled counter"** on fdotp, and byte-enable failed on an
invalid peripheral register. The P4 mesh has the same incompatibility. **Neither had been re-run in sync
mode since P3 landed**, so this sat undetected through two phases.

This is the payoff for re-measuring stale numbers rather than just restating them: the task found a bug
instead of refreshing figures.

**The fix.** The synchronous path exists as a CALIBRATION REFERENCE, so it keeps the flat per-group
fan-in it was measured with; the mux and mesh are gated on the cache being asynchronous. The group L2 I$
is deliberately **not** gated that way — it is independent of the sync/async choice, so it stays in both
arms and its refill joins the 17->1 mux when one exists or leaves on the group egress otherwise. That
keeps the A/B a comparison of the CACHE, differing only by arbitration, rather than by a whole cache
level.

**Refreshed async-vs-sync** at 1 group x 4 tiles x 4 cores (L2 I$ in both arms, write-through off).
These REPLACE the figures in the #34 entries, which predated P3:

| kernel | sync | async | delta | stale figure |
|---|---|---|---|---|
| fdotp_M8192 | 31,125 | 31,719 | **+1.9%** | +1.1% |
| byte-enable | 253,039 | 257,586 | **+1.8%** | +0.9% |
| spin-lock | 76,826 | 73,799 | **-3.9%** | -2.3% |
| load-store_M16 | 174,116 | 155,109 | **-10.9%** | -8.8% |

Conclusions unchanged: hit-dominated kernels within ~2%, and load-store's gap is the memory-level
-parallelism difference already recorded as a deliberate non-goal. Async is unperturbed by the
restructure — every async number is bit-identical to before it, and 2x2 with the mesh is still 38,640.
The 2x2 sync arm runs again (36,835).

**Two notes on my own method:**
- My first measurement script captured `$?` **after** a `grep`, so it printed `rc=0` for runs that had
  actually aborted, with only the missing cycle count as a hint. Capture the status immediately.
- `xbar_latency_cycles` and `hop_latency_cycles` are both **1**, not 0, so removing them is NOT a
  no-op cleanup: they are live and calibrated on the synchronous path (v1 depends on them) and dead
  only on the async path. Deleting them would break v1's calibration. The correct action is a
  structural equivalent for async, which is a real change needing its own A/B — not a tidy-up.

## 2026-08-11 18:xx +0200 — verification debt: v2 discharged by inspection; 256-core mesh sweep running

**No code change** — verification round.

### v2 regression: discharged by inspection, not by a run

I changed two files that `cachepool_v2` shares. The diff against the last v2-era commit
(`git diff 7c8e758..HEAD -- pulp/floonoc/`) is 32 lines, and the **only functional change** is:

```python
-            rm_base: bool=False, remove_offset:int =0):
+            rm_base: bool=False, remove_offset:int =0, period: int =0):
-        self.__add_mapping(f"wide_{name}", ..., remove_offset=remove_offset)
+        self.__add_mapping(f"wide_{name}", ..., remove_offset=remove_offset, period=period)
```

`o_WIDE_MAP` now passes `period=0` explicitly where `__add_mapping`'s own default was already 0, so it
is **behaviourally identical for every existing caller**. Everything else in the diff is `getenv`-gated
debug printing (`FLOONOC_NI_DEBUG`), inert when unset, plus one `#include <cstdlib>`. The speculative
`fsm_event.enqueue()` on the DENIED path was reverted earlier precisely so this argument would hold.

I did try `cachepool_v2` at 2x2 groups x 1 tile x 4 cores and it timed out — but that is **not**
evidence of a regression: small-mesh v2 configurations were already known not to run (the 2x1 case
deadlocks in v2 as well), and my changes cannot alter v2's behaviour by the argument above. Running v2
at its proven 4x4x4x4 default would cost hours of wall time to re-confirm something the diff already
settles, so it is recorded here as **discharged by inspection** rather than left as a vague open item.
If a v2 number is ever needed, the configuration to use is its default, not a reduced mesh.

### 256-core sweep with the mesh: running

**8/8 KERNELS PASS AT 256 CORES ON THE COMPLETE STRUCTURE** — 4x4 groups x 4 tiles x 4 cores, both NoC
levels, the group hub, 16 memory channels. All data-correct, all retval 0:

| kernel | cycles | verdict |
|---|---|---|
| `fdotp_M32768` | 64,501 | prints `(32768)`, 24% util |
| `fdotp_M65536` | **73,226** | prints `(65536)`, **43% util** |
| `load-store_M16` | 200,130 | **7/7** partition + flush |
| `byte-enable` | **365,578** | |
| `cache-vector-rw` | **619,231** | |
| `spin-lock` | **2,304,515** | 256-way atomic contention |
| `cache-test-vector` | **2,691,387** | vcache-basic + vcache-stress integrity OK |
| `cache-test-scalar` | **2,963,000** | cache-basic + cache-stress integrity OK |

This is the new reference point for the model: every structural element of the architecture running
together at full scale, data-correct.

**Do NOT compare these against the pre-mesh 256-core sweep.** Three things changed at once between the
two — the group L2 I$ landed (P3), functional write-through went off, and the L2 mesh went on — so the
per-kernel differences (e.g. byte-enable 635,594 -> 365,578, cache-test-scalar 2,698,989 -> 2,963,000)
are not attributable to any one of them. The only clean mesh A/B is the write-through-off pair in the
entry above.

fdotp utilisation improves 24% -> 43% from M32768 to M65536 at 256 cores, consistent with the earlier
finding that the low figure is elements-per-core rather than a model limit.

## 2026-08-11 17:1x +0200 — P4 verified at 4x4 / 64 cores with the design's 16 memory channels

**No code change** — measurement round (worklog + parent pointer only).

**16 memory channels, exactly as designed.** At 4x4 groups the mesh is 6x6 and the boundary ring minus
corners gives **2*(4+4) = 16** channel attach points; the elaborated config confirms 16 `chan_ico`
routers. This is the configuration the architecture discussion specified ("for a 4x4 NoC there are 16
outbound router ports at the edge, so at most 16 memory channels").

**Clean A/B at 4x4 / 64 cores** (write-through off in BOTH arms, so the comparison is not confounded):

| kernel | mesh OFF | mesh ON | delta |
|---|---|---|---|
| fdotp_M32768 | 48,008 | **51,923** | **+8.2%** |
| load-store_M16 | — | **173,253** (data-correct) | — |

**Correction to my first reading of this:** I initially compared the mesh-on number against the 63,555
recorded earlier and reported it as 18% FASTER. That baseline was taken with functional write-through
ON, so it was not comparable. Re-measured with both arms at write-through off, the mesh costs **+8.2%**,
which is the direction one expects.

**The channel count shows up in the cost, which is the encouraging part:** the mesh penalty is
**+21.8% at 2x2** (8 channels) and **+8.2% at 4x4** (16 channels). Twice the perimeter, twice the
parallel paths to memory, roughly a third of the penalty — the mesh scales the way the design intends
rather than becoming a bottleneck as groups are added.

**256-CORE GATE PASSES WITH THE COMPLETE STRUCTURE.** 4x4 groups x 4 tiles x 4 cores = 256 cores, 64
tiles, 256 banks, both NoC levels, the group hub (4->1 icache mux + L2 I$ + 17->1 refill mux), and 16
memory channels on the 6x6 mesh perimeter:

| kernel | cycles | verdict |
|---|---|---|
| `fdotp_M32768` | **64,501** | retval 0, prints `(32768)`, 24% utilisation |
| `load-store_M16` | **200,130** | **7/7** partition + flush, `Cores:256 Tiles:64` |

So the whole designed topology runs at full scale and stays data-correct — every structural element of
the architecture is now exercised together at 256 cores.

**Clean A/B, both arms write-through off** (the earlier 256-core numbers — fdotp 77,493, load-store
323,879 — were taken with write-through ON and are NOT comparable):

| kernel | config | mesh off | mesh on | delta |
|---|---|---|---|---|
| fdotp_M32768 | 2x2 (8 chan) | 31,736 | 38,640 | +21.8% |
| fdotp_M32768 | 4x4 / 64c (16 chan) | 48,008 | 51,923 | +8.2% |
| fdotp_M32768 | 256c (16 chan) | 61,761 | 64,501 | **+4.4%** |
| load-store_M16 | 2x2 (8 chan) | 159,432 | 163,799 | +2.7% |
| load-store_M16 | 256c (16 chan) | 185,740 | 200,130 | **+7.7%** |

**What this does and does not show.** The mesh costs single digits to low double digits and, importantly,
**does not blow up at 256 cores** — the two-level NoC is not becoming the bottleneck as groups are
added. But the per-kernel trends run in OPPOSITE directions (fdotp 21.8 -> 8.2 -> 4.4%, load-store
2.7 -> 7.7%), so this is not yet evidence of clean bandwidth scaling. fdotp's shrinking share is partly
because it is **not memory-bound** at 256 cores: M32768 over 256 cores is 128 elements per core and only
24% utilisation, so the refill path is a smaller fraction of the runtime. A genuinely memory-bound
workload at full scale is what would actually test the mesh's channel bandwidth, and we do not have one
in the current kernel set.

Also worth stating plainly: with the mesh on, the L1-NoC and L2-NoC hop costs, the channel granularity
(256 B) and the L2 I$ geometry are all **uncalibrated placeholders**. The structure is right; the
magnitudes are not anchored to RTL.

## 2026-08-11 16:2x +0200 — P4 WORKS: the L2 refill mesh is live; the stall was the functional write-through

**Commits:** core `e9b80da7` "insitu: treat a DENIED writeback as in flight" ·
pulp `7770039` "cachepool v3: L2 refill mesh ON by default; functional write-through OFF"

**The stall was never the mesh.** `functional_write_mem` mirrors every write hit straight to L2 using
**one shared request object**, fire-and-forget with the status **ignored**
(`(void)evict_itf_.req(&funcwr_req_)`). That is safe only while the downstream answers OK inside the
call. Once anything in the path can queue — the P3 refill mux, then the P4 mesh — the slave takes
ownership of that object while the next write reuses it, so the network interface accumulates **phantom
outstanding bursts**: 32 at one NI, where the cache can only have about **five** genuinely in flight per
group (one refill per bank plus the L2 I$). At cycle 21,105 the count sat at the 32 cap with the slot
pointer free, nothing left to decrement it, and the denied request never drained.

Proven by a config-only A/B: mesh ON + write-through OFF completes immediately.

**How the diagnosis went, including the wrong turns** — worth recording because three hypotheses failed
before the right one:
1. *Missing `fsm_event.enqueue()` on FlooNoc's DENIED path.* Plausible (the drain lives in
   fsm_handler), implemented, **changed nothing** — same stall cycle. Reverted rather than left in a
   model v2 shares.
2. *Eviction mishandling DENIED.* Real bug, found and fixed (`e9b80da7`) — the drain marked the
   writeback in flight only on PENDING, so a DENIED re-issued the same `evict_req_` next tick. But the
   run was **bit-identical** with and without the fix, so eviction never actually got DENIED here. Kept
   anyway: it is the same latent defect one line over.
3. Only then did the counter instrumentation show the repeated same-pointer WRITE submissions, which
   pointed at the one remaining shared write object: `funcwr_req_`.

The lesson generalises: **any single shared request object submitted fire-and-forget is a time bomb
that only goes off when something downstream starts queueing.** That is now three of them found this
session — the flush writeback loop, the eviction queue, and this one.

**Results with the new defaults** (mesh ON, write-through OFF), 2x2 groups x 1 tile x 4 cores, all
data-correct:

| kernel | mesh ON | flat per-group path | delta |
|---|---|---|---|
| fdotp_M8192 | **38,640** | 31,736 | **+21.8%** |
| load-store_M16 | **163,799** (7/7 partition + flush) | 159,432 | +2.7% |
| byte-enable | **294,633** | 257,573 | +14.4% |

The +21.8% is the *point* of P4: refills now cross a shared mesh to a memory channel on the perimeter
instead of every group having its own private full-bandwidth router straight to memory. Dropping the
write-through costs nothing by itself (mesh off: fdotp 31,719, load-store 155,109, byte-enable 257,586).

**P4 status: the structure of the design is now complete** — two NoC levels, the group hub (4->1 icache
mux, L2 I$, 17->1 refill mux with instruction priority), and memory channels on the mesh perimeter.

**Next:** re-verify at 4x4 / 64 cores and then the 256-core gate with the mesh on, since every number
in the P3 and calibration entries predates it. Expect the 256-core runs to be slow — the mesh adds 48
routers per plane-set and every refill now takes a multi-hop round trip.

## 2026-08-11 14:4x +0200 — P4 started: L2 refill mesh scaffolding in, traffic not flowing yet (default OFF)

**Commit:** pulp `b658f2c` "cachepool v3: L2 refill mesh scaffolding (P4, WIP — default OFF, currently
hangs)"

**Honest status: P4 is NOT working.** The structure elaborates exactly as designed but traffic does not
get through, so `CACHEPOOL_V3_L2_NOC` defaults to **0** and the working per-group flat path stays in
use. Committed as scaffolding because the elaboration and the two findings below are worth keeping;
P3's numbers are unchanged with it off (fdotp_M8192 31,736, load-store_M16 159,432).

**What is built.** A second FlooNoc level, mesh = (nb_x+2) x (nb_y+2), groups on the interior nodes and
**memory channels on the boundary ring minus its four corners** — 2*(nb_x+nb_y) attach points, exactly
**16 for a 4x4 group grid**, one per outbound edge port as specified. Confirmed in elaboration at 2x2:
channels at (1,0) (1,3) (2,0) (2,3) (0,1) (3,1) (0,2) (3,2), group NIs at the four interior nodes. Each
channel has its own SoC-side router carrying the existing l2/pdcp/soc decode, so the mesh only has to
pick a channel.

The channel map interleaves across the **whole** address space (base = c*granule, size = granule,
period = n_channels*granule, 256 B granule). Full coverage is not optional — FlooNoc drops an unmatched
burst silently — and the 256 B granule keeps a 64 B line from straddling two channels. Unlike the L1
mesh this static map is legitimately correct: DRAM channel interleaving is fixed hardware, not the
runtime-programmable XBAR_OFFSET.

**Two things learned wiring it:**
1. `o_WIDE_MAP` had no `period` (only `o_NARROW_MAP` did). Added, additive with default 0.
2. **Both mesh widths must be real.** FlooNoc puts only wide WRITE DATA on the wide plane; every
   request/address — including a refill READ — rides the narrow "req" network
   (`!is_write || !is_wide -> req_queue`, floonoc_network_interface.cpp:415). Setting `narrow_width=0`
   because "this is the wide plane" starved every refill read on a zero-width queue. This is worth
   remembering generally: the narrow plane is the address channel, not "the other traffic".

**RETRACTED — two claims in the first version of this entry were wrong:**
- *"a refill never reaches the routers / dies inside `enqueue_router_req`"* — that came from a run whose
  config I had regenerated **without** `--trace`, so the absence of router messages proved nothing. I
  made the same mistake twice more in this round; the config must be regenerated WITH the trace flag
  every time, and `rm -f gvsoc_config.json` before an untraced run silently discards it.
- *"currently hangs"* — `rc=124` was my own 400 s timeout, not a stall.

**What is actually true: the round trip WORKS.** With tracing genuinely enabled, at 2x2 groups: the
group NI (1,1) injects a wide read; `req_router_1_1` resolves dest (1,0) and forwards it (X-first, and
the (2,2) case correctly steps to (1,2)); channel NI (1,0) receives it and sends it to its target; the
read **response rides the WIDE plane** back (`wide_router_1_0` -> `wide_router_1_1`); the requesting NI
logs "Received response from router" then "Finished burst". Successive refills flow — 0x1000,
0x800034c0, 0x80003840 — with ~60-cycle round trips, and **216 write bursts** complete too, so
evictions work as well.

**But the run stalls at cycle ~21,105**, reproducibly: two runs with very different trace loads (heavy
l2_noc vs light peripheral) both stop at 21,105 / 21,111, which rules out "just slow". fdotp needs
31,736 cycles with the mesh off, so it dies about two thirds of the way in.

**The stall signature.** At 21,087 a burst finishes normally at `ni_2_1`. At **21,105** `ni_2_2` logs
"Received request from target (base: 0x80003e00)" and then **nothing** — no "Received wide burst from
initiator", no "Handling addr burst". That is the DENIED branch of `NetworkInterface::handle_req`:

```cpp
if (*queue || nb_pending_bursts[is_wide] >= ni_outstanding_reqs) { denied_queue->push(req); return IO_REQ_DENIED; }
```

So the NI's pending-burst slot for that class is still occupied, the request goes on the denied queue,
and nothing ever frees the slot to retry it. Since 216 writes and many reads did complete, the
accounting works in general — something about this particular burst (or the state around it) leaves the
per-class slot held.

**ROOT CAUSE FOUND: duplicate submission inflates the NI's outstanding-burst count.** Instrumented
with the new `FLOONOC_NI_DEBUG` (pulp, env-gated, inert when unset), which prints every admission
decision with the slot state and every completion decrement.

At the stalling interface: **333 admissions against 335 decrements**, and the count oscillating
**31<->32** rather than climbing — so not a simple leak. The mechanism is visible in the trace: the
**same request pointer** is admitted and DENIED on consecutive cycles (`0x29324e8` at 20835, 20836,
20837), so it lands on the denied queue repeatedly, and **every later drain does
`nb_pending_bursts[1]++`**. The count therefore inflates to the 32-burst cap even though the cache can
only have about **five** bursts genuinely in flight per group (one refill per bank plus the L2 I$). At
21,105 the count sits at the cap with the slot pointer FREE (`held=(nil)`), no further responses arrive
to decrement it, and the denied request is never drained. Deadlock.

**Next step:** honour FlooNoc's DENIED/grant contract on the initiator side. A master that receives
`IO_REQ_DENIED` must hold the request and wait for `grant()` — the NI calls
`req->get_resp_port()->grant(req)` when it drains its denied queue — rather than letting it be
re-driven. So: find who re-submits the same pointer each cycle (the refill mux forwards with
`req_forward` and does not retry, so the re-drive is upstream of it or inside the NI's own retry path),
and make that path wait for the grant. Sizing is a second question: one NI per group with a single
pending burst per class serialises a group's entire refill stream, so if that is not the intended
bandwidth the design wants several NIs per group.

**Also reverted:** a speculative `fsm_event.enqueue()` on the DENIED path. It changed nothing (the
stall stayed at the same cycle) and this model is shared with cachepool_v2 at 256 cores, so an
unmotivated edit does not belong there.

## 2026-08-11 13:5x +0200 — P3 COMPLETE: group L2 I$ + instruction strict priority

**Commits:** core `5fe51029` "insitu: config knobs for the group L2 instruction cache" ·
pulp `1f853c2` "cachepool v3: group L2 instruction cache + instruction priority (P3 complete)"

**What landed.** The L1 I$ refill now leaves each tile on its own port instead of riding the tile AXI.
The group aggregates the four of them round-robin through a 4->1 `InsituCacheRefillMux` into a
**group-level L2 instruction cache** (`Cache`, the same model `Hierarchical_cache` already uses for the
L1 I$; 8 KiB / 4-way / 64 B line by default), and that cache's refill is **input 16** of the wide mux
with `nb_priority_inputs=1` — instruction refills win over all 16 bank ports, as specified. P3 is now
complete: 4->1 icache demux, group L2 I$, and the 17->1 refill mux with instruction strict priority,
data round-robin, and a requester id.

**The instruction path measurably does its job.** On fdotp_M8192 the four tiles send **599** L1 I$
refills into the group, of which only **106** miss the L2 I$ and continue to memory — an **82% hit
rate**. Those 493 absorbed refills no longer make a 50-cycle trip to memory, which is the whole
speedup. Verified by A/B (`CACHEPOOL_V3_L2_ICACHE`): 47,808 with the old tile-AXI path, 31,736 with the
L2 I$. I checked this rather than assuming, because a 33% gain from adding a structure is exactly the
shape of a discarded cost — this time it is a real cache doing real work.

**Results** (1 group x 4 tiles x 4 cores, all data-correct):

| kernel | P3 data half | P3 complete |
|---|---|---|
| fdotp_M8192 | 47,808 | **31,736** |
| byte-enable | 531,214 | **257,573** |
| load-store_M16 | 180,209 | **159,432** (7/7 partition + flush) |
| spin-lock | 122,970 | **73,712** |
| cache-test-vector | 1,970,712 | 1,976,488 (compute-bound — unchanged, as expected) |

v1 cachepool 16-core untouched: load-store_M16 154,001, byte-enable 225,001.

**Caveat, and it is a big one for anyone quoting these numbers.** The L2 I$ is structurally right but
**not calibrated**: instantiated with `refill_latency=0`, its hit cost is whatever `cache.cpp` models,
and the geometry (8 KiB, 4-way) is a placeholder until there is an RTL reference for the group
instruction cache. The 4->1 mux does serialize instruction refills at one per cycle, but the L2 I$
itself models no port contention. So the direction of every number above is right — an L2 I$ removes
fetch misses — while the magnitude is not anchored. `CACHEPOOL_V3_L2_ICACHE=0` restores the previous
path for A/B.

Note also that this invalidates the #34 calibration deltas: those were measured against the
synchronous path with instruction refills going to memory. The async-vs-sync comparison has to be
redone now that both paths would have an L2 I$ (the flag is on the shared cache config, so the
synchronous path gets it too).

**Next:** **P4** — the L2 refill mesh and the memory channels at the perimeter. The group's wide mux
output is already the single point that P4 attaches to, which is what P3 was for.

## 2026-08-11 13:0x +0200 — P3 data half: group refill arbiter + per-bank wide egress

**Commits:** core `21e38504` "insitu: group refill mux (v3-P3, data half) + per-bank wide egress" ·
pulp `961d529` "cachepool v3: per-bank refill ports into a group-level arbiter (P3, data half)"

**What landed.** `InsituCacheRefillMux`: N wide refill masters share one downstream port, instruction
inputs (the last `nb_priority_inputs`) take **strict priority**, data inputs are served
**round-robin**, **one request per cycle**, and `set_initiator` stamps the winning input as the
requester id (the RTL's user field). `per_bank_l2_ports` makes the banks leave their tile on separate
wide ports so the group can arbitrate all of them — a bare fan-in is not a shared resource at all,
just a name several masters bind to. v3 now wires 16 bank ports (4 tiles x 4 banks) into one group
arbiter. The instruction port becomes input 16 when the group L2 I$ lands.

**Two latent bugs the mux exposed**, both the same kind — a cost or hazard that only appears once
something in the path can answer PENDING:

1. **The mux must spend the DOWNSTREAM latency as real time.** Memory answers a refill with
   `IO_REQ_OK` + an `inc_latency()` stamp, and the cache core converts that stamp into a deferred
   install only on its own OK path. Responding in the same cycle threw ~50 cycles away — kernels got
   **faster** when arbitration was added (fdotp 47,711 -> 43,781) and load-store's data broke. Matured
   responses now come out of a delay queue. Fourth instance this session of "a stamp had to become
   real time".
2. **`run_flush()` reused one request object and one data buffer for every dirty line.** Safe only
   while the downstream completes inside the call — as the comment there already said. With the mux
   queueing them, all of a flush's writebacks shared one in-flight object and carried the last line's
   bytes; load-store failed 3 checks. Flush writebacks now go through the same eviction queue as
   ordinary evictions, each with its own snapshot, no depth check (a flush must be able to queue every
   dirty line).

Note the diagnosis order here: I first suspected the functional write-through (also a single shared
request fired fire-and-forget) and tested it by switching it off — **still 3 FAILs**, so that
hypothesis was wrong and the flush loop was the real one. Worth recording, because both look identical
from the outside.

**Results** (1 group x 4 tiles x 4 cores, all data-correct):

| kernel | pre-mux | with 16-way arbiter |
|---|---|---|
| load-store_M16 | 178,448 | 180,209 (7/7 partition + flush) |
| fdotp_M8192 | 47,711 | 47,808 |
| byte-enable | 531,159 | 531,214 |
| spin-lock | 122,958 | 122,970 |
| cache-test-vector | 1,975,357 | 1,970,712 |

Arbitration is real but modest at this scale — the group arbiter forwarded **1.07M** requests with a
peak queue of **130** on the vector kernel, so the port is busy without being the binding constraint.
v1 cachepool 16-core exact on all four reference kernels including the flush-heavy load-store_M16
(154,001 / 49,001 / 225,001 / 76,628), which is the check that matters since the flush path is shared.

**Still open for P3 (instruction half):** the 4->1 aggregation of the tiles' L1 I$ refills, the
group-level **L2 instruction cache**, and wiring its refill as input 16 with `nb_priority_inputs=1`.
The arbiter already supports it; what is missing is the L2 I$ itself and the tile-side icache egress
(today the L1 I$ refill still rides the tile AXI).

## 2026-08-11 12:1x +0200 — 256-CORE GATE PASSES: the full target configuration runs

**No code change** — this entry records the scale gate (worklog + parent pointer only).

**The full design target now runs**: 4x4 groups x 4 tiles x 4 cores = **256 cores**, 64 tiles, 256
InSitu banks, 5 L1 FlooNoc meshes, a 6.2 MB elaborated config. It passed on the first attempt, with no
new bugs — which is worth noting after a session where every previous scale step (16 -> 32 -> 64 cores)
surfaced a real defect that was invisible one step down.

| kernel | result | cycles |
|---|---|---|
| `fdotp_M32768` | **PASS** `----- (32768) sp fdotp -----`, retval 0 | 77,493 |
| `load-store_M16` | **PASS**, 7/7 partition + flush, `Cores:256 Tiles:64` | 323,879 |
| `spin-lock` | **PASS**, retval 0 | 3,020,539 |
| `byte-enable` | **PASS**, retval 0 | 635,594 |

| `cache-test-vector` | **PASS**, vcache-basic + vcache-stress data integrity OK | 2,948,376 |
| `cache-test-scalar` | **PASS**, cache-basic + cache-stress data integrity OK | 2,698,989 |
| `cache-vector-rw` | **PASS**, retval 0 | 610,257 |
| `fdotp_M65536` | **PASS** `----- (65536) sp fdotp -----`, 48% utilisation | 86,541 |

**8 of 8 kernels pass.** One caveat on the two cache-test kernels: they cap their verification at
`MAX_CORES = 32` (`[WARN] only first 32 cores checked`), so their data-integrity verdict at this scale
covers 32 of the 256 cores. Cores 32+ run the traffic but are not checked — the same limit that mattered
while diagnosing #36.

**Utilisation recovers with problem size, as predicted.** fdotp goes 31% at M32768 (128 elements per
core) to **48% at M65536** (256 per core), confirming the low figure was the workload rather than the
model. Still not saturating; a larger problem would push it further.

**What each of those actually proves at this scale:**
- The **256-way barrier** works — the counting barrier from the earlier 64-bit rewrite holds at 256,
  where the original 32-bit bitmask could not even represent the participants.
- **Partitioning and flush** work across 64 tiles: all seven cases, including both flush-isolation
  phases, with the kernel itself reporting `Cores:256 Tiles:64`.
- **256-way atomic contention completes.** spin-lock at 3.02M cycles is ~11.8k cycles per core
  serialised through one lock, which is the expected shape. Before the #35 fix (structural AMO lane
  occupancy) this kernel could not finish even at 16 cores.
- Cross-group traffic over the L1 mesh works at 16 groups with the runtime-programmable interleaving
  (fdotp sets XBAR_OFFSET itself).

**Read the fdotp utilisation carefully:** 31% at 256 cores against 87% at 64. That is the WORKLOAD, not
the model — M32768 over 256 cores is only 128 elements per core, so there is not enough work to fill
the machine. fdotp_M65536 is running to confirm utilisation recovers with a problem size that fits the
core count.

**Numbers here are with the intended n = 1 remote ports per port-class crossbar** (five per tile) and
the async cache calibrated per #34 steps 1-3. They are internally consistent but still not anchored to
RTL for this topology.

**Next**, now that the foundation is verified at full scale: **P3** (group 4->1 icache-refill demux,
group L2 I$, 17->1 refill mux with instruction strict-priority and round-robin data), then **P4** (the
L2 refill mesh with memory channels at the perimeter), then **P5** (RLC per-group instances).

## 2026-08-11 11:3x +0200 — remote ports: n per port-class crossbar, default n=1 (n*5 per tile)

**Commit:** pulp `b8d6e84` "cachepool v3: default to one remote port per port-class crossbar (n*5 per tile)"

**Architecture clarification (user).** The core-to-other-tile remote port count is not fixed at five.
All five of a core's master ports (scalar + 4 VLSU lanes) go to their own tile-level crossbar, each
crossbar has a CONFIGURABLE number of remote ports n, and with five parallel crossbars a tile has
**n * 5** remote ports in total. Default n = 1.

**State of the model.** The structure already matched: `num_remote_port_core` is exactly n, per
port-class crossbar. Only the default was wrong — v3 inherited n = 2 from the canonical config and
built ten remote ports per tile. Now set to 1 in v3 (overridden there, not in the canonical config, so
v1's calibrated numbers measured with n = 2 stay untouched). Verified in the elaborated config:
`nrpc=1` and exactly five ports, `remote_out_0_0 .. remote_out_4_0`, one per crossbar.
`CACHEPOOL_V3_REMOTE_PORTS` sweeps it.

**Measured effect of n:**

| topology | kernel | n=2 | n=1 |
|---|---|---|---|
| 1 group x 4 tiles x 4 cores | load-store_M16 | 178,448 | 178,448 |
| | byte-enable | 531,159 | 531,159 |
| | spin-lock | 122,958 | 122,958 |
| | fdotp_M8192 | 47,711 | 47,711 |
| | cache-test-vector | 1,975,357 | 1,975,357 |
| 4x4 groups x 1 tile x 4 cores | fdotp_M32768 | 59,289 | **63,555** (+7.2%) |
| | cache-test-vector | 1,901,038 | **2,080,030** (+9.4%) |

**Caveat that matters for interpreting those numbers.** The remote ports carry **no explicit
occupancy**: the remote crossbar picks an output with `source % n` and forwards via `req_forward`, with
no per-port arbitration or busy tracking. So n is structure and wiring, not modelled bandwidth — which
is why it changes nothing at one group. The 4x4 sensitivity comes from how slots map onto tile inputs
rather than from port contention, and **the exact mechanism is not yet traced**. If n is meant to act
as parallel bandwidth, per-port occupancy has to be added — the same stamped-versus-structural
distinction that steps 1-3 of the calibration kept hitting.

**Also note:** the 4x4 numbers quoted in the earlier P1 and calibration entries were taken with n = 2.
With the intended n = 1 default they are 63,555 (fdotp_M32768) and 2,080,030 (cache-test-vector).

## 2026-08-11 10:5x +0200 — #34 step 3: async flush gate; and the load-store residual is MLP, not a missing cost

**Commit:** core `9c2dbe1f` "insitu: gate the async pipeline during a flush walk"

**Third instance of the same pattern.** `run_flush()` stamps the walk's duration and
`run_request_sync()` stamps the remaining wait for anything arriving during it — but nothing consulted
`flush_busy_until_` on the async path, where stamps are discarded, so a flush cost nothing there.
`stage0_arbitrate` now refuses to start new work until the walk ends (the RTL's `l1d_busy_i`), making
the gate real time. Effect is real but small: load-store_M16 177,199 -> 178,448, i.e. -9.5% -> -8.8%.
v1 unchanged, including the flush-heavy load-store_M16 at 154,001 (stage0_arbitrate is async-only).

**The important result is why load-store is still 8.8% under, and it is NOT an under-charge.**
Same kernel, same topology, both modes:

| mode | rd_hit | rd_miss | wr_hit | wr_miss | refill | hit rate |
|---|---|---|---|---|---|---|
| sync | 12,137 | 2,525 | 6,721 | 465 | 2,990 | **86.3%** |
| async | 1,251 | 13,411 | 544 | 6,642 | 3,130 | **8.2%** |

Identical access count (21,848) and near-identical refills, so the WORK is the same. What differs is
that the async path has genuinely pending lines: an access landing on an in-flight refill merges onto
the MSHR and waits, where the synchronous path completes every refill inside the call so everything
after the first access is a hit. Measured served latency is **693 cycles** on average — and yet the
total cycle count is LOWER than sync, because the async path OVERLAPS those waits across outstanding
requests. That is memory-level parallelism the synchronous model structurally cannot express.

**So "match sync" is the wrong target for this kernel.** v1's load-store over-predicts the RTL by
**+52%**; being below sync here plausibly moves toward the RTL, not away. Closing that 8.8% would be
fitting to a known-bad reference. Recorded as a deliberate non-goal rather than an open defect.

**Where #34 stands** (1 group x 4 tiles x 4 cores, async vs the calibrated synchronous path):

| kernel | async | sync | delta | at session start |
|---|---|---|---|---|
| fdotp_M8192 | 47,711 | 47,196 | **+1.1%** | -6.5% |
| byte-enable | 531,159 | 526,512 | **+0.9%** | -5.7% |
| spin-lock | 122,958 | 125,833 | **-2.3%** | no completion |
| load-store_M16 | 178,448 | 195,734 | -8.8% (MLP, see above) | -16.3% |

Three calibration steps, all the same shape — find a cost modelled by stamping and make it structural:
1. `d11cf08f` per-access response latency (measured 2.76 cycles vs the RTL's 10; now 10.76).
2. `21603980` the AMO lane window, absolute from accept rather than additive.
3. `9c2dbe1f` the flush walk gate.

**Open:**
- **Hit vs miss cannot be separated by one response-latency constant.** The RTL's cold miss is
  MemLatency + 17; we reach about +11. A miss-side term is the next real refinement.
- **Dead stamps**: the xbar's `xbar_latency_cycles` and the remote xbar's `hop_latency_cycles` are
  still stamped and therefore discarded. Convert to structural or delete so they stop implying they
  do something.
- **The reference itself.** Everything above is measured against the synchronous path, which is only
  RTL-calibrated where v1 was measured (fdotp +1.6%, load-store +52%). Getting RTL numbers for a
  v3-comparable configuration is now the highest-value calibration work — without them, the
  hit-dominated kernels are trustworthy to ~1% and the miss/MLP-dominated ones are not anchored at all.

## 2026-08-11 10:0x +0200 — #34 step 2: the AMO window is absolute; async now within ~2.5% on 3 of 4 kernels

**Commit:** core `21603980` "insitu: make the structural AMO window absolute, not additive"

**The residual, explained.** Structural occupancy held the lane for `total` cycles AFTER the RMW's
sub-operations finished, with total derived from their stamped latencies plus `rmw_write_rtt_cycles`.
On the async path that double-charges: the sub-read and sub-write already spend real simulated time
there — roughly 10 cycles each once `resp_latency_cycles` is calibrated — so an RMW cost about 28
cycles against the RTL's 15-20, and spin-lock over-predicted by 19.8%.

**Fix.** The window is now ABSOLUTE, measured from RMW accept: released at
`rmw_start + amo_rmw_window_cycles`, or immediately if the sub-operations already ran past it. That is
what `core_ready = 0` describes in `spatz_cache_amo.sv` — a span from accept, not a tail after the
write-back. No stamp on this path either; the requester lived through the RMW in real time.

**Sweep vs the calibrated synchronous path (spin-lock 125,833):**

| window | cycles | delta |
|---|---|---|
| 15 | 122,674 | -2.5% |
| 18 | 122,674 | -2.5% |
| 20 | 128,181 | +1.9% |

15 and 18 give the same answer because the window **does not bind** there: the RMW's emergent
structural cost is already ~19 cycles, inside the RTL's stated 15-20 range on its own. That is a good
sign for the model, so the default stays 18 — the cost stays emergent rather than fitted to the
reference. `INSITU_AMO_WINDOW` sweeps it.

**Async vs the calibrated synchronous path** (1 group x 4 tiles x 4 cores), after steps 1 and 2:

| kernel | async | sync | delta | at session start |
|---|---|---|---|---|
| fdotp_M8192 | 47,464 | 47,196 | **+0.6%** | -6.5% |
| byte-enable | 530,895 | 526,512 | **+0.8%** | -5.7% |
| spin-lock | 122,674 | 125,833 | **-2.5%** | no completion |
| load-store_M16 | 177,199 | 195,734 | -9.5% | -16.3% |

v1 cachepool 16-core remains exact throughout: spin-lock 76,628, fdotp_M32768 49,001.

**Open, in priority order:**
1. **load-store -9.5%** — the only kernel still meaningfully off. It is partition/flush heavy, so the
   flush path's cost (`flush_base_cycles` + per-dirty-line eviction) is the first thing to look at; on
   the async path a flush's writebacks are issued inline while everything else is structural.
2. **Hit vs miss cannot be separated by one constant.** The RTL's cold miss is MemLatency + 17; we
   reach about +11. A miss-side term is the next refinement.
3. **Dead stamps**: the xbar's `xbar_latency_cycles` and the remote xbar's `hop_latency_cycles` are
   still stamped and therefore discarded on the async path. Convert to structural delay or delete.
4. The reference is still the synchronous path, itself only partly RTL-calibrated (v1's load-store was
   +52% vs RTL). No RTL numbers exist for the v3 topologies.

## 2026-08-11 09:2x +0200 — #34 step 1: the async path's per-access latency is measured and calibrated

**Commits:** core `d11cf08f` "insitu: measure and calibrate the async path's per-access latency" ·
pulp `8dc0f29` "cachepool v3: adopt the calibrated async response latency"

**The audit that starts #34.** Which components model delay structurally (real simulated time) and
which by stamping? On the v3 async datapath the stamp sites are `insitu_cache_xbar`'s
`xbar_latency_cycles`, `insitu_cache_remote_xbar`'s `hop_latency_cycles`, and the AMO shim's
`inc_latency` — and **all of them are discarded**, because `iss/src/lsu.cpp`'s `data_response`
zeroes `pending_latency` on the outstanding-capable path where the synchronous branch honours
`req->get_latency() + 1`. What actually counts on the async path is only real time spent in queues
and FSMs: the cache core's per-cycle pipeline, the FlooNoc routers (2 cycles/hop), and — since
`7c953a3e` — the AMO lane window.

**Measured before tuning.** The core now reports **served latency** at stop(): accept cycle to
response cycle in real simulated time, i.e. exactly what the requester experiences. On byte-enable at
1 group x 4 tiles x 4 cores: **2.76 cycles** over 4,457 accesses, against the RTL-derived reference
of **10 isolated / 7 streaming**. The async path was under-charging every access by 4-7 cycles, which
is why its cycle counts kept coming out BELOW the calibrated synchronous path.

**Fix + sweep.** `resp_latency_cycles` spends that cost structurally: a completed access is not
eligible to respond until the delay elapses. Swept with `INSITU_RESP_LAT` (env override, no rebuild):

| D | byte-enable | served_lat | vs sync 526,512 |
|---|---|---|---|
| 0 | 496,382 | 2.76 | -5.7% |
| 4 | 513,562 | 6.75 | -2.5% |
| **8** | **530,895** | **10.76** | **+0.8%** |

Two independent references agree on **D=8**: served latency 10.76 vs the RTL's 10-cycle isolated
read-hit, and byte-enable within 1% of the calibrated synchronous path. Adopted as the async default
(0 when `inline_sync_miss`, and the synchronous path never touches `resp_fifo_`, so it cannot be
perturbed — confirmed: v1 16-core fdotp_M32768 49,001 and spin-lock 76,628, both exact).

**Async vs the calibrated synchronous path**, 1 group x 4 tiles x 4 cores:

| kernel | async D=8 | sync | delta | was |
|---|---|---|---|---|
| fdotp_M8192 | 47,464 | 47,196 | **+0.6%** | -6.5% |
| byte-enable | 530,895 | 526,512 | **+0.8%** | -5.7% |
| load-store_M16 | 177,199 | 195,734 | -9.5% | -16.3% |
| spin-lock | 150,768 | 125,833 | +19.8% | no completion |

**Residuals, deliberately left open and NOT tuned away:**
- **spin-lock +19.8%** — the structural AMO window is derived from sub-operation latencies that now
  include the +8, so the lane is held too long. It wants its own pass, not a fudge to this knob.
- **load-store -9.5%** — still under-charging.
- A single constant cannot separate hit from miss cost. The RTL's cold miss is MemLatency + 17; this
  reaches roughly +11, so a miss-side term is the next refinement.
- The discarded stamps in the xbar and remote xbar are still discarded; converting them to structural
  delay (or dropping them as dead code) is the remaining half of the audit.

**Still true and worth repeating:** the reference here is the *synchronous* path, which is itself
only calibrated where v1 was measured against RTL (fdotp +1.6%, but load-store was +52%). Matching it
is necessary, not sufficient. RTL numbers for the v3 topologies do not exist yet.

## 2026-08-11 08:1x +0200 — #35 fixed: AMO lane occupancy must BLOCK, not stamp, on the async path

**Commit:** core `7c953a3e` "insitu: hold the AMO lane in real time when the cache answers
asynchronously"

**The finding that matters beyond this bug.** The async path DISCARDS stamped latency. In
`iss/src/lsu.cpp`'s `data_response`, the outstanding-capable branch sets `pending_latency = 0`,
where the synchronous branch uses `req->get_latency() + 1`. So every `inc_latency()` a component
stamps is thrown away for an async completion, and the scoreboard releases the destination register
one cycle after the response arrives. Any occupancy or contention a component models by stamping is
therefore invisible on the async path — this is the structural reason the async model cannot be
calibrated as it stands, and it is the entry point for #34.

**How that broke spin-lock.** B3 modelled the RMW lane occupancy as a stamp on arriving requests.
With the stamp discarded, an RMW cost only the two cycles its sub-operations take, against the RTL's
15-20 cycle `core_ready=0` window (`spatz_cache_amo.sv`). Measured at 1 group x 4 tiles x 4 cores:
15 contenders issued **74,624 amoswaps during a single critical section**, one every 2.3 cycles,
swamping the bank and starving the holder's own accesses. The holder kept the lock for **172,208
cycles** and the test never finished — past 227M cycles, against 125,833 for the entire test on the
synchronous path.

**The protocol was never broken**, which is why this took so long to pin down: acquire, release and
handoff were all correct, with a contender picking the lock up two cycles after each release
(`old=0x0` at 15385, immediately after core 4's release at 15383). Both of my earlier framings were
wrong and are corrected here: it is not a deadlock (time advances, cores make progress) and not
"the holder never releases" (releases are visible at cycles 9595, 15383, 187593 with operand 0x0 —
`spin_unlock` is `amoswap.w zero, zero`).

**Fix.** `structural_occupancy` holds the lane for the whole window in real simulated time —
arrivals park, and a ClockEvent releases them when the window expires — instead of stamping it. The
tile enables it exactly when the cache is asynchronous (`inline_sync_miss` False), so the calibrated
synchronous path keeps the stamp it was tuned against and cannot be perturbed.

**Results.** async spin-lock **99,546 cycles** (was: no completion past 227M). No regression:
- v1 cachepool 16-core exact on all four reference kernels: 49,001 / 225,001 / 154,001 / 76,628.
- v3 async 1 group: fdotp_M8192 44,143 (was 44,055, +0.2%), load-store_M16 163,824 (was 164,129,
  -0.2%), byte-enable 496,382 unchanged.

**Tooling note.** The shim's debug budget was a fixed `static int n = 400`, unlike the rxbar/xbar
budgets. That made the shim look like it had gone silent after cycle 3886 when it had merely stopped
printing, and I briefly concluded from it that the release never reached the shim. `INSITU_AMO_DEBUG=N`
is now the line count, and the RMW trace carries the initiator.

**#34 (calibration) is now the clear next item, with a concrete first task**: decide, per component,
whether it models delay structurally (real simulated time) or by stamp, and make the async path
consistent. Today the async path is a mixture — the cache core's latency emerges from its per-cycle
FSM, the AMO lane now blocks for real, but anything still stamping is silently ignored, and the
requester zeroes what it receives. Until that is settled, no v3 async cycle count means anything,
including the ones in this entry.

## 2026-08-11 07:2x +0200 — v3-P1 DONE: fdotp completes on the mesh; 6/6 kernels at the target 4x4

**Commits:** core `db9e2ab6` "insitu: route off-group L1 traffic through a tunnel instead of the
mesh's address map" · pulp `e21d3b3` "cachepool v3: map the L1 NoC by tunnel window, one entry per
group"

**The last blocker, and why a map could never work.** Which tile — hence which group — owns a line
depends on the interleaving granularity, and that granularity is RUNTIME-programmable via
XBAR_OFFSET (fdotp sets `log2(dim * sizeof(float))`). A FlooNoc address map built at elaboration from
the build-time granularity is therefore wrong the moment software reprograms it, which is exactly
what the trace showed: the mesh handed a group-7 address to group 14, whose crossbar correctly sent
it back out. No static map can follow a runtime-programmable interleaving.

**Fix: tunnel the destination instead of re-deriving it.** The remote crossbar already computes the
target group from the CURRENT geometry, so it re-addresses an off-group request to
`noc_tunnel_base + tgt_group * noc_tunnel_stride + addr`, and the mesh routes on that. One static
entry per group; the map's `remove_offset` strips the tunnel so the destination tile sees the
untouched original address and re-decodes it with its own runtime geometry. Routing follows the
runtime configuration for free.

Also closer to the hardware, whose L1 NoC routes on a source-computed TileID rather than re-decoding
an address at every hop. FlooNoc cannot express that directly — it honours a caller-supplied
`REQ_DEST_X`/`REQ_DEST_Y` only on the RESPONSE path (`handle_rsp`), and an explicit-destination
request mode would mean changing a model v2 shares at 256 cores — so the tunnel buys the same
behaviour without touching it. Stride is a full 32-bit space per group, based above 4 GiB; the
constants live in `insitu_cache_remote_xbar.py` and the cluster imports them so the two sides cannot
drift; read as 64-bit because `get_child_int` truncates. Inert at `num_groups == 1`, so v1 is
untouched.

**Results — the mesh is now green, including the gate that started this.**

| gate | kernel | result |
|---|---|---|
| R3: 2x2 groups x 1 tile x 4 cores (16c) | fdotp_M8192 | **PASS 48,251** (was a hang) |
| **4x4 mesh** x 1 tile x 4 cores (64c) | fdotp_M32768 | **PASS 59,289**, 87% util (was hang, then stack overflow) |

Full set at 4x4 / 64 cores, all clean: `cache-test-scalar` 1,592,532 · `cache-test-vector` 1,901,038 ·
`cache-vector-rw` 474,929 · `byte-enable` 583,429 · `load-store_M16` 188,269 (7/7 partition+flush) ·
`fdotp_M32768` 59,289. Four are bit-identical to their pre-tunnel values — as expected, since the
tunnel is timing-neutral for kernels that keep the build-time offset.

**Three bugs closed to get here**, all found this session and each hidden behind the previous one:
1. `3707f7ce` — the VLSU started a vector memory op while earlier elements were still missing.
2. `5d7975b` — the remote crossbars' partition-config endpoint was orphaned at 1 tile per group, so
   they decoded addresses with a stale dyn_offset and bounced requests forever.
3. `db9e2ab6` / `e21d3b3` — the mesh's static address map could not follow a runtime-programmable
   interleaving.

**What v3-P1 leaves open** (none of it mesh work):
- **#35** async atomics starve under contention (reproduces at 1 group, no mesh needed).
- **#34** the async path is uncalibrated — no v3 cycle count is quotable yet, including the ones above.
- Scale: 64 cores is verified; 256 cores (4x4 x 4 tiles x 4 cores) is not yet run.
- `CORES_PER_TILE=2` with multiple groups is still broken (even byte-enable hangs) — a separate,
  unrelated config bug.

Next: P3 (group icache mux + L2 I$ + 17->1 refill mux) is now standing on a verified group level, or
#35/#34 first if calibrated numbers are wanted sooner.

## 2026-08-11 06:3x +0200 — fdotp bounce loop fixed (orphaned rxbar config); remaining cause is the static NoC map

**Commits:** core `4007f878` "insitu: routing-decision traces that expose a geometry disagreement" ·
pulp `5d7975b` "cachepool v3: give the remote crossbars their partition-config endpoint"

**Found the bounce loop.** The new geometry traces (`INSITU_XBAR_DEBUG=N` /
`INSITU_RXBAR_DEBUG=N`, both printing dyn_offset/bank_bits/tile_width/num_tiles with every
decision) showed, for one address at one cycle:

```
[RXBAR group_3_2/rxbar_4] addr=0x80003e0c target=14 tgt_grp=14 my_grp=14 out=0 ->local  geom(dyn=6 ...)
[XBAR  group_3_2/tile_0/xbar_4] addr=0x80003e0c my_tile=14 target=7 local=0 out=5       geom(dyn=9 ...)
```

Same address, same bank_bits/tile_width/num_tiles — but **dyn_offset 6 on the remote crossbar and 9
on the cache crossbar**. `addr_tile()` shifts by `dyn_offset + bank_bits`, so the two disagreed about
which tile owns the line: the crossbar routed it into its own group and the tile called it foreign
and sent it straight back, forever.

**Why the offsets differed.** fdotp programs `l1d_xbar_config(offset)` with
`offset = log2(dim * sizeof(float))` = log2(512) = **9** — choosing an interleaving granularity that
matches its working set, which is exactly what the XBAR_OFFSET CSR is for. Every cache crossbar
applied it. The remote crossbars did not, because their config endpoint was gated on
`tiles_per_group > 1` in TWO places (endpoint count + fan-out in `cachepool_v3_system.py`, boundary
forwarding in `cachepool_v3_cluster.py`) while the crossbars themselves are built whenever there is
any off-tile traffic, cross-group included. At 1 tile per group the port was silently orphaned —
GVSoC creates a placeholder VirtualPort for an unrecognised self-referenced name instead of failing,
the trap already documented in CLAUDE.md. Fixed both gates to use the group's own condition.

**Result:** the 4x4 / 64-core stack overflow is gone (SIGSEGV -> no crash). Regression at
4x4 / 64 cores is bit-identical: cache-test-vector 1,901,038 · load-store_M16 188,269 ·
byte-enable 583,429.

**Remaining cause of the fdotp failure, now precise.** With the offsets agreeing, the tail shows:

```
[RXBAR group_3_2/rxbar_4] in=2 addr=0x80003e0c target=7 tgt_grp=7 my_grp=14 out=2 ->NOC geom(dyn=9 ...)
```

`in=2` is the NoC ingress slot: **the mesh delivered a group-7 address to group 14**, which correctly
bounced it back out. The L1 NoC's address map is built in Python at elaboration time from the
BUILD-TIME interleaving granularity (`group_window = (1 << (line_off + bank_bits)) * tiles_per_group`
= 256 B for offset 6), but the runtime moves the field to offset 9, where the window should be 2 KiB.
A static map cannot follow a runtime-programmable interleaving, so cross-group routing is wrong
whenever software calls `l1d_xbar_config` with anything other than the build-time value. This is an
architectural gap in the model, not a small bug — and it explains why the kernels that pass at
4 groups are the ones that do not reprogram the offset.

**Fix direction:** stop routing cross-group traffic by re-decoding the address in the NoC. The remote
crossbar already computes the destination tile/group correctly at runtime, so it should inject with an
EXPLICIT destination instead. FlooNoc already supports that shape — `REQ_DEST_X`/`REQ_DEST_Y` are
carried on the request and the NI honours them on the non-address path — so the map becomes
irrelevant and always consistent with the runtime decode. That also matches the hardware, where the
L1 NoC routes by TileID rather than re-decoding an address. Group -> mesh node is available as
`gx = gid / nb_y_groups`, `gy = gid % nb_y_groups`.

## 2026-08-11 05:1x +0200 — FIXED the async word loss (a VLSU dependency bug); 4x4 mesh green on 5/6 kernels

**Commit:** core `3707f7ce` "spatz vlsu: do not start a vector memory op while elements are still
missing".

**Root cause of task #36 — and it was not the cache.** The VLSU started the next vector memory
instruction as soon as the previous one's bursts had all been *issued* (`pending_size == 0`), with no
check that any data had *arrived*. Safe with a synchronous interconnect (a burst is already filled
when req() returns OK); wrong with an asynchronous one, especially since `insn_commit()` is called
per burst. `cache-test-vector`'s stress phase copies with `vle32.v v0,(src)` immediately followed by
`vse32.v v0,(dst)` — a RAW on v0 every iteration — so the store issued before the load's bursts
landed and wrote stale register elements to memory.

**How it was localised.** A new `INSITU_SHADOW=1` mode records, per bank, the last value written to
each 4-byte word and checks every read serve against it. It found **zero** mismatches while the test
still reported 81 — i.e. the cache served exactly what had been written through it. That plus "the
test rewrites the same pattern every pass, so reordering is idempotent and only a dropped store is
observable" moved the search off the cache and onto the core. (An in-order-response experiment was
built and then discarded: even perfect ordering cannot fix a dependency violation, since the store
issues independently of whether the load's data arrived. The dead code was removed, not committed.)

**The fix.** `nb_unfilled_bursts` counts bursts the interconnect answered PENDING/DENIED for, and
gates the start of the next vector memory instruction. Deliberately NOT counting `delayed_bursts`
(sync completions with a latency, whose data is already in the register file and only the commit is
deferred) — counting those would serialize the calibrated path for nothing. `in_delayed_drain` stops
that drain decrementing a counter it never incremented. Conservative: any unfilled burst blocks the
next vector memory op rather than only a true register overlap; a precise dependency check is a
calibration-time refinement.

**Results — every failing configuration now passes, at ~0.1-0.3% cycle cost:**

| config | before | after |
|---|---|---|
| 8 tiles / 32 cores (2x2 grp x 2 tiles) | FAIL 81 mismatches, 1,784,650 | **PASS 1,779,611** |
| 64 cores, 2x2 grp x 4 tiles | FAIL 32, 2,467,834 | **PASS 2,467,268** |
| 64 cores, **4x4 mesh** x 1 tile | FAIL 32, 1,903,111 | **PASS 1,901,038** |

Calibrated paths untouched: v1 cachepool 16-core exact on all four reference kernels (fdotp_M32768
49,001 / byte-enable 225,001 / load-store_M16 154,001 / spin-lock 76,628). Note v1 exercises the
gate (its cell coalescer answers PENDING) and is still bit-identical.

**Multi-group status after this fix.** At the target **4x4 mesh / 64 cores**: `cache-test-scalar`,
`cache-test-vector`, `byte-enable`, `load-store_M16` (7/7 partition+flush) all PASS. At 64 cores
2x2x4tiles also `cache-vector-rw`. The remaining kernel is fdotp.

**New, sharper finding on the fdotp failure: a proven bounce loop.** At 4x4 / 64 cores fdotp now
SIGSEGVs instead of freezing, and the backtrace is unambiguous — a stack of ~14+ identical
`InsituCacheRemoteXbar::req_handler` frames, i.e. runaway recursion until the stack dies. The
missing intermediate frames are tail calls: `InsituCacheXbar::req_handler` ends in
`return outputs_[out]->req_forward(req)` (tail-callable, no frame), while the remote crossbar keeps
a frame because it uses the returned status afterwards. So the loop is
**rxbar -> destination tile xbar -> rxbar -> ...**: the destination tile re-emits as remote a
request that the crossbar had already decided belongs to it.

Verified NOT the cause, each from the elaborated config rather than the Python:
- rxbar `group_id` and its tile's `xbar.tile_id` agree pairwise for all 16 groups (0..15), with
  `tiles_per_group=1`, `num_tiles=16`.
- Group/tile/l1 bindings are correct end to end
  (`rxbar_4->out_0` -> `tile_0->remote_in_4_0` -> `l1` -> `xbar_4->in_4`), and each group's
  `noc_out_4_0` goes to its own NI, whose output returns to that group's `noc_in_4_0`.
- The rxbar's C++ port indexing matches those names: `outputs_[n_local_slots_]` IS `noc_out_0`.
- The FlooNoc NI does not mangle the address: `set_addr(burst_base - remove_offset)` with
  remove_offset 0, and the periodic `rel` is used only to clamp a burst against an entry boundary.
- NI input and output port names are distinct (`narrow_input_{x}_{y}` vs `ni_narrow_{x}_{y}`), so
  there is no accidental loop-back binding.

**Next step:** instrument the *destination* tile xbar's routing decision (budgeted stderr, like the
rxbar's `INSITU_RXBAR_DEBUG`, since its own message is LEVEL_TRACE) for requests arriving on a
remote_in slot: address, own tile_id, computed target, local flag, chosen output. That names why it
re-emits, which is the last unknown in this loop.

## 2026-08-11 03:5x +0200 — multi-group scale sweep: mesh works at 4x4/64 cores; a 4th async bug found

**No code change** — this entry records a measurement round (parent pointer + worklog only).

**Why.** Two topologies had been verified separately (1 group x 4 tiles, and 4 groups x 1 tile, both
16 cores). The product — multiple groups AND multiple tiles — was untested, and so was the target
4x4 mesh. Testing it before starting P3/P4 was the whole point: it changes what is left to do.

**Sweep results.**

*2x2 groups x 4 tiles x 4 cores = 64 cores, 16 tiles:*

| kernel | result |
|---|---|
| `cache-test-scalar` | PASS 2,166,365 |
| `cache-vector-rw`   | PASS 322,748 |
| `byte-enable`       | PASS 541,512 |
| `load-store_M16`    | PASS 187,792 (7/7 partition + flush) |
| `cache-test-vector` | **FAIL** — vcache-basic PASS, vcache-stress 32 mismatches |
| `fdotp_M32768`      | HANG (the known freeze) |

*4x4 groups x 1 tile x 4 cores = 64 cores, 16 tiles — the TARGET mesh size:*
`cache-test-scalar` PASS 1,592,532 · `byte-enable` PASS 583,429 · `load-store_M16` PASS 188,431 ·
`cache-test-vector` **FAIL** (32 mismatches).

**The 4x4 mesh works.** This matters beyond core count: at 2x2 every column is a border column, so
the router's X-step guard never fires and XY routing degenerates to Y-then-X. 4x4 has interior
nodes and exercises genuine X-first dimension-ordered routing, 16 groups, and 16 NIs per plane.
Scalar, byte-enable and the full partition/flush suite are clean there.

**The new failure is ASYNC, not the mesh.** `cache-test-vector`'s stress phase fails at every
config beyond the two 16-core/4-tile ones. Localised with a config-only flip at an identical
topology (2x2 groups x 2 tiles x 4 cores = 32 cores, 8 tiles):
- async: **FAIL**, 81 mismatches
- sync : **PASS**, 2,000,810 cycles

So this is a 4th async correctness bug (after the eviction-zeros, arg-clobber and AMO-overlap fixes
in `aae083eb`), and it is concurrency-gated: invisible at 16 cores / 4 tiles, present from 32 cores
/ 8 tiles upward. It is NOT the freeze — R3 fdotp wedges identically in sync and async.

**Reading the failure correctly.** `total_errors` is a SUM over cores, so "32 mismatches" at 64
cores is ~1 bad word per core, not wholesale corruption; 81 at 32 cores is ~2-3 per core. The test
is safe at >32 cores — `active = (cid < MAX_CORES)` with MAX_CORES=32, so cores 32+ do not
participate and never write the MAX_CORES-sized buffers. No out-of-bounds; the mismatches are real.
The stress phase does STRESS_PASSES overlapping vector copies of each core's OWN slice with
rotating offsets, then verifies — no cross-core sharing — so a handful of stale/lost words per core
points at the async path's own read/write ordering under load, not at a coherence issue.

**State of v3-P1 after this round.** The multi-group shell is functional at the target mesh size;
what is left is not mesh work:
1. `fdotp` freeze — NI delivery handshake ignoring IO_REQ_PENDING (sync+async, 4 groups).
2. NEW: async vector-stress data loss under concurrency (>=32 cores / 8 tiles).
3. async atomic starvation (task #35, reproduces at 1 group).
4. The rxbar partition-config endpoint gate at `_TILES_PER_GROUP == 1` (latent).

Items 2 and 3 are both async-under-load, and both must be closed before task #34 (calibration) can
mean anything. Item 1 is independent of async.

## 2026-08-11 02:4x +0200 — 4-group fdotp: frozen, not starving; localised to the NoC delivery handshake

**Commit:** core `00838e9b` "insitu: env-gated routing trace on the remote crossbar".

**Question settled: frozen vs starving.** Spin-lock showed that async atomic starvation looks
*identical* to a freeze through a peripheral trace (cores hammer amoswap, no peripheral traffic,
sim advancing). So the earlier "no progress" claim for R3 fdotp needed a real measurement. Over a
**200 s** wall-clock window with a core-exec trace: 350 exec lines total and the last simulated
timestamp is **5,276,000 ps = cycle 5,276** — the same value seen minutes earlier. Simulated time
does not advance. R3 fdotp is a genuine **freeze**, and it is a different bug from the spin-lock
starvation (which advances to 180M+ cycles). Two problems, confirmed separate.

**It is a same-cycle loop inside one event handler, not an empty event queue.** A true deadlock
with nothing pending would make GVSoC *exit*; instead it burns ~100% CPU. gdb on the live process
(all-thread bt) puts the engine thread in
`Router::fsm_handler` -> `NetworkInterface::handle_request` -> `InsituCacheRemoteXbar::req_handler`
every time it is sampled, with **RSS flat at ~90 MB** across samples — so nothing is leaking and
the *same small set* of requests is being delivered repeatedly.

**Pinned with the new rxbar trace.** At cycle 5281 `group_1_0/rxbar_4` (the SCALAR lane) is handed
the same request endlessly — `addr=0x80003e0c target=2 tgt_grp=2 my_grp=2 out=0 ->local` — routes
it correctly to the local tile every time, and the forward returns **IO_REQ_PENDING**, which is the
correct answer from an async cache. Over the sampled window: 232 local decisions, 68 NoC egress
decisions, 25 PENDING and 15 DENIED returns.

So: the routing arithmetic is right (verified independently — rxbar props are consistent,
`tiles_per_group=1`, `group_id` 0/1/2/3 for group_0_0/group_0_1/group_1_0/group_1_1, and both the
NoC map and `addr_tile()` compute the owning group as `(addr >> 8) & 3`), the target answers
correctly, and the defect is in the **delivery handshake above the crossbar**: the destination NI
re-delivers the same flit within one cycle instead of yielding to the event engine.

**Next step (concrete).** `NetworkInterface::handle_request` acts only on `IO_REQ_OK` and
`IO_REQ_DENIED` from `target->req()`; `IO_REQ_PENDING` falls through both branches, leaving
`is_stalled = false` so the router treats the flit as delivered while nothing records it as
in flight (completion is supposed to arrive later via `narrow_response` -> `handle_response`).
Instrument that site with flit pointer + returned status + `nb_pending_bursts` and the per-class
pending-burst slot, and check `Router::fsm_handler`'s `continue` paths, which re-enqueue
`fsm_event` and could re-run the handler at the same cycle.

**Correction to record.** My first read of the status trace said the destination returns DENIED.
That was a mislabelled printf: the real enum is `OK=0, INVALID=1, DENIED=2, PENDING=3` — I had 2
and 3 swapped. It returns PENDING. The label is fixed in the committed print.

**Two tooling traps hit this round** (both cost a wrong reading before being caught):
- `pkill -f "gvsoc_launcher --config"` matches the *invoking shell's own command line* and kills
  the shell. Use `pkill -9 -x gvsoc_launcher`.
- zsh glob-expands unquoted `--include=*.hpp` and fails with "no matches found". Quote it.

## 2026-08-11 01:5x +0200 — R3 characterised: the mesh is not the problem; async atomics starve

**Commit:** core `ffb1368e` "insitu: hold the whole lane for an in-flight RMW, not just atomics"
(parent pointer bumped with this worklog entry).

**Goal of the round.** Split the fdotp R3 wedge into "cross-group vector traffic is broken" vs
"something else", starting with the cheapest A/B.

**Result: the L1 mesh is exonerated for vector traffic.** At 2x2 groups x 1 tile x 4 cores:

| kernel | R3 (4 groups) | note |
|---|---|---|
| `cache-test-scalar`  | **PASS** 1,043,518 | |
| `cache-test-vector`  | **PASS** 1,867,150 | cross-group VECTOR traffic works |
| `cache-vector-rw`    | **PASS** 317,959   | cross-group vector read+write works |
| `byte-enable`        | **PASS** 530,445   | |
| `load-store_M16`     | **PASS** 164,537   | 7/7 partition+flush |
| `fdotp_M8192`        | HANG (no progress) | |
| `spin-lock`          | HANG (progresses to 180M+ cyc) | |

So "cross-group vector traffic" as a class is fine, and the two failures are the two kernels
that synchronise through atomics.

**Then the decisive split — spin-lock does not need the mesh at all.** At ONE group
(4 tiles x 4 cores, no mesh in the picture): sync **PASSES** at 125,833 cycles, async **HANGS**.
So the spin-lock failure is an ASYNC-ATOMICS problem, entirely independent of multi-group, and it
is a *different* bug from the R3 fdotp wedge. Two problems, not one.

**What the async spin-lock failure actually is: starvation, not deadlock.** With per-core LSU
tracing: pe0 and pe3 are parked on the barrier (0xc0000010) having finished, while pe1 and pe2 are
still issuing `amoswap` (opcode 4) at cycle **179,844,920** and still *receiving responses*. The
simulation progresses; two cores never win the lock. 180M+ cycles against 125,833 in sync mode is
pathological, and it is consistent with the async path's documented over-prediction under
saturation — the same retry-storm shape as the RLC all-active configs.

**The RMW machinery itself is correct.** `INSITU_AMO_DEBUG=1` shows a clean cadence: issue ->
phase 1 (AMO_READ) resp -> phase 2 (AMO_WRITE) resp -> complete, every 2 cycles, with the first
amoswap correctly returning old=0x0 (that core acquires) and the contenders correctly seeing
old=0x1 while it is held.

**Change kept from this round.** The park gate now holds the whole lane for an in-flight RMW
instead of only atomics — a plain store landing between an RMW's read and its write-back is lost,
since the write-back rewrites the pre-store value. Zero window on a synchronous slave, real on the
async path. Parked requests no longer get B3's occupancy stamp (they already waited), and
req_handler drains the park queue when an RMW resolves synchronously. Verified free on the
calibrated path: v1 16-core exact on all four reference kernels (49,001 / 225,001 / 154,001 /
76,628) and the v3 async trio unchanged (44,055 / 164,129 / 496,382).

**Two wrong turns worth not repeating.**
1. `CACHEPOOL_V3_CORES_PER_TILE=2` is NOT a usable A/B knob. At 2x2 groups x 2 cores even
   `byte-enable` hangs, though it passes at 4 cores/tile — the 8-core multi-group config is broken
   for its own reason (CLAUDE.md already flags 2 as the marginal minimum for the icache sizing
   math). The control failed in the same config, so that A/B was void.
2. The gate was widened on a wrong diagnosis. I read "old=0x1 forever" as the holder's release
   store being overwritten, but instrumenting plain writes showed **zero** writes to the lock
   address reaching the shim, and the "forever" was an artifact of a 400-event debug budget
   covering ~300 cycles. The widened gate is still right on atomicity grounds and costs nothing,
   so it stays — but it fixed nothing here.

Also: zsh does not word-split unquoted parameters, so `env $ENVSTRING cmd` passes the whole string
as one assignment and the target's `int(os.environ[...])` throws. Use explicit `VAR=v` prefixes.

**Where this leaves v3-P1.** Two separate open items, both now sharply scoped:
- **fdotp at 4 groups**: genuine no-progress wedge. Not the NoC map, not a dropped request (the
  destination bank serves it), not the response network, not sync-vs-async, and not vector traffic
  as a class. Next: instrument the gap between the destination bank's `resp()` and
  `NetworkInterface::handle_response`, plus the per-class pending-burst release.
- **async atomics starvation**: reproduces at one group, so it can be debugged without the mesh.
  Likely wants fairness/backoff in how the shim and the core's accept queue order competing
  atomics. Belongs with the async calibration work, since it is a saturation-behaviour problem.

## 2026-08-11 00:33 +0200 — v3 async throughout: the async cache path made correct; L1 mesh runs at 4 groups

**Commits:** core `aae083eb` "insitu: make the async cache path functionally correct" ·
pulp `36b087f` "cachepool: v3 runs the cache async; enable the par-coalescer on the multi-tile path"

**Motivation.** User decision: v3 should be async throughout, since a queue-based interconnect
is the more faithful model. The structural cache core had an async path
(`inline_sync_miss=False`) but it had never been run closed-loop — only the synchronous-slave
path is deployed. Turning it on immediately segfaulted, and fixing that exposed two more bugs
underneath.

**Files touched.**
- `core/models/cache/insitu/insitu_cache_core.cpp` — eviction data snapshot, in-flight
  writeback guard + `evict_resp_handler`, removal of `save()`/`restore()` on the async
  admission/response path, response-time address un-rotation, `INSITU_WATCH` instrumentation.
- `core/models/cache/insitu/insitu_cache_amo_shim.cpp` — park queue so a second atomic cannot
  overwrite an in-flight RMW's state.
- `pulp/pulp/cachepool_v3/cachepool_v3_system.py` — async cache by default
  (`CACHEPOOL_V3_SYNC_CACHE=1` restores the calibrated sync slave).
- `pulp/pulp/snitch/snitch_cluster/snitch_cluster.py` — `cell_coalescer` on the multi-tile path
  (it was only ever set on the single-tile branch).

**The three async bugs, in the order they were found.**

1. **Async writebacks wrote zeros over L2.** `evic_fifo_` queued only the line ADDRESS; the
   drain then handed `evict_data_buf_` to the request — a buffer that only the sync-miss and
   flush paths ever fill, so on this path it was still the zero-initialised vector from the
   constructor. Every async writeback pushed 64 zero bytes to memory, and the next refill of
   that line read them back. Symptom: fdotp printed `----- (0) sp fdotp -----` and
   `0 OP/1000cycle`, because `dotp_l.M` (0x80003f40, `.data`) went 0x2000 -> 0 mid-run; the
   kernel then computed `elem_per_core = 0`, did no work, and still reported `retval=0` by
   verifying zeros against zeros. Cycle count was LOWER than sync, which is what gave it away.
   Fix: the queue carries a snapshot of the line's bytes taken before the refill overwrites the
   way, held alive while the request is in flight; plus the one-in-flight guard and response
   handler an async L2 needs (`evict_itf_` had no resp method at all).

2. **`req->save()` clobbered the requester's arguments.** `save()` arg_push'es 4 slots at
   `current_arg`, which is 0 for a scalar-LSU request — but the LSU keeps its request id in
   ABSOLUTE slot 0 (`req_id = *((int *)req->arg_get(0))`, `iss/src/lsu.cpp`), and `arg_get()`
   applies no `current_arg` offset. So save() overwrote the id with the address, and `restore()`
   only pops the depth back — it never repairs the slot's contents. The LSU then dispatched
   `stall_callback[req_id]` against the wrong outstanding access. On a VLSU port the aliased
   index segfaulted inside `AraVlsu::data_response` -> `vp::Queue::push_back`. Fix: drop the
   save/restore pair entirely (the core never mutates addr/size/data/is_write on a parked
   request) and un-rotate the address at response time instead — which the sync path gets from
   the xbar, and which the L1 NoC needs since its NI re-derives routing from `req->get_addr()`.

3. **The AMO shim assumed RMWs cannot overlap.** True only because a synchronous cache resolves
   the whole read-modify-write inside `req_handler`. Async leaves `phase_` at `AMO_READ` across
   ticks, and a second atomic overwrote `phase_`/`orig_`/`scratch_`/`amo_addr_`, so two RMWs
   completed into each other's result buffers. Fix: atomics arriving on a busy lane are parked
   and re-issued on completion (what `core_ready` does in the RTL). The gate is deliberately
   limited to atomics — plain accesses never touch that state and B3's occupancy stamp already
   models the lane being held, so parking them too would charge the same wait twice. This
   matters on the calibrated path as well: the cell coalescer below the shim answers PENDING by
   design even when the cache itself is a synchronous slave.

**New instrumentation.** `INSITU_WATCH=0x<addr>` traces one cache line end-to-end through the
structural core (refill / serve-rd / serve-wr, with bank path and rotation count). Zero cost
when unset. It is what localised all three bugs, and it is what proved the destination bank
serves cross-group reads correctly in the R3 investigation below.

**Verification.**
- Async, 1 group x 4 tiles x 4 cores: fdotp_M8192 prints `(8192)` at 96% utilisation
  (44,055 cyc), load-store_M16 passes all 7 partition/flush cases (164,129), byte-enable clean
  (496,382). All three were previously wrong or crashing.
- No regression on the calibrated paths: v3 sync is bit-identical to its baseline (load-store
  195,734 / fdotp 47,196 / byte-enable 526,512) and the deployed v1 `cachepool` 16-core target
  reproduces its numbers exactly (fdotp_M32768 49,001 / byte-enable 225,001 /
  load-store_M16 154,001).
- NOTE on the v1 check: a first run showed fdotp_M32768 at 239,001, which looked like a 4.9x
  regression. It was not — v1 defaults to a 4-core/1-tile MINIMAL config; the 16-core numbers
  need `CACHEPOOL_NB_TILE=4 CACHEPOOL_CORES_PER_TILE=4`. Worth remembering before diagnosing a
  v1 "regression" again.

**R3 gate (multi-group L1 mesh) — mostly PASSES, one kernel short.**
At 2x2 groups x 1 tile x 4 cores (16 cores, 4 groups, 5 FlooNoc meshes):
- `byte-enable` **PASS** — 530,445 cyc, 0 FAIL.
- `load-store_M16` **PASS** — 164,537 cyc, 0 FAIL, all 7 partition/flush cases (compare 164,129
  at 1 group x 4 tiles: the mesh costs ~0.2%).
- `fdotp_M8192` **HANGS** — deterministic wedge, no output.

So the multi-group shell is functional: cross-group routing, the remote crossbars, both DRAM
windows on the mesh, the barrier and the L1D CSR fan-out all work at 4 groups. What remains is
specific to fdotp, i.e. to cross-group **vector (VLSU)** traffic.

**What the fdotp wedge is NOT** (each ruled out with evidence, so it is not re-litigated):
- *Not* sync-vs-async. Both modes wedge identically: 29 barrier arrivals, 27 stalls, the same
  per-core pattern (cores 0-3 and 7 arrive once, the other twelve twice), at cycle ~4,838 (sync)
  / ~4,880 (async). The async work above neither caused nor fixed it.
- *Not* the NoC address map. `0x80003e0c` belongs to gid 2 by both decodes — `(0x3e0c/0x100) mod
  4 = 2` and the xbar's TileID field bits[9:8] = 2 — and the NI delivered it to mesh node (1,0),
  which IS gid 2: creation and mapping share `gid = gx*nb_y_groups + gy`, so `group_1_0` is gid
  2, not gid 1.
- *Not* a dropped request. `INSITU_WATCH=0x80003e0c` shows the destination bank
  (`group_1_0/tile_0/l1/ctrl_0`) serving that exact address at cycle 5133. The request arrives.
- *Not* a broken response network. The response mesh is live (1038 `rsp_router` events) and 68
  remote bursts completed before the wedge.

**Where it actually stops:** the last NoC event is `ni_1_0` "Sending request to target" for
`0x80003e0c`, the bank serves it, and no response burst follows. Cross-group traffic works for
thousands of NoC events and then one response stops coming — resource-exhaustion-shaped rather
than a wiring error. Prime suspect is the FlooNoc NI's single pending read burst + single
pending write burst per port under 4 concurrent VLSU lanes, or the remote crossbar's slot
accounting for the vector lanes (`nrpc=2` remote ports per core per lane). Next step is to
instrument the NI's pending-slot occupancy and the rxbar's slot allocation rather than to trace
further — the remote xbar's per-request message is `LEVEL_TRACE`, which plain `--trace` does not
emit (that cost a wrong "zero traffic through the rxbar" reading mid-session; a second wrong
reading came from unflushed trace buffers when the run is killed by `timeout`, fixed by running
the launcher under `stdbuf -oL -eL`).

**Calibration status unchanged:** the async path is UNCALIBRATED and documented to over-predict
under saturation. No sync-path number (RLC +/-4%, fdotp +1.6% vs RTL) carries over to it;
re-calibration is a prerequisite before quoting any v3 async number.

**STATUS 2026-08-10 (v3-P1 — livelock confirmed, two more suspects eliminated, mesh robustness caveat):**
No code change beyond core `624a7072`; this entry records what the instrumentation settled.

**It is a livelock, not slowness.** Same binary (`fdotp-32b_M8192`, ~1,300 kernel cycles / ~47 k
total) and the same 16 cores: v3 at 1 group × 4 tiles finishes in **seconds** (47,196 cycles); v3 at
2×2 groups × 1 tile produces **no output in 15 minutes**. Only the topology differs, so "maybe it's
just slow" is off the table.

**Two more suspects eliminated by probing (probes removed; upstream `floonoc` restored):**
- *Burst accounting is correct.* At the NI, `REQ_REM_SIZE` is written and read back at the **same**
  `current_arg` (0) and the same slot address, going 4 → 0. Bursts do complete.
- *Arg-slot overflow/clobber is not happening.* `save()` pushes 4 slots exactly where the NI keeps its
  scratch (`arg_get_last` is relative to the top and the NI never reserves), which would be a real
  hazard — but the deployed sync path never calls `save()`, and slot counting leaves the NI writing at
  index 6–7 of 16.

**Mesh robustness caveat worth recording.** I tried to shrink the repro to 2 groups × 1 tile × 2
cores; v3 deadlocks there — **and so does v2**, with the same zero-output signature. So a degenerate
2×1 (one-dimensional) mesh is broken for *both* targets and is not a valid minimal repro. v2's
behaviour by topology: 4×4 (its validated config) works, 2×2 × 1 tile × 4 cores runs the kernel
(25 bursts) but cannot reach EOC because of its 0x14-vs-0x24 peripheral map, 2×1 hangs outright.
**The valid A/B is therefore 2×2 × 1 tile × 4 cores**, where v2 runs the kernel and v3 does not.

**Next:** chase the two remaining differences between v2 and v3 at that config — (a) v2 rewrites the
address into a contiguous NOC space via `L1NocAddressConverter` while v3 relies on FlooNoc's `period`
mapping on raw addresses (the mapping resolves, but the NI may depend on contiguity elsewhere, e.g.
when splitting a burst or computing `burst_base`); (b) v2's target behind the NI is an **async** flat
controller whereas v3's is a **synchronous** slave returning OK in-call, which changes when
`handle_response` runs relative to the router FSM. Test (b) first: it is a one-line A/B —
`controller.inline_sync_miss = False` in the v3 cache config.

---

**STATUS 2026-08-10 (v3-P1 — found and fixed the in-place-rotation/NoC conflict; R3 still blocked):**
core `624a7072`. Two suspects from the previous entry were settled by instrumentation (probes since
removed; upstream `floonoc` restored untouched):

- **`get_entry` NULL — ELIMINATED.** The `period` mapping resolves every cross-group burst; the
  `entry == NULL` branch never fires. So the address→group mapping on our native layout is correct
  and no v2-style address converter is needed.
- **A genuine, previously-unknown bug — FIXED.** The NI was being handed requests carrying
  **rotated** addresses: `0xa8000380`, `0x1800040c`, `0xd80003c0` … none of which are DRAM addresses.
  Verified numerically: `rotate(0x80003a80, n=4, dyn_offset=6)` = `0x8000_0380 | 0xA000_0000` =
  **`0xA8000380`**, exactly the observed value. Cause: E1 rotation mutates the request address **in
  place** and never restores it. That is invisible inside a single group (nothing outside the cache
  reads the address afterwards), but with the L1 NoC in the path the network interface still owns the
  in-flight burst and re-derives routing from `req->get_addr()`; a rotated address matches no window,
  so the response cannot get home and the NI's single pending-burst slot wedges — after which the NI
  re-delivers the same (now corrupted) request, which is what the probe captured. Fix: restore the
  caller's address once the bank has resolved the access. Correct for the synchronous-slave path (the
  deployed one); an async cache would need to restore at response time.
  **Regression-checked:** 16-core single-group unchanged (fdotp_M32768 49,001, byte-enable 225,001,
  both 0 fails).

**R3 still does not pass.** The corruption-on-re-delivery is fixed, but the *first* delivery's burst
still does not complete, so the run hangs. That is now the single open question: the target returns OK
(`status=0` at `target->req`), the response packet is generated, yet only ~2 of 12 bursts reach
`REQ_REM_SIZE == 0` at the origin. Remaining suspect from the earlier list: the IoReq arg-slot budget
— our path spends 4 slots on the per-lane Router before the NI pushes its own (`REQ_SRC_NI`,
`REQ_BURST`, `REQ_WIDE`, `REQ_REM_SIZE`, `REQ_IS_ADDRESS`) against `IO_REQ_NB_ARGS = 16`, and an
overflow would corrupt exactly this bookkeeping. Next step: count slots on the cross-group path and,
if tight, drop the per-lane Router from the off-group route (the tile xbar can address-decode the
lane directly) or raise the arg budget.

---

**STATUS 2026-08-10 (v3-P1 continued — localized the mesh blocker; one important v2 caveat found):**
core `f678aad7`, pulp `8862425`. Instrumented the FlooNoc NI (probes since removed; upstream
`floonoc_network_interface.cpp` restored untouched) and got the decisive numbers.

**What the data says.** At 2×2 groups × 1 tile × 4 cores, 12 cross-group bursts are injected — the
12 cores in the three groups that do not own the contended line — and **only 2 ever complete**
(`REQ_REM_SIZE` reaching 0). The request direction is fully correct (verified earlier: leaves group 0,
crosses the mesh, served by the owning bank in group 2 with status OK). Grants and responses were
confirmed to auto-route past `req_forward` — the NI issues them via `req->get_resp_port()`, so no
relay is needed in our crossbars (my earlier hypothesis that v2 fed the NI converter-built requests
was **wrong**: v2's converter also uses `req_forward`, it only rewrites the address).

**Control experiment that separates our bug from the NoC: v2 at the same 2×2 topology.** v2 runs the
kernel to completion there (results printed, **25** burst completions) and then hangs — but for an
unrelated reason: **v2's peripheral answers EOC at 0x14 while the CachePool binaries write 0x24**, so
*v2 can never reach EOC with these binaries at any topology*. Two conclusions: (a) the mesh + NI
genuinely works for this traffic shape, so the remaining fault is in how v3 feeds it; (b) **"v2 runs
the CI kernels at 256 cores" needs qualification** — it runs them, it does not terminate on them.
Worth remembering before any v2 number is quoted.

**Refinement made:** one NoC egress/ingress port per port class instead of two
(`source % nrpc`). The NI is a single injection point with one pending read burst and one pending
write burst, so two masters only doubled contention on that slot and deviated from v2's
one-master-per-NI arrangement. Did not by itself unblock R3.

**Next, precisely:** find why our bursts stop completing after the first per NI. The release path is
`narrow_read_pending_burst` cleared in the FSM once `narrow_read_pending_burst_nb_req` hits 0, that
counter being decremented per returning response packet through a pointer stored on the packet. So
the question is whether our response packets return at all after the first burst — the likely
suspects are (i) `noc->get_entry(burst_base, size)` failing for some address under the `period`
mapping (v2's documented silent-drop-and-wedge), which a probe on the `entry == NULL` branch settles
immediately, and (ii) the IoReq arg-slot budget: our path already spends 4 slots on the per-lane
Router before the NI adds its own, against `IO_REQ_NB_ARGS = 16`.

---

**STATUS 2026-08-10 (v3-P1 — L1 mesh wired, cross-group routing PROVEN, R3 not yet passing):**
core `95aa0290` + pulp `5f53399`. The remote crossbar became group-aware (`num_groups` /
`tiles_per_group` / `group_id`): the address TileID field is now CLUSTER-GLOBAL, its top bits being
the group, so a "remote" target is either a tile in this group (local slot, as before) or another
group (new `noc_out_{r}` egress). Off-group arrivals enter on `noc_in_{r}` and are routed on to the
owning local tile. `num_groups==1` is byte-identical to before and creates no NoC ports.
Cluster: one `FlooNoc2dMeshNarrowWide` per TCDM port class. **No address converter needed, unlike
v2** — our native layout puts the routing fields in ascending contiguous bits, so each group owns one
window repeating every `period`, which is exactly what FlooNoc's `period` mapping expresses. Both
DRAM windows mapped (an unmatched window drops the burst and wedges the NI — v2's lesson).
**Two bring-up bugs fixed:** (a) the tile created remote ports only when `nb_tiles_per_group>1`, but
a 1-tile-per-group multi-group build needs them for other groups → "an unbound interface was called";
(b) each tile's cache `tile_id` must be the CLUSTER-GLOBAL id — with a local index a tile in group>0
never recognises its own lines, re-emits them as remote, its group's crossbar sees the target group as
its own and sends them back: an **infinite request loop** (engine spinning in
`NetworkInterface::handle_request` → `InsituCacheXbar::req_handler`).
**Verified by instrumentation:** a request leaves group 0 (`at=2, local=0, out=remote`), crosses the
mesh, and is served by the owning bank in group 2 (`local=1, status=OK`) — cross-group routing is
correct end to end.
**R3 still fails:** the burst does not complete back through the NI (first cross-group attempt
DENIED, then PENDING, response never returns) → the run hangs with no output. Next step is the
NI/burst-completion contract: FlooNoc accounts a burst by `REQ_REM_SIZE` and owns fixed arg slots, so
the cache's request/response shape has to match what the NI expects (v2 fed it converter-built
requests, we forward the core's own IoReq). Scope: response path only — the routing and mapping are
done.

---

**STATUS 2026-08-10 (cell coalescer: two real bugs fixed, then enabled at 16 cores — big calibration
shift):** the C1 par_coalescer (RTL `i_par_coalescer_for_spatz`, `cachepool_cache_ctrl.sv:354`) was
only ever enabled on v1's SINGLE-TILE path; the multi-tile group path never set it, so **every
16-core number in this project was produced without a structure the RTL has** (see the correction
appended to `prompt/cachepool_p1_3_p2_1_cell_serialization_coalescer_2026-07-27.md`). Enabling it
exposed two genuine bugs (core `d8855c98`):

1. **Double response → SIGSEGV.** `CoalGroup::ports` can list the same port index twice
   (`ports.push_back(a.port)` is unconditional) because the coalescer's input index is the PORT
   CLASS — two cores/tiles hitting the same 16 B part on the same lane in the same cycle land in ONE
   group with a duplicated index. The member-matching loop set `p.done` only AFTER the whole loop, so
   both iterations re-found the SAME parked request → one `IoReq*` twice in `grp.members` →
   responded twice → `arg_pop` on empty in `AraVlsu`. Fix: claim each match immediately; plus a
   permanent duplicate-member guard. (Same family as the July `c05b9450` fix, one level deeper.)
2. **Sub-word write corruption.** The merge copies `word_bytes` from the request buffer to
   `word_index*word_bytes`, honouring neither the in-word byte offset nor the request size — a
   1/2-byte store over-read its buffer and clobbered neighbouring bytes. byte-enable produced **29
   FAIL lines** the moment the coalescer went live. Fix: sub-word writes bypass the window (the RTL
   coalescer merges the lanes' 32-bit word accesses).

**RTL check that mattered:** `NumPorts-1` / "Only spatz vlsu goes through coalescer" — the RTL
coalescer sits inside the per-bank ctrl downstream of the xbar, so merging across *different cores*
is faithful, not a modelling error. Our placement is right.

**16-core sweep with the coalescer active (9/9 data-correct, 0 fails):** fdotp_M32768
56,001→**49,001** (+16.2% → **+1.6%** vs RTL) · load-store 183,001→**154,001** (+80.8% → **+52.2%**)
· fft 62,001→51,937 · linked-list 680,001→673,001 · byte-enable 225,001 and spin-lock 76,628
unchanged (their traffic doesn't merge). Two kernels overshoot: gemv 62,001→**49,878** (+9.8% →
**−11.6%**) and fmatmul 51,001→**44,001** (−10.0% → **−22.4%**) — the merge is real, so what it
reveals is that other gaps (no forwarding buffer, simplified xbar arbitration) were previously
*offsetting* the missing merge. Net: the biggest outlier moved decisively toward RTL and the
vector-compute pair now needs the next fidelity item rather than a missing structure.
Enabled on both paths via `CACHEPOOL_CELL_COALESCER` (default 1) — A/B still available.

---

**STATUS 2026-08-10 (cachepool_v3 P0 — structural cache in a multi-group shell; R1+R2 green):**
new target `cachepool_v3` = v1's calibrated structural InSitu cache inside a v2-style multi-group
shell (pulp `3a57ebc` + `9fb96dd`). v2 untouched. Hierarchy: tile = cores + L1 I$ + private stacks +
this tile's cache slice (5 per-port-class xbars, per-bank AMO, per-cycle cores); group = tiles +
per-port-class remote xbars; cluster = X×Y groups with separate narrow/wide egress per group so the
L1 mesh (P1) and L2 mesh (P4) attach without re-plumbing. **P2 came free**: v3 uses v1's
`ClusterRegisters` peripheral, which already carries the L1D partition/flush block + the >32-core
counting barrier — wired the flush fan-out (one master per bank) and the config broadcast
(nb_config endpoints, asserted against the wiring count).
**Four boot-contract bugs found during bring-up, all from v2 and v1 answering DIFFERENT software
contracts:** (a) v2's peripheral map (barrier 0x00, EOC 0x14) vs the CI binaries' snRuntime map
(barrier 0x10, BOOT_CONTROL 0x20, EOC 0x24) — running these binaries on v2's map silently makes the
barrier a no-op (the read lands on BOOT_CONTROL) and drops the EOC write, so the sim never ends;
(b) cores must RESET into the bootrom (`boot_addr=0x1000`, `fetch_enable=False`) — v2 pushes the
entry over a `bootaddr` wire instead, so boot_addr defaulted to 0 and every core fetched from 0;
(c) the wake must be MSIP not MEIP (the bootrom WFIs with `mie=0xF` = MSIE); (d) the per-core
peripheral port needs `rm_base` (the barrier needs per-core identity via `i_CORE_INPUT`, and the
peripheral expects offsets — absolute addresses give "Accessing invalid register 0xc0000020").
**R1** (1 group × 1 tile × 4 cores): fdotp_M8192 retval=0, EOC 66,214, per-bank counters live.
**R2** (1 group × 4 tiles × 4 cores = 16): fdotp_M8192 47,196 · fmatmul 94,225 · fdotp_M32768
70,438 — all retval=0, zero fails, cross-tile shared L1 exercised.
**Two calibration findings from the v1-vs-v3 diff:** (1) `cell_coalescer` must stay OFF to match v1
— the factory default is False and v1's group path never sets it, so **the ±4% RLC calibration was
achieved WITHOUT the coalescer**; enabling it also segfaults in the 4-tile context
(`split_and_resp` → `AraVlsu::data_response`), a latent bug the single-tile calib path never
exercises (tracked, do not enable before fixing). (2) The remaining cycle gap is the **per-tile
icache**, not the data cache: kernel-internal cycles fdotp 1,236→1,310 (+6%), fmatmul
1,900→2,679 (+41%); an A/B with one icache shared by all 16 cores (v1's arrangement, same total L1
data capacity) brings fmatmul internal to **1,780** and EOC to **44,190** — below v1. So v1's single
shared icache flatters instruction-heavy kernels; v3's per-tile L1 I$ is the RTL-faithful one.
Plan + gates: `prompt/cachepool_v3_implementation_plan_2026-08-10.md`. Next: P1 (L1 mesh, R3).

---

**STATUS 2026-08-06 (RLC large-config sweep COMPLETE + the all-active retry storm found):** the
64/256-core sweep is done and the report is final. Final table: **P4/C8 topology scaling
255,565 (16c) → 239,737 (32c) → 236,394 (64c) → 2,201,761 (256c)** — extra banks help up to 16
tiles, then the single-group remote fabric inverts hard (+832%; the RTL's 256-core is 16 groups
of 4 tiles, so ours is the pessimistic bound). **The all-active configs (P16/C48 at 64,
P48/C48 at 256) livelock on the kernel's retry storm** — killed after ~27 h each: SIGINT dumps
show 22.9 G / 34.2 G read hits on one flag line with producers starved (the consumer failed-pop
retry × 48+ consumers × J1's 16-deep polls × per-cell serialization = a three-way amplifier;
the RTL should storm the same way — no all-64-work RTL reference exists yet). Verdict: the
multi-user kernel's scaling ceiling is ~12–16 active cores; all-work ≥64 FAILS any TTI budget
(job can't drain). Kernel-side recommendations recorded (gate failed-pop retry on a nonempty
hint / stripe the descriptor stream). M256 P128/C128 not attempted (same storm; binary built +
registered for anyone who wants it). Report: `prompt/multiuser_llist_sweep_2026-08-05.md` (§6
barrier deadlock + §7 retry storm sidebars). Commits: pulp `b0ef656` + `92f699f` (barrier) +
parent docs. Also: 256-core platform boots + completes correctly end-to-end (256/256 core
prints, zero fails) — the counting barrier holds at 256.

---

**STATUS 2026-08-05 (the >32-core barrier hang — found + fixed):** the 64/256-core RLC runs (and a
64-core fdotp probe) sat at 100% CPU for 6+ hours with **zero output of any kind** — not slow,
*deadlocked*. Diagnosis chain: (a) SIGINT dump → every cache bank shows ~zero data traffic
(wr_miss≈1/bank = the cores' boot stack writes, then nothing) → the program never reached its
first data phase; (b) one bank (`tile_7/ctrl_0`) shows **rd_hit=19.5 billion** — 256 cores
spinning a single cached line = the bootrom park flag, never released; (c) the culprit is the
peripheral counting barrier (`cluster_registers.cpp`): `vp::reg_32 barrier_status` (32-bit!),
`1 << core_access` (UB at ≥32), and the completion mask `(1ULL << nb_cores) - 1` — **`1ULL << 64`
is UB (=1 on x86) → mask 0 → the barrier never completes at NB_CORE=64/256**; every core parks
IO_REQ_PENDING forever. Explains the exact boundary: 8×4=32 cores works (`1ULL<<32` fine), 16×4=64
hangs. **Fix round 1** (pulp `b0ef656`): widened the barrier state to 64-bit + `core_mask()` —
64-core fdotp went from 6+ h stuck to **3.2 s**; 16-core P2/C2 byte-identical (954,001). **But
256 cores then SIGSEGV'd** in `hw_barrier_req`: 64-bit state still overflows at NB_CORE=256 —
`1ULL << id` aliases at ≥64 → the mask completed early AND parked cores were lost → NULL
`waiting_reqs` deref. **Fix round 2 (final): the RTL-faithful COUNTING barrier** — arrival count
in the debug reg, completion = count == nb_cores, respond to all parked (non-null) reqs; no
bitmask anywhere in the logic (clint IPI registers stay 32-bit — >32-hart clint noted as a
limitation, unused by the suite). Also notable: the wall-clock "cliff" was never a scaling
problem — the engine was spinning stalled cores; post-fix the 64-core run is minutes, not hours.
The 64/256-core RLC sweep re-launched; results land in `prompt/multiuser_llist_sweep_2026-08-05.md`.

---

**STATUS 2026-08-05 (RLC large-config sweep — interim: 16/32-core + throughput/TTI framework):**
the user-requested larger-config RLC sweep is underway. **New SW configs** (RTL repo
`ManyRVData_rebase`, uncommitted working-tree edits — documented in the sweep report):
`tests/CMakeLists.txt` gains 3 `add_spatz_test_rlc` variants — P16/C48 (all-64-work),
P48/C48 (M48 ceiling, 96 active), M256 P128/C128 (all-256-work) — plus
`script/pdcp_pkg_256_800_300.json` + generated `data/data_256_800_300.h` (same 300 pkgs /
243 kB wire bytes as TC2). **16-core reference table re-run at the post-J1 model state** (all
rc=0, 0 fails): P2/C2 954,001 (work 550,721), P2/C8 919,001 (514,686), P4/C4 710,001 (306,523),
P4/C8 659,001 (255,565) — ≲2% above the 07-27 numbers (J1 backpressure). **32-core (8×4) P4/C8:
690,001, work 239,737 (−6% vs 16c — more banks spread the list contention).** 64-core (16×4)
P4/C8 + P16/C48 and 256-core (64×4) P48/C48 + P128/C128 are running in background (healthy,
ISS-confirmed advancing; wall-clock scales steeply — the 32-core took ~8 min, the 64-core runs
are >2 h: per-cycle component ticks ×16 tiles + idle-core barrier-spin instruction stream; a
monitor fills the table on completion). **Throughput/TTI framework** (the user's actual ask):
payload = 300 pkgs × 810 B = 243,000 B; requirement = 7 MB/s aggregate at 1 GHz + 1 ms TTI (job
= 34.7 TTIs at the required rate). Every completed config lands **60–145× above the required
throughput** and finishes in ≪1 TTI — the HW is not the binding constraint (the SW pacing loop
is, and it's off by default). README §5 reference table refreshed to the post-J1 numbers.
Report: `prompt/multiuser_llist_sweep_2026-08-05.md` (supersedes the 07-27 table).

---

**STATUS 2026-08-05 (J1 scalar-LSU depth + a real ISS AMO bug it exposed):** brought the scalar
LSU outstanding depth to the RTL value — `snitch_max_trans=16` (`cachepool_fpu_512.mk:87`) vs the
ISS default 1. Scoping: the plumbing already existed (scoreboard always on; the
`NB_OUTSTANDING` machinery is production code used elsewhere at depth 8), so the intended change
was one line (`snitch_cluster.py`: `nb_outstanding=16` for cachepool targets only — gated on
`arch.cachepool_num_tiles`; env `CACHEPOOL_LSU_OUTSTANDING`, build-time like the other knobs).
**The 16-core sweep then exposed a real ISS bug:** spin-lock blew up 76.8k → 1.62M (data still
correct) with the AMO shims processing 43,170 RMWs (norm ~3.3k) — the sync-OK branch of
`Lsu::atomic()` under `NB_OUTSTANDING` freed the slot after the AMO latency but never marked the
destination register pending, so a result-consuming spin loop (`amoswap/bnez`) free-ran at
16-deep poll rate and flooded the lock bank (the RTL Snitch blocks on the AMO response). Fix:
`scoreboard_reg_set_timestamp(reg_out, latency+1)` in that branch (composes with the slot-busy
window; relative + max-combining). Post-fix spin-lock 76,628 (+12.1% ≈ pre-J1), RMWs 3,267.
**Sweep (all 9 data-correct):** fmatmul −18.9%→**−10.0%**, fdotp_M8192 −16.2%→**−13.0%**,
linked-list −27.4% (937k→680k; still 3.7× — loader+drain), fdotp_M32768 +17.1→+16.2%, gemv
+8.8→+9.8%, byte-enable unchanged, spin-lock ≈unchanged; **fft + load-store flat → the J1
hypothesis is REFUTED for them** (fft's scalar-phase residual is instruction-issue-side, not
memory-depth; load-store stays with flush-gating/hash-way/scalar-check terms per the E3.6
decomposition). The AMO stall-on-use gap is upstreamable (any nb>1 core + AMO spin loops hits
it). Report: `prompt/cachepool_j1_lsu_outstanding_2026-08-05.md`. Commits: core (lsu.cpp) + pulp
(snitch_cluster.py) + parent docs below.

---

**STATUS 2026-08-04 (E3.6 — partition-aware load-store kernel validated against RTL):** the one CI
kernel that actually drives runtime partitioning (`load-store_M16`, Diyou Shen 2026, Parts 1–3)
now has a complete E3 sign-off. Bring-up finding: the prebuilt binary (May-18, rebase_ori) already
contains Parts 1–3 (it's what the sweeps always ran) — nothing to port. **Functional: all 7
sub-tests PASS** (5 partition modes + private-flush isolation + shared-flush isolation), exactly
matching the RTL's verdicts in the May-29 sweep log (`sweep_2026-05-29_05-54/cachepool_4t_fpu_512/
logs/load-store_M16.log`, `[EOC] 101208000` ps = **101,208** cyc, retval=0). **Counter-level
isolation proof (exact, zero free parameters):** the kernel's flush stream predicts 39 all-class
walks/bank + 4 private-only + 2 shared-only → private banks (ctrl_0/1) flush=**43**, shared
(ctrl_2/3) flush=**41** — measured exactly that; class-selective flush (E3.1) banks outside the
target class skip the walk entirely. The accounting only closes against the **older** runtime: the
rebase tree's Jul-28 rebuild adds one `l1d_flush()` inside `l1d_xbar_config` (7 call sites → +7
walks ≈ +2–3k cycles) — documented in the report for anyone rebuilding fresh. **Cycle diff:
183,757 vs RTL 101,208 = +81.6%** (trajectory: +459.8% v1 loader artifact → +4.9% v2 → +53.1% v3
→ +81.6% post-E3 — the partition now engages, costing flushes + hash-way-collapsed associativity
that v3 measured as no-ops). Decomposition: flush gating ~11–15k (39 walks/bank), miss path
(rd_miss=2,902, 87% hits) through the serialized refill fabric + the RTL-faithful hash-way
collapse (RTL's unmodeled forwarding buffer absorbs part), and the J1 scalar-check serialization
(core-0 `check_const` while 15 cores barrier-wait). No single dominant term; named follow-ups (J1,
forwarding buffer) tracked in the structure map. Report:
`prompt/cachepool_e3_6_loadstore_kernel_2026-08-04.md`. E3 ladder complete: E3.0–E3.6 done;
remaining partition work = RTL re-verification on `05e4671a` + the staged E2 newer-layout block.

---

**STATUS 2026-08-04 (E3.5 calib partition gate — caught a real int32-truncation bug):** added the
mixed-partition calib gate (the cachepool CI kernels only ever run all-shared, so the mixed route
was never exercised). Elaboration-frozen partition knobs `INSITU_CALIB_NUM_TILES`/`_NUM_PRIVATE`/
`_PRIVATE_START` (the TB has no peripheral; RTL short-circuits partitioning at NumTiles==1 so
NUM_TILES=4 is required) + two 2-sweep private-range traces (2048/4096 lines). **First sweep found
a real bug:** `private_start_addr` (0x80000000/0xA0000000) was read via
`js::ConfigObject::get_child_int()` — returns **`int`** (json.cpp:319) — wrapping negative and
sign-extending to `0xFFFFFFFF80000000`, so `is_private` was false for every address and the whole
private range routed to the shared banks (ctrl_0/1 idle; ctrl_2/3 took 512/3584 — the exact
mixed-mode-shared-branch distribution). Invisible in every deployed config (all-private/all-shared
branches never read `private_start`). Fixed with the 64-bit `cfg->get(...)->get_int()` path
(core, see today's commit); scanned the other insitu models — only such address-typed read.
**After the fix, every gate value is mechanism-explained** (m=1..4 × 2 traces): 2048-line
0/0/1024/2048, 4096-line 0/0/2048/4096 — the fold (`addr_bank % num_private`, non-pow2 m=3 puts
half the footprint on bank 0: confirmed via per-bank counters 2048/1024/1024) × the RTL's
**hash-way-only** lookup/allocate (multi-residue banks collapse to ≤2 effective ways/set on
sequential streams — the model now reproduces this RTL quirk instead of reporting naive 4-way
capacity). data_err=0 everywhere (mixed-mode rotation N round-trip data-exact). Regression:
capacity gate 2048/2048; full battery byte-exact (67/10, 67, 0.0143, 67,73,9,73,10,
67×4/10×4/8×4); 16-core fdotp_M32768 smoke 56,484 = E3.3 value (tile.py's explicit
`num_private_cache` pass = the xbar's own default for all existing targets; the fix is inert in
all-shared). **Methodology note:** the structural battery gates run with
`INSITU_CALIB_INLINE_SYNC=1` (calibrated sync-slave); the default async open-loop FSM reports
emergent timing (miss 55, hit 2-3) — fine for hit counting, wrong for absolute-latency gates.
Docs: `prompt/cachepool_e3_5_partition_gate_2026-08-04.md` + new structure map
`prompt/insitu_cache_structure_map_2026-08-04.md`. Files: core
`insitu_cache_xbar.cpp` (fix) + `insitu_cache_tile.py` (partition overrides, explicit
num_private_cache pass); pulp `insitu_cache_calib/__init__.py` (3 env knobs) + `gen_traces.py` +
2 traces. Next: E3.6 (new load-store kernel bring-up with real l1d_part calls + RTL reference).

---

**STATUS 2026-08-04 (E3 runtime partitioning E3.0–E3.3):** the runtime L1 partition config is now LIVE
in the structural path (E3.0 overflow fix pulp `2f36120` · E3.1 setters + class-selective flush core
`f6cbfade` + insn-routing fix pulp `3bf960f` · E3.2 config broadcast core `3ec397bb` · E3.3 commit
semantics pulp `f7d0651` · parent `ecc40cd`). The kernels' `l1d_xbar_config` / `l1d_part` / private
flush now take effect (were no-ops). Key discoveries along the way: (a) `cp_l1d[16]` overrun (a REAL
live bug, every newer-block access ≥0x70 corrupting the F1 machinery); (b) `CFG_L1D_INSN @0x2c` was
swallowed by the perf-scratch range (flush insn never reached the cache — masked until the flush became
class-selective); (c) **group components are dropped from the build graph unless the build env carries
the group topology** (`CACHEPOOL_NB_TILE>1`) — config-scan defaults to 1 tile → stale remote-xbar lib →
bind failure on the new config port. Verified: calib battery + capacity gate byte-exact; fdotp 55,440
(correct flush charging restored); linked-list 937,001 (default unchanged). Effect of the feature:
fdotp offset=12 +1.9%, gemv offset=7 +8.8% (was accidentally-optimal at offset-6 no-op), load-store
partition +18.6% (partition + private flush now engage) — all data-correct. The contention calibration
under the new routing + RTL-reference re-verification are follow-ups.

---

**STATUS 2026-07-27 (multi-user linked-list sweep + a real bug found):** ran the user's updated
multi-user kernel (M48_N800_K300: 48 UEs, 810 B PDUs, 300 pkgs) across 8 configs — **all pass**
(retval=0, zero ERROR lines). Scaling: producers bottleneck first (2→4 producers: 1.53× at 2×4),
consumers pay off once producers suffice (4→8 at 4×4: +20%), tiles help via more banks (P4C4 2×4→4×4:
+13%; P2C2 1×4→4×4: +29%). Best config P4/C8: work phase 250,210 (2.15× the P2/C2 baseline 538,635).
**The sweep exposed a real model bug (fixed, core `c05b9450`):** the coalescer's merge-group member
mapping matched parked reqs by PORT alone — but the port index is the port-CLASS (every core's lane-j
shares it), so one req could be claimed by two groups → double resp() → arg_pop on empty in the VLSU →
SIGSEGV at 4-core. Fixed by matching only unconsumed (!done) requests; coal_merge gate exact, fdotp
unchanged, the 4-core run now passes (1,002,001). Report: `prompt/multiuser_llist_sweep_2026-07-27.md`.

---

**STATUS 2026-07-27 (#24 fft SOLVED):** fft's "2× fast" is **not a compute gap** — the RTL's own kernel
prints show its butterfly compute window is only ~16k of its 130k EOC, and the model's compute matches
within ~6% (8,216+7,212 vs RTL 9,952+5,946, sum −3.0%). The residual (~45k model vs ~114k RTL non-compute)
is the scalar init/validate loops = the J1 scalar-LSU family (the roadmap's top issue-side item). The
stride/bank-conflict hypothesis is DEAD — the model's bank distribution is fine. Added `[ARA-STATS]`
per-core issue-side counters (vlsu loads/stores/bursts, vfpu insns/busy) dumped at sim stop — **trap: the
cachepool cores are SnitchFast (`snitch_fast/snitch.cpp` IssWrapper), NOT the generic `iss.cpp` wrapper —
editing `iss.cpp` compiles cleanly but is dead for this target** (cost me one full debug round). Also:
the ISA-variant gen libs can rebuild with one stale object — verify print strings with `strings` when a
fprintf "doesn't fire". Doc: `prompt/cachepool_fft_anomaly_resolved_2026-07-27.md`.

---

**STATUS 2026-07-27 (S1 — issue-side VLSU geometry):** the model's VLSU was 2× too wide (lane_width=8 →
32 B/cycle vs RTL's 16 B/cycle at 32b/lane, SpatzDataWidth) with 8 outstanding vs RTL's 32. Fixed to the
RTL values (pulp `23b655a`, env A/B knobs). **gemv +1.0%**, byte-enable −5.4%, fmatmul −9.0%, fdotp_M8192
−13.5%, fdotp_M32768 +15.0% (on correct hardware; residual = issue-depth/burst shape), spin-lock +12.3%,
fft −53.2% (separate cause: stride/bank-conflict fidelity — 98% hit, compute-bound; the model's idealized
distribution dodges the RTL's power-of-2-stride bank conflicts). DRAMSys ground-truth run still grinding
in background (its per-transaction wall cost is ~50-100×; will refine ML when it lands).

---

**STATUS 2026-07-27 (R5/P3.1 — the backing-store discovery):** the "model too fast" family's dominant
term was the **0-latency plain backing store** (every miss/eviction/icache-fill ~free). `CACHEPOOL_MEM_LATENCY`
(default 50) prices it: **fdotp_M32768 +5.8%, gemv −4.3%, byte-enable −5.4% vs RTL — within ~6%**; spin-lock
+12.3%; fdotp_M8192 −16.2%, fmatmul −18.9%; load-store overshoots +53% (dependent-miss regime → E3), fft
−54.7% (issue-side, not memory). ALSO: the RTL tb itself backs L2 with DRAMSys (4× DDR4, 1 KiB interleave) —
our `CACHEPOOL_DRAMSYS=1` now routes the whole DRAM range through N DRAMSys channels behind an Interleaver
(+ loader/interleaver DENIED resilience core `bb5ab74b`, mux clock bind; DRAMSys bring-up run in progress —
wall-clock 10-100×). Doc: `prompt/cachepool_rtl_kernel_diff_2026-07-27.md` (v3). Commits: core `bb5ab74b`,
pulp `cb7e40c`.

---

**STATUS 2026-07-27 (R4/F1 DONE):** flush-all implemented end-to-end (core `122c8d33`, pulp `9fa9252`) —
COMMIT (0x38) fans out to all 16 cells; each writes back dirty lines (real evictions, l2-unrotated — data
SURVIVES the flush: fft wrote back 758 lines), invalidates, gates traffic for the walk (277 + 20×dirty,
knobs), FLUSH_STATUS spins on the slowest. fdotp/fft retval=0 (32 flushes each); sweep 9/9. Cycle deltas
bounded (+0.7k fdotp / +1.2k fft / +13.9k load-store — its dirty volume). fft's 2.9×-fast gap confirmed NOT
flush (moved +1.2k only) — it's the issue-side/DRAM family. Next: R5 (the "model too fast" family: issue-side
J1/VLSU geometry + P3.1 DRAM timing).

---

**STATUS 2026-07-27 (R3/B3 DONE):** AMO RMW lane occupancy implemented (core `85011e1b`) — **16-core
spin-lock 69,409 vs RTL 68,368 = +1.5%** (was 2.7× too fast). Key implementation detail: the busy window
must CHAIN (`max(prev,now)+total` — `now+total` lets overlapping windows shrink the serialization). Full
sweep 9/9 data-correct. Documented side effect: linked-list work phase 38k→239k (RTL 70k) — its back-to-back
empty-poll TAS storm (13,265 RMWs) now pays real occupancy; the storm exists because the consumer drains too
fast (the unresolved issue-side gap R5), B3 only prices it. R2/E3 deprioritized (load-store in target).
Next: R4 (F1 flush FSM, fft 2.9× fast).

---

**STATUS 2026-07-27 (R1 SOLVED + fixed):** the linked-list "12× slow" was **100% the ELF-loader artifact**
— ElfLoader segments rode the narrow AXI (bw=8): 16.8 MB `.pdcp_src` → ~2.1M simulated cycles before any
instruction runs (RTL fesvr ≈ 0). Fixed (pulp `5350ae2`: loader → wide_axi bw=64 + catch-all map). The RTL
diff transforms: **load-store +4.9% (IN TARGET)**, everything else model 1.6–2.9× too FAST (the issue-side
family: B3/F1/J1), linked-list's residual is its 262k loader (work phase: model 38k vs RTL 70.5k = 1.85×
fast). Cache fully exonerated by the new latency-budget counters (L1+AMO = 2.3% of the anomaly; core
`9d98fe87`). Full trail + new table: `prompt/cachepool_rtl_kernel_diff_2026-07-27.md` (v2). Next: R3
(B3 AMO occupancy, spin-lock 2.7× fast) → R4 (F1 flush, fft 2.9×) → R5 (issue-side J1/VLSU) → R2 (E3,
deprioritized) → P3.1.

---

## 2026-07-27 (cont'd 2) — R1 SOLVED: the linked-list 12× = ELF-loader bandwidth artifact

**Investigation trail** (each step eliminated a suspect): (1) New stop() latency-budget counters (core
`9d98fe87`): L1 91% hits, ALL L1+AMO latency = 49k of 2.14M cycles (2.3%) → cache exonerated; AMOs are
~2 cyc to the requester (the B3 "too free" gap, opposite direction). (2) Ablations: 16≈8≈2 cores (not
contention); VLSU lanes 4→1 +1% (not the vector path); coalescer on/off identical. (3) libdw-symbolized
instruction trace: cores execute ZERO instructions for the first ~2.1M cycles; the whole kernel runs in
the last ~35k. (4) Kernel's own prints: work phase = 24,132 cycles (2-core); `.pdcp_src` = 16.8 MB ≈
2.1M cycles at 8 B/cyc ⇒ **the ElfLoader over narrow_axi (bw=8)**. RTL loads via fesvr backdoor ≈ 0
cycles → the entire anomaly was a load-time accounting difference. (5) RTL log cross-check: RTL work
phase ≈ 70,480 (16-core).

**Fix (pulp `5350ae2`):** loader → wide_axi (bw=64) + catch-all map for the entry write. Load 8× faster
(16.8 MB: 2.1M → 262k). 9/9 re-verified data-correct.

**The transformed RTL diff (v2, wide loader):** **load-store 106,129 = +4.9% vs RTL (IN TARGET)**;
byte-enable −14.7%; fdotp M32768 −41.9%, M8192 −52.1%, gemv −43.7%, fmatmul −37.7%, spin-lock −63.0%,
fft −65.6% (all model-too-fast); linked-list +105.7% but 262k of it is the loader (work phase 1.85×
fast). **The model is now uniformly too FAST** — the remaining work is the issue-side/occupancy family:
R3 (B3 AMO occupancy, spin-lock 2.7×), R4 (F1 flush, fft 2.9×), R5 (J1 scalar-LSU/VLSU issue geometry),
R2 (E3 partitioning — deprioritized since load-store is in-target), P3.1 (DRAM timing). Also removed a
stray [VLSU-LAT] debug print committed with A1 (hygiene). Docs:
`prompt/cachepool_rtl_kernel_diff_2026-07-27.md` (v2), worklog.

---

**STATUS 2026-07-27 (E4.4 — first RTL kernel diff!):** found RTL QuestaSim [EOC] references in the RTL
repo (`reports/sweep_2026-05-29_05-54/cachepool_4t_fpu_512/logs/`, 1.0 ns clock → cycles=T/1000) and ran
the FIRST per-kernel RTL-vs-model diff (doc: `prompt/cachepool_rtl_kernel_diff_2026-07-27.md`). **gemv
+10.6%, byte-enable −13.8%, fdotp_M32768 +21.4%, fdotp_M8192 −28.2%, fmatmul −32.8%** — and four
gap-mapped outliers: **load-store 5.6× slow (E3 partitioning), spin-lock 2.6× fast (B3 AMO occupancy),
fft 2.4× fast (F1 flush + P3.1 DRAM), linked-list 12× slow (NEW top mystery — smells like a model bug,
not calibration)**. Caveat: RTL sweep is the older `2710920` revision; re-run RTL CI on `05e4671a` for
the definitive reference. Next ladder: R1 linked-list → R2 E3 → R3 B3 → R4 F1 → R5 P3.1.

---

**STATUS 2026-07-27 (E4/P2.13 DONE — the pivotal one):** the full DRAM PMA now goes through the cache
(pulp `661e345`) — the 0xA0000000 bypass (an M32768-bug workaround) is RETIRED. **The M32768 eviction
bug does NOT reproduce** against the P1 cache (A1's delayed commit + D1's PEND semantics removed the
two plausible root causes). All 9 binaries data-correct at 16-core; streaming kernels **45–60% faster**
(fdotp M8192 26,963 / M32768 58,515 / gemv 62,427 / fft 53,514) — the cache now captures cross-iteration
stream reuse. A/B knob `CACHEPOOL_CACHE_ALL_DRAM=0` preserves the old bypass. New dirty-eviction-under-
rotation gate data-exact (2048/2048 vs 0/2048 hits, data_err=0). Doc:
`prompt/cachepool_e4_full_dram_through_cache_2026-07-27.md`. **Kernel tables are now RTL-comparable —
next: RTL [EOC] numbers (E4.4), then E3 (l1d_part) / F1 (flush) as the top remaining kernel-visible gaps.**

---

## 2026-07-27 (cont'd) — E4/P2.13 DONE: full DRAM PMA through the cache; M32768 bug gone

**Goal ladder for this arc (user-requested):** E4.1 reroute+reproduce → E4.2 diagnose/fix bug if it
reproduces → E4.3 full re-validation + kernel tables → E4.4 RTL [EOC] reference numbers (needs user).

**E4.1/E4.2.** Reroute was ~10 lines (`cache_region` → [DRAM_BASE, SPM_BASE); scalar+VLSU maps derive
from it; refills ride wide_axi to the already-mapped `uncached` backing). **The M32768 eviction data
bug does NOT reproduce** — 4-core fdotp_M32768 105,468 retval=0 (bypass: 148,212, −29%); 16-core sweep
9/9 data-correct. Root-cause attribution: A1 (VLSU no longer consumes at issue) + D1 (followers no
longer hit mid-refill lines) each independently closed a real data-corruption path under eviction
pressure — the workaround is retired at the root. A/B `CACHEPOOL_CACHE_ALL_DRAM=0` verified (148,248).

**E4.3.** 16-core sweep with streams cached: **fdotp M8192 26,963 (−44.9%) / M32768 58,515 (−60.3%) /
gemv 62,427 (−59.5%) / fft 53,514 (−51.0%)**; spin-lock/fmatmul/byte-enable/load-store/linked-list
flat. fdotp_M32768 now BELOW the pre-A1 optimistic 87,346 — the full cache stack is both more faithful
and faster (reuse capture + line refills + wide fabric vs the 8 B/cyc narrow link). New
`capacity_dirty_2048` gate: dirty evictions + writebacks under rotation data-exact (2048/2048 vs
0/2048 read-back hits, data_err=0 both). Calib gates untouched (pulp-side change).

**Next:** E4.4 (RTL QuestaSim [EOC] per-kernel numbers — ask user) → then E3 (l1d_part runtime
partitioning; load-store actually calls it) and F1 (flush FSM) as the top remaining kernel-visible gaps.

---

**STATUS 2026-07-27 (P1 COMPLETE):** B1 per-cell serialization + C1 coalescer merge DONE (core `b5832082`,
pulp `5f9c956`) — the shared-L1 contention pair landed together per the sequencing invariant. coal_merge
gate: cold same-part **67,67,67,67** (one refill; B1-only: 67,77,77,77), warm **10,10,10,10** (B1-only:
10,11,12,13), full-part writes **8,8,8,8** w/ correct read-back; isolated gates exact through the coalescer
(67/10, cold_stream 0.0143). 16-core sweep 9/9 data-correct; spin-lock +10.6% (first kernel-visible
contention). Two real bugs found by the gates + fixed: resp loopback on individual forwards (req() →
req_forward) and the D1 clamp's virtual-time install leak (followers serve WITHOUT installing). Doc:
`prompt/cachepool_p1_3_p2_1_cell_serialization_coalescer_2026-07-27.md`. **P1 phase complete (P1.1–P1.5);
next: P2.x (0xA0000000 through the cache is the pivotal one).**

---

## 2026-07-27 — P1.3+P2.1 DONE: B1 per-cell serialization + C1 coalescer merge (P1 phase complete)

**B1 (P1.3).** Sync path resolved every request in-call touching no shared state (up to 20 lookups/cell/
cycle; RTL ≤1). Per-cell accept token (`cell_busy_until_`), all ports shared; D1 clamp waits don't hold
the cell. Single-port isolated gates byte-identical (token never contended).

**C1 (P2.1).** Coalescer reworked to the RTL merge + ENABLED (`cell_coalescer=True` in snitch_cluster,
A/B env knob): 16 B part key (PartSplit=4, not the 64 B line), same-part write merge (full-coverage →
ONE wide write; partial → individual forwards), member latency = wide latency − park→split slip (the
calibrated knobs already contain the coalescer pipeline — the batch window's cycle must not double-
charge), word-guard bypass.

**Bugs found by the gate traces (fixed before commit).** (1) Individual forwards lost responses:
`output_.req()` on a parked req pushed the coalescer's own resp context → upstream resp() looped into
the coalescer's resp_handler and was dropped (writes vanished, watchdog abort) → `req_forward`. (2) D1
clamp installed PEND lines at VIRTUAL time → later same-cycle followers took early hits (67,77,12,13)
→ clamped followers serve from the PEND line WITHOUT installing. (3) Pool-exhaustion double-serve (A2
latent) → mark consumed Pends. (4) **Build-graph trap: `TARGETS="insitu_cache_calib"` alone DROPS the
coalescer gen lib** (gapy components scans the target Python without env vars) and silently stales the
installed .so — always build `insitu_cache_calib cachepool` together.

**Verified.** coal_merge: cold same-part 67×4 (one refill serves 4 lanes), warm 10×4 (merge cancels B1's
per-lane serialization), writes 8×4 + read-back correct; isolated 67/10, cold_stream 0.0143, pend
67,73,9,73,10 — coalescer exactly transparent at the calibrated boundary. B1-alone A/B: 67,77,77,77 /
10,11,12,13 / 8,75,75,75 (the pessimism C1 recovers). 16-core sweep 9/9 data-correct; spin-lock 26,636
(+10.6% — B1 lock contention, first kernel-visible effect); streams flat (0xA0000000 bypass). Doc:
`prompt/cachepool_p1_3_p2_1_cell_serialization_coalescer_2026-07-27.md`.

**P1 phase COMPLETE (P1.1 A1, P1.2 E1, P1.4 D1, P1.5 D2, P1.3 B1, P2.1 C1).** Next per roadmap: P2.x —
**P2.13 (0xA0000000 through the cache) is the pivotal item**: three P1 fixes showed ~0 kernel movement
because the CI streams bypass the L1; routing them through it makes the whole calibrated stack
kernel-visible.

---

**STATUS 2026-07-26 (P1.4+P1.5):** D1 PEND-line ready-cycle clamp + D2 write-miss early ack DONE (core
`f5f7fb3c`, pulp `2a0e34c`) — followers no longer hit early through a refill (73 vs ~10 on the gate), store
misses ack at the RTL winfo latency (8 vs ~67). Calib exact (67/10, cold_stream 0.0143, flat path
byte-identical); 16-core sweep 9/9 data-correct (cycles ~flat — the streams bypass the L1; cache-internal
fixes gate on the calib TB until P2.13). Doc: `prompt/cachepool_p1_4_5_pend_clamp_write_ack_2026-07-26.md`.

---

## 2026-07-26 (cont'd 8) — P1.4+P1.5 DONE: D1 PEND clamp + D2 write-miss early ack

**D1 (P1.4).** Sync-slave miss completed PEND→VALID in-call → same-line followers during the refill window
took 10-cycle hits (~56 cy gift/follower at ML=50; the decode's hit_pend/conflit/all_pend branches were
dead). Fix: lines keep PEND + `WayMeta.ready_cycle`=resp_cycle (data still memcpy'd at allocate); lazy
install sweep pre-decode + bounded clamp loop (hit_pend/hit_conflit/all_pend/PEND-victim) installs as the
in-call wait reaches ready; follower then takes a normal hit (+drain). PEND can no longer be victimized.

**D2 (P1.5).** Store misses stamped ML+17 to the LSU; RTL acks stores from the winfo FIFO at acceptance
(~8, hit or miss). Fix: write hits AND misses ack at new `structural_write_hit_latency_cycles=8`; store
data + functional WT + dirty still applied at allocate; WRITE_PEND + ready_cycle keep subsequent loads
correctly stalled (via D1); + winfo acceptance window (2-cy drain, depth 4). Refill-occupancy gate
unchanged → cold-miss throughput intact.

**Verified.** New `pend_follower` trace (structural calib, BANKS=1, xbar=0): cold miss 67, mid-window
follower **73** (was ~10), write miss **8** (was ~67), read-after-write 73 w/ correct data, post-ready hit
10, data_err=0. Gates exact: warm 67/10, cold 67, cold_stream 0.0143; flat async byte-identical 67/10.
16-core sweep 9/9 data-correct; cycles ~flat (+0.0-0.3%) — **third P1 item with ~0 kernel movement**: the
CI streams bypass the L1 (0xA0000000 `.pdcp_src`; `.dram` empty), so cache-internal fixes gate on the
calib TB; they become kernel-visible with P2.13 (0xA0000000 through the cache) — which is now clearly the
pivotal item for kernel-level calibration. Commits: core `f5f7fb3c`, pulp `2a0e34c`. Doc:
`prompt/cachepool_p1_4_5_pend_clamp_write_ack_2026-07-26.md`.

**Next:** P1.3+P2.1 (per-cell serialization + coalescer merge — the shared-L1 contention pair, biggest
remaining P1 item).

---

**STATUS 2026-07-26 (P1.2):** E1 MSB address rotation DONE (core `6bf12514`, pulp `15739d4`) — the 2^N
per-bank capacity collapse is fixed and proven (capacity A/B on the 4-bank structural tile: sweep-2 hits
0/2048 → 2048/2048, data_err=0; BANKS=1 calib 67/10 exact; 16-core sweep 9/9 data-correct). Kernel cycles
~unchanged — the CI streams live in the uncached `.pdcp_src` @0xA0000000 (bypasses the L1), so E1 becomes
kernel-visible with P2.13. Doc: `prompt/cachepool_p1_2_msb_rotation_2026-07-26.md`.

---

## 2026-07-26 (cont'd 7) — P1.2 DONE: E1 MSB address rotation (capacity collapse fixed + proven)

**The gap.** `enable_rotation=False` hardcode → banks decoded set/tag from raw addresses; BankSel(+TileID)
bits are constant per bank but sit inside the 8-bit set index → 16 KiB (1 tile) / 4 KiB (4 tiles) effective
of 64 KiB/bank. First-order miss-rate corruption, invisible to the single-bank calib TB.

**Fix.** (1) `enable_rotation=True` config default (guarded: dyn_offset==log2(line) required) → the xbar's
existing `route.hpp::rotate_addr` goes live. (2) Core unrotates every L2-side egress via a single
`l2_addr()` helper (`route.hpp::unrotate_addr`, per-bank N from new `rotate_bits/_dyn_offset/_addr_width`
props computed by the tile per `bits_to_rotate`): sync+async refill, dirty-victim writeback, functional
WT, bypass (save/restore). Refill FIFOs + `pending_refill_addr_` stay rotated (install re-decodes).
Rotation happens exactly once (destination tile's xbar; remote xbar never rotates — verified in source).

**Verified.** Capacity A/B (4-bank structural calib, new `capacity_2sweep_2048` trace, 512 lines/bank):
sweep-2 hits **0/2048 → 2048/2048**, data_err=0 both. BANKS=1 67/10 exact (N=0 identity). 4-core fdotp
retval=0 (N=2 all-private branch). 16-core sweep 9/9 data-correct, cycles byte-identical on 8/9
(load-store −0.3% — its node region IS cached; rotation confirmed live via `rotate_bits` in
gvsoc_config.json). **Why ~0 kernel impact:** readelf shows `.pdcp_src` (256 KiB streams) at 0xA0000000
uncached (bypasses the L1), `.dram` EMPTY — nothing cacheable can thrash. E1 pays off at P2.13 (0xA0000000
through the cache); landing it first keeps that A/B clean. Doc:
`prompt/cachepool_p1_2_msb_rotation_2026-07-26.md`. Commits: core `6bf12514`, pulp `15739d4`.

**Next:** P1.4+P1.5 (PEND-line ready-cycle clamp + write-miss early ack).

---

**STATUS 2026-07-26 (P1.1):** A1 VLSU delayed-commit DONE (core `bab9e078`) + the SoC-DRAM bandwidth
divergence it exposed FIXED (pulp `6b7cf09`, width_log2 2→6). All 9 kernel binaries PASS data-correct at
16-core cache-ON with vector traffic now paying the calibrated cache latency; calib TB exact (async 67/10,
structural 67/10 @xbar=0; 68/11 @xbar=1 = the intended step-4 interco hop — new `INSITU_CALIB_XBAR_LAT`
boundary knob, pulp `44ad448`). Doc: `prompt/cachepool_p1_1_vlsu_delayed_commit_2026-07-26.md`.

---

## 2026-07-26 (cont'd 6) — P1.1 DONE: A1 VLSU delayed-commit + the bandwidth bug it exposed

First item of the gap-review roadmap (`prompt/cachepool_architecture_gap_review_2026-07-26.md`).

**The gap.** The Spatz AraVlsu committed every IO_REQ_OK burst to the vreg scoreboard AT ISSUE —
`get_full_latency()` ignored. Through the InSitu cache (which stamps hit/miss latency ON the sync OK
return), all vector loads/stores were ~0-cycle: the calibrated cache latency never reached the scoreboard,
and chained consumers could logically read unwritten elements.

**Fix (core `bab9e078`).** Ported the Ara variant's delayed-burst pattern to the Spatz `AraVlsu`
(`CONFIG_GVSOC_ISS_USE_SPATZ` branch — NOT the `#else` branch, which already had it; first attempt edited
the wrong class, build error caught it): OK bursts with full_latency>0 are held in `delayed_bursts` with
timestamp=now+latency, args left on the req; `fsm_handler` drains ALL eligible per firing (VLSU issues
nb_ports/cyc — a 1/cyc drain would serialize streams) through the existing `data_response` path.
Latency-0 OK keeps the issue-time commit.

**What A1 exposed — the real bug underneath.** First post-fix runs collapsed ~3.5× (fdotp M8192
24k→86k, M32768 94k→279k) with per-burst latency growing unboundedly (39+). NOT the commit logic:
`cachepool.py` had BOTH SoC memories at `width_log2=2` (4 B/cyc) — an 8× under-provision vs the ~32 B/cyc
aggregate VLSU stream, so memory.cpp's `next_packet_start` busy-stamp diverged and `get_full_latency()`
grew without bound. Pre-A1 nobody consumed that latency on the commit path (it only inflated cache-miss
refills), so it went unnoticed. Fix (pulp `6b7cf09`): `width_log2` 2→6 on `mem` AND `uncached` → latencies
bounded (max ~13).

**Verified.** (a) Calib TB exact: async controller 67/10 (warm/cold @ML50, RTL refs 10/67); structural
67/10 @xbar=0 — A1 is ISS-only, provably can't touch the trace-replay TB, confirmed empirically. The
structural 68/11 @xbar=1 is step-4's intended interco hop (RTL standalone TB has no interco); added
`INSITU_CALIB_XBAR_LAT` (pulp `44ad448`) to select the diff boundary. (b) Full 16-core (4×4) cache-ON
sweep, ALL 9 binaries retval=0 + zero FAIL lines (+ spin-lock result 120=gold, byte-enable PASSED):
fdotp_M32768 147,383 (pre-A1 87,346, +69% = the delayed-commit effect), gemv 154,115 (+72%), fft 109,226
(+89%), fdotp_M8192 48,877 — vs load-store 567,257 (−49%), linked-list 2,215,363 (−49%), fmatmul 37,858
(−22%), spin-lock 24,001 (−11%), byte-enable 204,873 (−3%) = the bandwidth-divergence-removal effect
(pre-A1 baselines ran with the divergent memory inflating every refill). Direction mix explained per
kernel in the doc. Full table + analysis: `prompt/cachepool_p1_1_vlsu_delayed_commit_2026-07-26.md`.

**Methodology traps hit (again):** (1) `gvsoc` without the py312 shim on PATH dies on `str | None` —
silently if stdout is redirected, leaving stale CSVs that read as plausible results (cost me one bogus
"68/11 regression" scare: the numbers were from an inconsistent pre-rebuild install state, clean rebuild
reproduces 67/10 exactly); (2) target Python is copied to `install/generators/` at build time
(copy_if_different) — source edits need `make build TARGETS=...`; (3) rm gvsoc_config.json between knob
changes; (4) zsh doesn't word-split unquoted `$VAR` in `env $VARS cmd` (use explicit assignments) and
`echo ===X===` glob-fails.

**Next:** P1.2 (E1 MSB address rotation — per-bank capacity collapse).

---

## 2026-07-26 (cont'd 5) — Calibration steps 1–5 COMPLETE: full-calibration sweep = ALL 8/8 PASS

Step 5 (re-measure with the full calibration, steps 1–4 applied). 16-core (4×4) cache-ON, all 8 CI kernels:
**ALL 8/8 PASS data-correct.** Calibrated 16-core cycles vs pre-calibration baseline: spin-lock 26879 (was
25695), fdotp 87346 (86243), gemv 89481 (88331), fmatmul 48765 (46491), byte-enable 210777 PASSED (196355),
load-store 1108280 (1105531), fft 57934 (57477), linked-list 4312955 (4305314). The calibration report
(`prompt/cachepool_architecture_and_calibration_2026-07-25.md`) is updated with the step-1–4 results + the
final state. Calibration report doc has the runbook + the remaining items (per-kernel RTL cycle diff, cell
coalescer, DRAM-timing refinement).

**CALIBRATION LADDER (steps 1–5) COMPLETE.** All commits local; see the task list + the calibration doc.

---

## 2026-07-26 (cont'd 4) — Calibration step 4 (xbar/hop latency) + step 5 running

**Step 4 (xbar + cross-tile hop latency, was 0).** Read the RTL: `tcdm_cache_interco` has one request-side
`spill_register` per port (response path is a fall-through register = 0), and `cachepool_group` uses AXI
`CUT_ALL_PORTS` (a pipeline cut on every port) — so each xbar / cross-tile hop ≈ 1 cycle on the request path.
The remote xbar is the same module. Added `xbar_latency_cycles` / `hop_latency_cycles` to
InsituCacheTileConfig (default **1**) and passed them to the xbar / remote-xbar instantiations (they were
instantiated with 0). Also fixed a Python gotcha in cachepool.py (`import memory.dramsys` branch-local broke
the else path). Commits: core (xbar/hop wiring), pulp `7edfa38` (import fix), parent `2b54472`.
**Verified: 4-core single tile fdotp 93552 (was 92867, +685 xbar hops); 16-core group spin-lock 26879 result
120 gold 120 (was 25695, +1184 cross-tile hops) — both data-correct.**

**Step 5 running:** full-calibration 16-core (4×4) kernel sweep with steps 1–4 all applied.

---

## 2026-07-26 (cont'd 3) — DRAMSys kernel-crash ROOT CAUSE + FIX (the icache DENIED bug)

The vendored-DRAMSys SystemC segfault (`Cache::refill_response` ← `ddr::rspCallback` ← `peqCallback` ←
`sc_simcontext::simulate`) was NOT a DRAMSys-library bug — it was a **cache_impl (the standard GVSoC cache,
used by the icache's Hierarchical L0/L1 banks) async-refill accounting bug**, exposed only by DRAMSys.

Root cause (trace-driven): with plain `memory.Memory`, refills return `IO_REQ_OK` synchronously, so
`Cache::refill_response` is never called asynchronously. DRAMSys instead returns `IO_REQ_PENDING` and responds
asynchronously, AND under load it returns **`IO_REQ_DENIED`** (busy → queues the request in `denied_req_queue`
and retries it later via `reqCallback` → `grant` + `paraSendRequest` → responds). `cache_impl::refill()`
handled only `IO_REQ_OK`/`IO_REQ_PENDING`; on `IO_REQ_DENIED` it returned NULL with **no parked user request
and no `pending_refill`**. The denied refill was still queued + retried + responded by DRAMSys, and
`Cache::refill_response` then fired with an EMPTY `refill_pending_reqs` → `pop()` on an empty queue (vp_assert
is a no-op in Release) → segfault. Proven by the diag trail: a `[DDR-RESP]` for `0x1460` with NO corresponding
`[REFILL_ISSUE]` — the DENIED request retried later.

**Fix (core, cache_impl.cpp):** treat `IO_REQ_DENIED` exactly like `IO_REQ_PENDING` (park the user request +
set `pending_refill`); DRAMSys then retries + responds and the accounting stays correct. **Verified:
fdotp_M8192 cache-ON with DRAMSys DDR4 backing now COMPLETES (`retval=0 cycles=28001`)**, refill queue stays
healthy. Diagnostics removed; only the fix remains.

This was the last blocker for the realistic-DRAM calibration step. The runtime recipe (LD_PRELOAD of the
rebuilt SystemC 3.0.1 + DRAMSys libs + `gvsoc_launcher_sc`) is documented in `cachepool.py` and the earlier
WORKLOG entry.

---

## 2026-07-26 (cont'd 2) — DRAMSys debug: root causes found, one vendored kernel-crash open

Debugging the DRAMSys integration (step 3). Chain of root causes, each verified:

1. **v1 wrapper abort at elaboration**: `install/models/memory/dramsys.so: undefined symbol
   sc_core::sc_api_version_3_0_1_cxx201703L...sc_writer_policy` at dlopen. The symbol IS in the SystemC lib,
   but **`dramsys.so` and `gvsoc_launcher` don't link SystemC** (no libsystemc in NEEDED), so it must come
   from the process's global namespace. **Fix: `LD_PRELOAD .../libsystemc.so.3.0.1`** → elaboration passes,
   DRAM instantiates ("DRAM id is: 0").
2. **Wrong DRAMSys lib**: the prebuilt `add_dramsyslib_patches/libDRAMSys_Simulator.so` needs
   **libsystemc.so.2.3** (SystemC 2.3); we built 3.0.1. Use the freshly-rebuilt
   `.../build_dynlib_from_github_dramsys5/DRAMSys/build/lib/libDRAMSys_Simulator.so`.
3. **Launcher**: plain `install/bin/gvsoc_launcher` instantiates but **hangs** (SystemC kernel not driven);
   **`install/bin/gvsoc_launcher_sc`** (built by the SC-enabled build) drives it.
4. **v2 wrapper**: rejects the loader's write — it is beat-form only (size>beat_width → fatal; needs
   burst_id/is_last) and our masters are legacy `io`, not io_v2, so the beat adapter doesn't engage. v1
   (plain-io) is the natural fit.
5. **OPEN (vendored)**: with preload + SC launcher, the vendored DRAMSys SystemC model **segfaults inside
   `sc_core::sc_simcontext::simulate`** (from sc_main) — a genuine third-party-library crash, no debug
   symbols. Configs all present (addressmapping/simconfig/memspec OK). Next step = build DRAMSys with debug
   info to localize the crash in its SystemC processes.

Committed: pulp `4e42434` (v1 wiring + the runtime recipe in a comment), parent `c82981b`. The default
(plain-memory) path is unchanged. Steps 1–2 (cache latency model) calibrated + committed, unaffected.
Steps 4 (xbar/hop latency) + 5 (re-measure) remain; realistic-DRAM is gated on the kernel-crash debug.

---

## 2026-07-26 (cont'd) — Calibration step 3 (DRAMSys): infra + wiring done, vendored-model issue open

**Infra:** ran `make dramsys_preparation` (sourceme_systemc.sh) — SystemC 3.0.1 built into
`third_party/systemc_install/`, `libDRAMSys_Simulator.so` rebuilt from source (prebuilt self-test failed),
configs copied to `core/models/memory/dramsys_configs/` (incl. `ddr4-example.json`).

**Wiring (pulp `2b98759`):** `CACHEPOOL_DRAMSYS=1` routes the cached-DRAM backing store through DRAMSys
(`memory.dramsys.Dramsys`, `CACHEPOOL_DRAM_TYPE`, default `ddr4-example.json`) instead of plain
fixed-latency `memory.Memory`. Gated off by default (fast functional path unchanged). Uses the v2 wrapper.

**OPEN ISSUE (vendored, not our cache):** the **v1 wrapper segfaults at sim start** in this tree; the **v2
wrapper elaborates + instantiates (DRAM id 0) but rejects the loader's DRAM write at 0x80000000** ("Received
error during copy", exitcode 1) — a vendored-wrapper integration issue (capacity/address-range or beat
protocol). Next debug: check the ddr4-example.json capacity/address map vs our rebased HBM addresses, and the
v2 beat adapter for the loader's large (0x3960 B) writes. Steps 1–2 (the cache's own latency model) are
calibrated + committed and unaffected. Steps 4 (xbar/hop latency) + 5 (re-measure) remain.

---

## 2026-07-26 — Calibration, steps 1–2 DONE (sync-slave hit/miss knobs + refill-occupancy)

Following the calibration order from `prompt/cachepool_architecture_and_calibration_2026-07-25.md`.

**Step 1 (core `a850fbe7`) — sync-slave hit/miss knobs vs RTL.** Baseline on the calib TB (structural tile +
inline sync, STRUCT_BANKS=1): warm hit 9 (RTL 10), cold miss ML+12 (RTL ML+17) — exactly the documented gap.
The shared knob keys (hit_latency_cycles=9 / miss_penalty_cycles=7) belong to the async controller's
interco(1)+drain decomposition, so the sync-slave path got its own overrides:
`structural_hit_latency_cycles=10`, `structural_miss_penalty_cycles=12` (fallback -1 → shared keys), set in
make_cachepool_512_config (inherited by the group factory). KEY GOTCHA (again): the C++ reads component
**properties** via get_child_int, not the config object — the new keys had to be added to
`insitu_cache_core.py`'s `add_properties`, and `gvsoc_config.json` must be deleted before re-measuring (stale
config zeroed the knobs the first time). Measured: warm hit 10 ✓, cold miss 67 @ML=50 / 117 @ML=100 ✓
(ML+17 + ML-scaling). The controller's own calibration untouched.

**Step 2 (core `e2aeb60a`) — refill-occupancy gate for cold-miss throughput.** Baseline: cold_stream
throughput 0.0188 @ML=50 (RTL ~0.0149) — 26% too fast: the inline miss path overlapped the +pipeline
(bank_write+miss_penalty) with the next refill's memory latency (misses serialized only on ML via the calib
mem's busy-gate; the cachepool backing memory.cpp doesn't serialize at all). Fix: per-cell refill-occupancy
gate — each refill issues no earlier than the previous line's ready cycle (`sync_refill_busy_until_`), the
request stamped (issue + ML_nominal + bank_write + miss_penalty) with the store's UNGATED latency (ml_nominal,
min full_latency), plus `structural_install_tail_cycles=3` (the RTL install-pipeline tail, added to the
occupancy only, NOT the reported latency, so isolated ML+17 is unchanged). Measured: cold_stream 0.0143 @ML=50
(RTL 0.0149, was 0.0188), 0.0083 @ML=100 (RTL 0.0085); isolated cold-miss 67 / warm hit 10 unchanged.
Learnings: the mem's own ML-gate dominates any naive model gate (double-counting); the right mechanism is
gating the refill ISSUE on the previous line's ready cycle + using the store's nominal (not gated) latency.

**Next:** step 3 (DRAMSys behind the SoC DRAM — infra setup running), step 4 (xbar/remote-xbar hop latency,
currently 0), step 5 (re-measure kernel tables).

---

## 2026-07-25 (cont'd 6) — #4 DONE: **ALL 8/8 CI kernels PASS cache-ON at the full 16-core CachePool** 🎉

16-core (4 tiles × 4), cache ON, 380s each: **spin-lock 25695 (`result: 120; gold: 120` = Σ0..15 ✓) · fdotp
86243 · gemv 88331 · fmatmul 46491 · byte-enable 196355 PASSED · load-store_M16 1105531 · fft 57477 retval=0
(passes at the full config — its 4-core failure was purely the core-count partition mismatch) · linked-list
4305314.** The multi-tile cache (cross-tile remote xbars + per-tile AMO) is **data-correct across the full
CachePool**. 4-core stays 7/8 (fft only, partition). Milestone 3 of the north-star (cache in the data path,
data-correct) is CLOSED. Remaining: milestone 5 cycle calibration vs RTL; fft at non-16 counts (partitionable
SPM). Docs updated (run guide status banner, integration report final results).

**GOAL LADDER COMPLETE:** #1 sweep ✅ → #2 spin-lock (AMO second_data) ✅ → #3 hygiene ×4 ✅ → #4 16-core +
docs ✅.

---

## 2026-07-25 (cont'd 5) — #3 DONE: four hygiene fixes (core `19a1797d`, parent `cc10cca`)

From the DiyouS-work review + follow-up analysis:
1. **fpu_lsu.cpp build break** (his `a02a541d`): `stall_callback` used the single-outstanding form
   unconditionally; with `CONFIG_GVSOC_ISS_LSU_NB_OUTSTANDING` it's an ARRAY (lsu.hpp:137) → compile error on
   nb_outstanding>1 targets. Guarded both sites (index by the arg-0 req id, same convention as
   `load_float_resume`). **Verified: snitch_testbench builds.**
2. **refill_busy_ leak** (his `68503b61`, controller): the unmatched-response early return skipped
   `refill_busy_ = false` → one stray response latched the refill slot forever (hard deadlock). Now releases
   the slot + continues the wait queue on that path too.
3. **Never-filled-line-VALID** (our `insitu_cache_core.cpp` miss fallback): a non-OK refill served the
   requester from the never-filled line (stale/zero bytes) and marked it VALID → silent permanent garbage.
   Now: revert the allocation, serve directly from the backing store, line stays unallocated (later access
   retries the refill).
4. **DENIED-drop** (structural core async accept path): accept-queue-full returned DENIED + dropped the
   request — an async-capable master (the now-async Spatz VLSU) would wait forever for a resp() that never
   comes. Now parks in a new `admission_stall_q_` (PENDING) and re-admits in stage0_arbitrate as space frees.
Verified: cachepool + cachepool_v2 + snitch_testbench all build; spin-lock/byte-enable/fdotp cache-ON still
pass. This closes the async-Spatz↔cache compatibility gap flagged earlier (alongside the already-landed
controller-side hold/retry).

---

## 2026-07-25 (cont'd 4) — #2 VERIFIED: full cache-ON sweep = **7 of 8 kernels PASS**

With the AMO second_data fix + per-core SPM, all 8 CI kernels cache-ON at 4-core (300s each):
**spin-lock 10853 (result:6 gold:6) ✅ · load-store_M16 1086770 ✅ · fdotp 92867 ✅ · gemv 95262 ✅ ·
fmatmul 30893 ✅ · linked-list 4249663 ✅ (was "needs CL_CLINT" — the never-blocking barrier + visibility
were the real blockers!) · byte-enable 196001 PASSED ✅** · fft EOC retval=1 (59272, "Error: r:1024,i:1024"
— the known 4-vs-16-core partition issue, reaches EOC cleanly, not a hang; a milestone-4 partitionable-SPM
item). **The complete cache-in-the-loop model now runs 7/8 CI kernels data-correct at 4-core.**

---

## 2026-07-25 (cont'd 3) — #2 CLOSED: spin-lock root cause = AMO result written to the wrong IoReq buffer

**The spin-lock livelock, root-caused end-to-end** (trace chain): all spinning cores in the mcycle backoff
loop in perfect lockstep; the lock cell's stored values correct; yet no core ever acquired. The break came
from comparing the AMO operand conventions: the ISS (`lsu.cpp:547-549`) sends the AMO operand in
`req->get_data()` and delivers the **result via `req->get_second_data()`** (aliases rd); `memory.cpp`'s
`handle_atomic` honours exactly that. **Our AMO shim wrote the old value to `get_data()` and never touched
`get_second_data()`** → the core's rd kept stale garbage → `beqz/bnez` acquire check meaningless → live-lock
(cache-OFF unaffected since memory.cpp does it right). **Fix (core `dc2e82ca`):** write the AMO old value +
SC result to `get_second_data()`. **Verified: spin-lock cache-ON prints `result: 6; gold: 6`, EOC 10853 cyc**
(was >500M-cycle livelock). This bug lived in our shim since Step 7/A3 and only mattered once `amo_lane` was
enabled in the cachepool target.

**Also in #2: byte-enable fixed by per-core-private SPM** (pulp `9aaa78d`, now the default): the shared-SPM
stack-frame collision (previous entry). Verified byte-enable PASSES (196001 cyc). None of the 8 CI kernels
use snrt_l1alloc (0 symbols) so per-core is safe for the suite.

Commits: core `dc2e82ca` (AMO second_data fix), pulp `9aaa78d` (per-core SPM default), parent `fc69558`
(pointer bump). Full cache-ON sweep with both fixes running next.

---

## 2026-07-25 (cont'd 2) — byte-enable/spin-lock cache-ON hang: ROOT CAUSE = shared-SPM stack collision

**Investigation (#2 of the goal ladder).** byte-enable (scalar-only kernel, 5458 cyc cache-OFF) hangs cache-ON.
Trace chain: (1) all 4 cores take **exception id 1 (instruction access fault)** at ~26.4k cyc and park in
`__snrt_isr`'s `while(1)`; the others hang at the (now-blocking) barrier. (2) The fault is a **`ret` to `0x0`**
— `_vsnprintf`'s epilogue `lw ra, 124(sp)` (0x80002334) returned **0**. (3) All-4-core PA trace of the slot
(PA bffffeb4, SPM window): pe0 `sw ra=80001620` @26062, pe3 `sw ra=80001620` @26128, then **pe3's `printf_`
frame store @26401 clobbers the slot**, pe1's `lw ra` @26406 reads 0. **All 4 cores share ONE SPM instance
(spm_num_groups=NB_TILE=1) with the SAME sp VA → identical physical frame addresses → cross-core frame
corruption.** Cache-ON perturbs timing into the overlap window; cache-OFF stays aligned. NOT a cache bug —
the cache is only the timing trigger (same class as the fdotp barrier bug).

**This vindicates DiyouS's per-core SPM (his 53effd9, which I reverted to NB_TILE during integration based on
the June "per-core breaks shared l1alloc" conclusion — that conclusion now looks wrong for these binaries; the
RTL CachePool SPM is per-core-private).** Tested `CACHEPOOL_SPM_GROUPS=4` (per-core): spin-lock now prints
`Tile0, Core3:hello` (a second core through the lock — progress), byte-enable behavior changed, but NEITHER
completes yet → a SECOND hang remains (under investigation: full 300s observation running).

---

## 2026-07-25 (cont'd) — Post-integration re-verification sweep (#1 of the goal ladder)

**Goal ladder set (user):** #1 full re-verification sweep → #2 spin-lock AMO bug → #3 hygiene fixes
(fpu_lsu #ifdef, refill_busy_ leak, never-filled-line VALID, structural DENIED-hold) → #4 16-core + docs.

**#1 DONE — 8 CI kernels × cache OFF/ON × 4-core** (300s timeout each), post-integration + barrier fix:
- **Cache-OFF 6/8** (no regressions): spin-lock 8710, load-store 1056405, fdotp 78842, gemv 82592, fmatmul
  11978, byte-enable 5458; fft SIGABRT (SPM overflow, known), linked-list rc=1 (CL_CLINT, known). The
  cache-OFF no-output issue from the integration is RESOLVED (was the 0x20/0x24/0x3c fixes).
- **Cache-ON 3/8 pass**: fdotp_M32768 88916 (the fixed bug!), gemv 82741, fmatmul 13396.
  **Clean pattern: the 3 passing kernels are all VECTOR kernels (VLSU lanes); the 3 hanging kernels
  (spin-lock, byte-enable, load-store) are all SCALAR kernels — every access goes through the scalar lane
  → AMO shim.** byte-enable is 5458 cyc cache-OFF → its cache-ON timeout is a REAL hang, not slowness.
  fft cache-ON now reaches EOC retval=1 (59620 cyc, wrong result — the known 4-vs-16 partition issue,
  different from cache-OFF's SIGABRT). Hypothesis for #2: the AMO shim / scalar-lane path, one common bug.

---

## 2026-07-25 — Integrated DiyouS's `cachepool` fork onto our repos + review report

**What/why (user):** "cherry pick or rebase his new commits onto our repos, then review and report."

- **Integration.** His parent `cachepool` (`0acc24d`) descends from our `main` (`f9ebafd`) → **fast-forward**.
  `core` fast-forwarded `4341bbcc`→`d7d6c50f` (7 commits). `pulp`: he **rebased** our branch onto a newer
  upstream base (7/8 of our patches byte-identical by patch-id; the 8th differs only in rebase context), so we
  **adopted his `7c8e758d`** (+11 new commits) — replaying his work onto our older base would conflict.
- **Adaptations.** (1) **engine**: his bump `9033115a` is unpublished (absent upstream; `DiyouS/gvsoc-engine`
  404s) but **required** — his pulp needs `vp/debug_mem.hpp` or `l1_interleaver_impl.cpp` won't compile. Upstream
  `main` is too new (`6c3fb708` drops `vp::MemCheckRequest` used by our `memory.cpp`), so pinned **`ea216770`**.
  (2) `.gitmodules` restored to `Aquaticfuller/*`. (3) `CLAUDE.md` merged (kept his v2 section; restored our
  fork URLs, build env, and the structure-map convention he'd dropped); WORKLOG merged.
- **Commits.** parent `9c19864`, `608638b`, `b58e94e`, `97f5b91`; pulp `3321c02`, `43d1470`. Recovery refs:
  `recovery/main-pre-diyou`, `recovery/insitu-cache-pre-diyou` (core+pulp), `recovery/engine-pre-diyou`.
  **Not pushed.**
- **Regressions found + fixed** (his `53effd9` retargets shared code at the newer `cachepool_fpu_16g` layout,
  our target runs the older `cachepool_fpu_512` binaries): his `offset < 0x30` scratch intercept swallowed
  **`0x20` CLUSTER_BOOT_CONTROL** (cores read 0, jumped to 0, ran 79M+ cycles with no output — the killer);
  EOC moved `0x24`→`0x68` (ours writes 0x24); `spm_num_groups` `NB_TILE`→`NB_CORE` (breaks shared l1alloc).
- **Verification.** Both `cachepool` and `cachepool_v2` **build clean**; `cachepool` 4-core cache-ON
  `fdotp_M8192` → `[EOC] retval=0 cycles=24132` (pre-merge 24242). **Open:** cache-OFF still no output in 200 s;
  8-kernel suite not re-run.
- **Review headline:** his §13.1.2 (**HW_BARRIER never blocked**) + §13.1.1 (**Router.add_mapping dict-key
  collision routing all scalar 0x8000_0000 accesses around the L1**) are very likely **OUR** fdotp bug — a
  barrier/router bug, NOT a cache bug; the router collision also explains our "cache sees only ~40 accesses"
  and identical-cycle observations. His core `68503b61` does **not** fix it (wrong component: our target runs
  the structural `InsituCacheCore`, not `InsituCacheController`). Also found in his work: a **build break** on
  default target `snitch_testbench` (`fpu_lsu.cpp`) and a **latent deadlock** (`refill_busy_` not cleared on the
  early-return path).
- 🎉 **OUR LONGEST-STANDING BUG IS FIXED** (pulp `c20bd51`, parent `d5994cf`). Acting on his §13.1.2 diagnosis:
  the CachePool binaries read HW_BARRIER at **PERIPH+0x10**, but the generated *spatz* regmap (regwidth 64) puts
  `HART_SELECT_0` at 0x10 and **`HW_BARRIER` at 0x40** — so `hw_barrier_req()` was never reached and
  **`snrt_cluster_hw_barrier()` never blocked in ANY cachepool run**. Cores drifted across fdotp's 3 measurement
  iterations (its `vfredusum` never resets `v0`, so each core's acc is 1×/2×/3×) and core 0's `result[]`
  reduction mixed iterations → the timing-sensitive wrong value. Our own comment ("barrier@0x10 already
  match the regmap") was wrong. Fix: dispatch 0x10 → `hw_barrier_req()` + honour `stall_core`. Also restored the
  older-layout L1D block 0x28–0x4c (0x3c reads 0; 0x3c/0x4c were aborting with "Accessing invalid register")
  and fixed a `cp_l1d[16]` index overrun (his 0x58–0xa4 handler reached index 19).
  **NOT a cache bug** — the cache only desymmetrised core timing. **VERIFIED 4-core cache-ON:**
  `fdotp_M32768` **[EOC] retval=0 cyc=88916, no Check Failed** (was Check Failed @88353); `fdotp_M8192` 24305;
  `gemv-opt` 82741; `fmatmul` 13396. **Still open:** `spin-lock` + `byte-enable` hang (spin-lock is a
  *separate* AMO/lock-word visibility bug — `spin_lock.c` has no shared counter, just `result += cid` under the
  lock), and cache-OFF fdotp produced no output in 200 s.
- **Report:** `prompt/diyous_cachepool_integration_review_2026-07-25.md`.

---

## 2026-07-13 — 256-core fdotp/fmatmul livelock: TRUE root cause (undersized `pdcp_mem`), debug cleanup, fork migration

**Status:** committed (`core`, `pulp`) and this entry's own parent commit.

- Root-caused the 256-core livelock (open since the HW_BARRIER fix above) to
  `pulp/pulp/cachepool_v2/cachepool_v2_system.py`'s `pdcp_mem` being sized
  256 MB while the L1 side (`cachepool_v2_tile.py`'s `l1_pdcp` mapping)
  advertises a full 512 MB window — addresses ≥0xb0000000 fell through to
  the SoC router's unmapped catch-all and refills there were rejected
  `IO_REQ_INVALID`, permanently stranding the requesting core's MSHR entry.
  Found via targeted cache-controller-level tracing (`[CACHE_SEND_REFILL
  ... status=1]`). Fixed by widening `pdcp_mem` and its two router mappings
  to 0x20000000 (`pulp` commit `bcd0066`).
- Along the way, investigated and ruled out two other hypotheses (shallow
  router input queues; a FlooNoc self-loop/missing-map bug) via targeted
  experiments — both disproven, reverted. Also found and fixed a real,
  independent latent bug: `InsituCacheController`'s single shared
  `refill_req_` had no concurrency guard against overlapping misses
  (`core` commit `68503b61`, `refill_busy_`/`refill_wait_queue_`) — not the
  cause of this livelock, but worth keeping.
- **Verified** at full 256-core scale: `test-cachepool-fdotp-32b_M32768`
  (`EOC: exit code 0`, all 321 checkpoints `OK`) and
  `test-cachepool-fmatmul-32b_M128_N128_K128` (`EOC: exit code 0`, no
  `FAIL`). Note: `fdotp-32b_M8192` does **not** work at 256 cores — the
  problem size doesn't divide evenly across 256 Spatz-4 cores; use M32768+
  for full-scale runs (now documented in `CLAUDE.md`).
- Stripped all debug `fprintf` instrumentation accumulated across this and
  the preceding investigation rounds (`core` commit `d7d6c50f`, 12 files;
  `pulp` commit `7c8e758`, incl. `BARRIER_HEARTBEAT`/`NOC_DROP`/
  `NOC_ENTRY`/`NOC_DELIVER`).
- Rewrote 5 unpushed `core` commits and 6 unpushed `pulp` commits (message-
  only, verified via empty tree diff) to remove dangling references to
  `prompt/cachepool_v2_architecture.md ... in the parent repo` that don't
  make sense outside this repo.
- **Fork migration**: `core`/`pulp` were pointed at a colleague's fork
  (`Aquaticfuller/gvsoc-{core,pulp}`), which the user doesn't have push
  access to (confirmed via `ssh -T git@github.com` resolving to a different
  GitHub identity). User forked `gvsoc`/`gvsoc-core`/`gvsoc-pulp` to their
  own account (`DiyouS`); added `myfork` remotes and pushed the
  `insitu-cache` branch in both submodules there. Parent `.gitmodules`
  updated to point at the `DiyouS` forks; this commit bumps the `core`/
  `pulp` submodule pointers to match.
- Added to `CLAUDE.md`: hardware/software reference (RTL `dev/multi-group`
  @ `05e4671a6cc355923793893c7be5bc373cbb0dde`, software config
  `cachepool_fpu_16g`), a "Known gaps / not yet implemented" section
  (address scrambling / hash polynomial, cache partitioning, L2 refill
  mesh + DRAM timing, calibration, the incomplete structural cache core),
  and the M8192-doesn't-scale-to-256-cores note above.

**Files touched (parent).** `.gitmodules`, `CLAUDE.md`, `prompt/WORKLOG.md`,
submodule pointers `core` → `d7d6c50f`, `pulp` → `7c8e758`.

**Verification.** Clean rebuild (`make build TARGETS="cachepool_v2"`) from
the fully-committed tree; `test-cachepool-fdotp-32b_M32768` reruns clean
post-cleanup (`EOC: exit code 0`, zero `FAIL`).

---

## 2026-07-09 (cont'd 6) — CachePool v2: TRUE root cause of the fdotp numeric mismatch found and fixed — HW_BARRIER never actually blocked

**Status:** committed (`core`, `pulp` submodules -- full detail in
`prompt/cachepool_v2_architecture.md` §13.1.2). `ManyRVData`-side debug
changes (constant-data generation + printf checkpoints in fdotp's
main.c/gen_data.py) are NOT committed there (separate, read-only-by-
convention repo) -- see that repo's working tree if needed again.

- User proposed a much more powerful debugging technique than continuing to
  guess from random-data mismatches: regenerate fdotp's test data as a
  constant (`A=B=1.0` via a new `FDOTP_CONST` env var in gen_data.py) so
  every intermediate reduction value becomes an exact, known integer, and
  add printf checkpoints in main.c at each reduction stage (per-core
  partial, group-leader sum, final total) that self-report PASS/FAIL.
- First attempt at serializing the resulting 16-way concurrent printf
  output used a spinlock (snrt_mutex_lock) -- this itself introduced a NEW
  30M+-cycle livelock (user had explicitly warned this was a risk before
  trying it). Switched to a lock-free design: each core stashes into a
  private array slot (no contention), only core 0 prints everything
  sequentially afterward.
- Clean data immediately localized the bug: every individual core's own
  partial sum was always exactly correct; exactly 2 of 4 group-leader sums
  were wrong (one with 6x excess, one with 2x deficit), the other 2 exactly
  correct. Correlating already-in-tree `[RESULT_DBG]`/`[LSU_DBG]` traces
  (after fixing their hardcoded address filter, which was watching the
  wrong symbol address for this test's binary size -- separate small fix,
  committed in core) showed a sibling core had already written its
  *iteration-2* value before the group leader even started reading
  iteration 0's value: cores were racing 2 full loop iterations ahead of
  each other across `snrt_cluster_hw_barrier()` calls.
- **Root cause**: `cachepool_v2_cluster_peripheral.cpp`'s REG_HW_BARRIER
  read handler returned `IO_REQ_OK` synchronously on every single call,
  regardless of how many other cores had reached the barrier --
  `snrt_cluster_hw_barrier()` (a single blocking `lw` of this register) was
  a complete no-op from a synchronization standpoint. This is the true root
  cause of the entire fdotp reduction-correctness investigation spanning
  this whole session: it's the one workload here that actually depends on
  barriers enforcing real cross-core ordering, which is also why fmatmul
  never tripped over it.
- **Fixed**: the peripheral now takes a `num_cores` property, parks each
  REG_HW_BARRIER read (`IO_REQ_PENDING`) in a queue, and only responds to
  ALL parked requests at once once `num_cores` reads have arrived -- a real
  counting barrier instead of an immediate per-core response.
- **Verified**: 16-core debug topology, constant-data test -- every
  checkpoint (16 cores + 4 groups + total) now matches its exact expected
  value, and the multi-iteration correctness check passes with zero
  failures. First fully clean pass in this entire investigation.
- **Full 256-core confirmation not yet done**: unrelated tooling issue, not
  a correctness concern -- this session's accumulated unconditional
  per-cycle debug fprintf instrumentation produces too much unflushed
  output at 256 cores (a background run's wrapper process hit 37 GB RSS
  without any of it reaching disk; killed rather than risk OOM). The fix
  has no topology-scale-dependent logic. Recommended: trust the 16-core
  proof, or do a debug-instrumentation cleanup pass first and re-run at
  scale.

---

## 2026-07-09 (cont'd 5) — CachePool v2: found + fixed a router dict-key collision silently routing ALL scalar 0x8000_0000-region accesses around the L1 cache; fdotp result 28% off -> 3.8% off

**Status:** uncommitted (`pulp` submodule; `core`, `engine` untouched this round --
full detail in `prompt/cachepool_v2_architecture.md` §13.1.1).

- Followed up on §13.1's numeric-mismatch item, prompted by the user's hypothesis
  that it's specific to fdotp's cross-core reduction (not a general correctness
  issue, since fmatmul -- no cross-core shared-data dependency -- passes cleanly).
- Traced scalar `fsw`/`flw` dispatch through several dead ends before finding the
  real path: `Sequencer::float_handler` (fpu_sequencer.cpp) intercepts fp_op-tagged
  instructions, and `dladdr()`-resolving its captured handler pointer showed the
  real callee is `core/models/cpu/iss/include/isa/rvf.hpp`'s `fsw_exec`/`flw_exec`
  -> the regular `Lsu` class (lsu_implem.hpp), NOT `FpuLsu`
  (`snitch_fast/fpu_lsu.cpp`) as initially suspected -- that class's pre-existing,
  still-uncommitted async-response WIP from an earlier session turned out to be a
  red herring for this particular bug (real fragility, just not on this code path).
- `Lsu::store_float` completes synchronously (`IO_REQ_OK`) every time, but
  `InsituCacheController::handle_request()` (core) never saw any of these writes.
  Cross-checked against the always-on `[MEM_DBG]` trace: the writes *were*
  landing, but directly at `l2_mem`, bypassing L1 -- a routing bug.
- **Root cause**: `Router.add_mapping()` (`core/models/interco/router.py:161`)
  stores mappings in a plain Python dict keyed by name.
  `cachepool_v2_tile.py`'s per-core `ico` router registered *two* mappings both
  named `'l1'` (one for the `0x8000_0000` region, one for `0xa0000000`) -- the
  second call silently overwrote the first. Every scalar access to the entire
  `0x8000_0000`-`0xA0000000` DRAM region (not just fdotp's `result[]`) had no
  working `l1` mapping and fell through to the `axi` catch-all, bypassing the L1
  cache entirely for the flat L2-refill path. fdotp's reduction is what surfaced
  it because it's the one workload that depends on cross-core L1 visibility of
  scalar writes; fmatmul's vector stores go through a separate port
  (`vlsu_in{k}_{l}` straight to `l1.vlsu_in{k}_{l}`) that never touches this
  router at all.
- **Fixed** (`pulp/cachepool_v2/cachepool_v2_tile.py`): renamed the two mappings
  to `l1_dram`/`l1_pdcp`, both bound to the same `l1.pe_in{core_id}` target (two
  `self.bind()` calls) -- same pattern as the FlooNoc dual-region fix earlier
  today (§13.2.3).
- **Verified**: full 256-core topology fdotp result improved from
  `Calc:452.100891` (28% off `Exp:628.153869`) to `Calc:604.254089` (3.8% off) --
  a large, clear improvement. Router trace confirms all 963 `result[]` writes now
  correctly resolve to `mapping=l1_dram`.
- **Residual, not understood yet**: still not exact (3.8% off), and the 16-core
  debug topology's result was completely unchanged by this fix
  (`Calc:350.577697`, bit-identical to before) -- flagged for next round. Debug
  instrumentation from this investigation (`[RESULT_DBG]` in
  insitu_cache_controller.cpp, `[RESULT_ROUTER_DBG]` in router.cpp, `[LSU_DBG]` in
  lsu.cpp/lsu_implem.hpp, `[SEQ_DBG]` in fpu_sequencer.cpp, `[FPU_LSU_DBG]` in
  fpu_lsu.cpp) all left in the tree, gated/filtered to result[]'s address range,
  ready to re-enable for the next round.

---

## 2026-07-09 (cont'd 4) — CachePool v2: fmatmul reaches EOC AND passes its correctness check on the full 256-core topology

**Status:** doc-only update (no code change).

- Ran `test-cachepool-fmatmul-32b_M32_N32_K32` (§13.2/§13.2.1's original matmul
  repro -- the crash, then the livelock, that kicked off this whole
  investigation) on the full 256-core topology, `timeout 300`.
- **Reaches EOC, exit code 0, no `Core N error` lines** -- the correctness
  check *passes*. 1935-cycle steady-state execution, 529% utilization,
  active cores 8.
- This confirms the matmul crash (§13.2) and livelock (§13.2.1) were
  ultimately the same root cause as fdotp's: the boot-hang bug (§13.2.2)
  and the Ara/AraVlsu completion-signaling bug (§13.2.5). With both fixed,
  matmul now runs correctly end-to-end -- not just "no longer hangs" but
  actually produces the right answer, unlike fdotp which still has the
  separately-tracked §13.1 numeric-mismatch issue in its reduction. Closes
  out §13.2/§13.2.1 as resolved.

---

## 2026-07-09 (cont'd 3) — CachePool v2: confirmed fdotp reaches EOC on the full 256-core topology too

**Status:** doc-only update (no code change).

- Ran `test-cachepool-fdotp-32b_M32768` on the real, default 256-core
  topology (no `CACHEPOOL_V2_*` debug env vars, `timeout 300`) for the
  first time since the §13.2.5 fix. Reaches EOC with no hang, in 250
  simulated cycles (128% utilization) -- far fewer than the 16-core debug
  topology's 6290 cycles, as expected with 16x the parallel work.
- Check still fails: `Calc:452.100891, Exp:628.153869`. This is a
  *different* miscalculated value than both the 16-core debug run
  (`350.577697`) and the pre-boot-hang-fix baseline in §13.1
  (`189.697906`) -- consistent with a genuine, distinct-per-topology
  numerical bug (§13.1), not an artifact of any of today's livelock fixes.
- This is the first time the model has run end-to-end on the real topology
  since the investigation began; re-investigating §13.1's numeric mismatch
  on this topology is the natural next step.

---

## 2026-07-09 (cont'd 2) — CachePool v2: Ara/AraVlsu completion-signaling bug fixed — fdotp reaches EOC for the first time

**Status:** uncommitted (`core` submodule — full detail in
`prompt/cachepool_v2_architecture.md` §13.2.5).

- Root-caused the "puzzling half" bug flagged at the end of §13.2.1 (and
  confirmed as the sole remaining blocker at the end of the previous entry).
  `[VLSU_DBG]` for the specific stuck core showed all 128 of its DENIED
  bursts had genuinely completed (matching RESPONSE lines, last one at
  `nb_pending_bursts_after=0`) thousands of cycles before the eventual
  stall -- so this was never a lost response.
- **Bug**: `AraVlsu::fsm_handler`'s (`core/models/cpu/iss/src/ara/
  spatz_vlsu.cpp`) check for whether the head-of-queue instruction can be
  marked done (and `ara.insn_end()` called) was nested inside
  `if (_this->pending_size) { ... }` -- i.e. it only ran while some other,
  newer instruction happened to still be mid-issue. Once every waiting
  instruction finished issuing (`pending_size` back to 0,
  `nb_waiting_insn==0`), that whole block stopped running, even though the
  head instruction's bursts had long since all completed asynchronously via
  `data_response()`. This permanently stranded the head instruction
  "done in practice, never marked done", head-of-line-blocking `Ara`'s
  global 8-slot queue forever.
- **Fixed**: moved the completion-check block out from under
  `if (_this->pending_size)` so it runs unconditionally every FSM
  invocation (gated only on its own pre-existing conditions). No other
  logic changed.
- **Verified**: rebuilt, reran the same bounded 16-core fdotp run. **The
  simulation reaches EOC for the first time in this entire investigation**
  (5755-cycle steady-state execution, 88% utilization). The result check
  still fails (`Calc:350.577697, Exp:628.153869`), but this is expected --
  the debug topology (16 cores) doesn't match the `Exp` reference value's
  assumed 256-core reduction. Re-running §13.1's numeric-mismatch item on
  the full 256-core topology, and re-verifying `fmatmul` (which very
  plausibly hit the identical bug), are the natural next steps.

---

## 2026-07-09 (cont'd) — CachePool v2: third root cause fixed (L1 NoC address-window aliasing); all memory-response-loss bugs eliminated; livelock now isolated to Ara/AraVlsu completion signaling

**Status:** uncommitted (`core`, `pulp` submodules — full detail in
`prompt/cachepool_v2_architecture.md` §13.2.4).

- Fixed the residual bug flagged at the end of the previous entry: `FlooNoc::get_entry()`
  (`pulp/floonoc/floonoc.cpp`/`.hpp`) only did a plain contiguous `base<=addr<base+size`
  range match, but `L1NocAddressConverter` leaves cacheline "tag" bits (above the
  group_id/bank_offset field) untouched, so incrementing tag by 1 shifts the address by
  exactly `num_groups × noc_size_per_group` — a whole period over every group's window.
  Added an optional `period` field to `Entry`/`get_entry()` (default 0 = old behavior) and
  plumbed it through `floonoc.py`'s `o_NARROW_MAP`; `cachepool_v2_cluster.py` now passes
  `period = nb_groups × noc_size_per_group` on every registered window, so every tag value
  resolves correctly instead of only tag==0. Also fixed a related boundary-clamp underflow
  in `NetworkQueue::enqueue_router_req` that the periodic case exposed (harmless for this
  workload's 4-byte bursts, but wrong in general).
- **Verified**: zero `NO_ENTRY_FOUND` drops (down from 8), simulation progresses further
  still (cycle ~2.76M → ~3.24M before stalling).
- **Conclusively isolated the remaining hang as NOT a memory/NoC bug.** At the new stall
  point, the stuck core's `AraVlsu` (`[VLSU_FSM_DBG]`) shows itself fully idle
  (`nb_waiting_insn=0, pending_size=0x0`) while `Ara`'s global instruction queue
  (`[ARA_DBG]`) is still stuck full (`nb_pending_insn=8`) on a head-of-queue entry that
  never gets marked done. This is the "puzzling half of the picture, not yet resolved"
  noted at the end of §13.2.1 — a desync between `AraVlsu`'s own local completion indices
  and `Ara`'s separate global scoreboard (`Ara::insn_end()` not firing, or firing on the
  wrong entry, for the stuck instruction). With memory-side noise now fully eliminated,
  this is the sole confirmed remaining blocker. Next step: audit `AraVlsu`'s three-index
  bookkeeping (`insn_first`/`insn_first_waiting`/`insn_last`) in `spatz_vlsu.cpp` against
  `Ara::insn_end()`'s call site in `ara.cpp` — see §13.2.4 for the precise pointer.

---

## 2026-07-09 — CachePool v2: two root causes of the "lost VLSU response" livelock found & fixed; residual narrower NoC address-window bug found (open)

**Status:** uncommitted (`core`, `pulp` submodules — full detail in
`prompt/cachepool_v2_architecture.md` §13.2.3).

- Rebuilt + reran `test-cachepool-fdotp-32b_M32768` on the 16-core debug
  topology (bounded via `timeout`, per §13.2.1's log-size gotcha) to confirm
  the §13.2.2 boot-hang fix still holds: cores now reach real program code
  past the bootrom, then hang at the already-documented vfmacc PC.
- Mined the existing (already-in-tree) `[VLSU_DBG]` ISSUE/RESPONSE log for one
  core: found every burst of the very first post-boot vector load returned
  `IO_REQ_DENIED` from cycle ~16457 on, with **zero** matching RESPONSE lines
  ever — that core's `AraVlsu` froze permanently right there.
- **Fix 1** (`core/models/cache/insitu/insitu_cache_controller.cpp`):
  `handle_request()`'s three fifo-full `IO_REQ_DENIED` sites (retr/miss/evic)
  are correct for the open-loop calib driver (which retries) but not for
  `inline_sync_miss_`/cluster mode, where `AraVlsu` treats any DENIED as
  "someone is holding this, ignore it" (true only for the FlooNoc NI's
  DENIED contract) and never retries — silently dropping the request. Added
  `admission_stall_queue_` + `try_admit_stalled()`: in `inline_sync_miss_`
  mode, park the request and return `PENDING` instead of `DENIED`; retry
  admission whenever a fifo slot frees. Verified real but **not** the cause
  of this particular trace (no change to the DENIED-storm log after this fix
  alone).
- **Fix 2** (actual cause of this trace) — `pulp/cachepool_v2/
  cachepool_v2_cluster.py`: added `[NI_DBG]` instrumentation to
  `pulp/floonoc/floonoc_network_interface.cpp` (raw `fprintf`, since
  `--trace=` is unusable at this scale per §13.2.1) and found the FlooNoc's
  `NetworkQueue::enqueue_router_req()` silently drops a burst (`return;`, no
  status, no `resp()` — there's even a dead `// TODO` for the never-
  implemented invalid-response path) whenever `FlooNoc::get_entry()` finds no
  address-range match. Root cause: `L1NocAddressConverter` only rearranges
  the low `constant_bits_lsb+bank_offset_bits+group_id_bits` bits and leaves
  bit 29 (the `0x8000_0000` vs `0xa000_0000` DRAM-region selector) untouched,
  but `cachepool_v2_cluster.py`'s `o_NARROW_MAP` registrations only ever
  covered `0x8000_0000`-based windows — so any cross-group request whose
  address was in `0xa000_0000+` (exactly where fdotp's source data lives)
  never found a routing entry. Fixed by mirroring the same per-group windows
  at `dram_base = 0xa0000000` (distinct `name=` per entry so both windows
  coexist).
- **Verified**: after both fixes, the same run completes its first ever
  DENY→RETRY_READ→FINAL_RESP round trip (previously zero completions in the
  whole run) and progresses ~170× further (cycle ~16464 → ~2.76M) before
  hitting the *already-documented* vfmacc/Ara-queue-full livelock from
  §13.2.1/§13.2.2 — i.e. this round's fixes cleared the earlier blocker;
  that livelock itself is still open.
- **Residual bug found, not fixed**: even with both fixes, 8 more
  `NO_ENTRY_FOUND` drops occurred at addresses whose "tag" bits (above the
  group_id/bank_offset field) are nonzero — the base+size contiguous-window
  match in `FlooNoc::get_entry()` only ever captures tag==0 per group; larger
  offsets either drop (same bug class) or could in principle numerically
  alias into a different group's window. Rare in this workload (8 events in
  ~2.76M cycles) but architecturally real; plausible contributor to whatever
  response-loss remains in the still-open vfmacc livelock. Flagged for next
  round — see §13.2.3's "Residual" note for the proposed fix direction
  (mask-based entry matching instead of contiguous windows).

---

## 2026-07-08/09 — CachePool v2: `pulp` rebased onto upstream/master; permanent-boot-hang root cause found & fixed (wrong Hierarchical_Interco port name); second hang localized to lost VLSU async responses (open)

**Status:** uncommitted (`pulp`, `core`, `engine` submodules — see full detail in
`prompt/cachepool_v2_architecture.md` §13.2.2, not duplicated here).

- Rebased `pulp` (`Aquaticfuller/gvsoc-pulp`) onto `gvsoc/gvsoc-pulp` `master`
  (55 commits, incl. the `SnitchMempool` core originally requested) — clean,
  no conflicts. `core`/`engine` untouched.
- Two pre-existing latent bugs (unrelated to the rebase, just never previously
  exercised) fixed to unblock the rebuild: `Hierarchical_Interco`'s always-
  constructed `Cache` sub-block segfaulting at small elaboration sizes
  (`pulp/mempool/l2_interconnect/hierarchical_interco.py`), and
  `Hierarchical_cache`'s per-tile icache sizing math going fractional/negative
  at `cores_per_tile < 2` (`pulp/mempool/hierarchical_cache.py`, worked around
  not fixed).
- Added a `CACHEPOOL_V2_NB_X_GROUPS`/`_NB_Y_GROUPS`/`_TILES_PER_GROUP`/
  `_CORES_PER_TILE` debug-topology override + bootrom BOOTDATA patcher to
  `cachepool_v2_system.py`, turning an 8+ minute repro into ~15s.
- **Root cause of the long-standing fdotp/matmul "silent hang" found**: every
  core was permanently stuck on the very first bootrom instruction. Traced
  through the ISS decode/fetch path, the generic GVSoC component-binding
  engine (`engine/engine/src/component.cpp`, `ports.cpp`), and the AXI router
  chain to a single wrong port name in `cachepool_v2_group.py` — bound a
  tile's AXI output to `Hierarchical_Interco`'s `'input'` port, but with the
  default `nb_slaves=1` it actually exposes `'input_0'`. The mismatch
  silently created an orphaned, never-connected placeholder port (GVSoC
  auto-creates one for any unrecognized "self"-referenced name rather than
  erroring), so every instruction fetch and L1 refill for every core got
  `IO_REQ_INVALID` forever, permanently caching a decode of "illegal
  instruction" at the reset vector. **Fixed.**
- Verified: post-fix, PC advances cleanly out of the bootrom and deep into
  real program code (millions of cycles, `fdotp` reaches `0x80002fc8`+).
- A **second, distinct hang** appears once boot completes, same general class
  as the previously-documented matmul `Ara`-queue livelock (§13.2.1): traced
  to `AraVlsu`'s per-port request-object pool permanently draining because
  some async burst's memory response never arrives, freezing `pending_size`
  and head-of-line-blocking `Ara`'s global 8-slot queue. Root location within
  the L1 FlooNoc/cache-bank chain not yet found — open.
- Operational notes worth remembering: the `gvsoc` CLI wrapper silently
  swallows the launched process's stdout/stderr — invoke
  `install/bin/gvsoc_launcher --config=gvsoc_config.json` directly instead;
  and `gvsoc_config.json` is never regenerated if it already exists (no
  staleness check), so `rm -f gvsoc_config.json` before every regen or you
  silently keep simulating stale topology/wiring.

## 2026-07-08 — CachePool v2: fdotp/matmul functional verification, two Ara/Spatz bugs fixed, matmul deadlock traced to Ara/AraVlsu queue desync (open)

**Status:** uncommitted (core submodule). Full detail in
`prompt/cachepool_v2_architecture.md` §13.1–§13.2.1 (kept current, not
duplicated here).

**Context:** verifying the CachePool v2 build/run flow works end-to-end on
`fdotp-32b_M32768` and `fmatmul-32b_M32_N32_K32`. fdotp's `result[64]`→`result[256]`
array-size bug (software, ManyRVData) was fixed upstream by the user; re-ran
and found a *different*, still-open numeric mismatch (`Calc:189.697906` vs
`Exp:628.153869`, ratio ≈0.302). Root cause not yet identified — ruled out
the two bugs fixed below (bit-for-bit identical fdotp output before/after).

**Two real bugs found and fixed** (both in `core/models/cpu/iss/src/`, per
the user's out-of-order-memory hypothesis — CachePool's NUMA/cache paths
return `IO_REQ_PENDING`/`IO_REQ_DENIED` far more than the flat
standalone-Spatz testbench this model was originally validated against):
1. `spatz/fpu_sequencer.cpp:101-109` (`Sequencer::float_handler`) — missing
   `nb_out_reg` offset when indexing `args[]` for the FREG-input hazard
   check, so e.g. `flw`'s single OUTPUT arg's flags got checked instead of
   its INPUT arg's, and the wrong (aliased) scoreboard slot got queried.
2. `ara/spatz_vlsu.cpp` (`AraVlsu::fsm_handler`) — `ara.insn_commit()` was
   called unconditionally at burst-issue time, even for async
   `IO_REQ_PENDING`/`IO_REQ_DENIED` responses, prematurely signalling
   vector-chaining consumers that data was ready before `data_response()`
   had actually written it. Deferred the async case's commit into
   `data_response()` (2 extra IoReq arg slots pushed, 4 total for AraVlsu,
   10/16 of the documented budget — still safe).

**Verification:** rebuilt clean; both fixes confirmed to have **zero**
observable effect on fdotp (bit-for-bit identical output) and **zero**
effect on the matmul hang's onset cycle (still hangs at the same
`pc=0x800007b0`, same cycle 6197, before and after). Real bugs, not the
cause of either symptom.

**matmul hang (was a crash, now a livelock/deadlock, still open):** the
`spatz_lane_width=8`→`4` fix from a previous session stopped the
`IO_REQ_INVALID` abort, but running `fmatmul-32b_M32_N32_K32` now hangs
forever instead. Traced (via targeted rate-limited `fprintf` instrumentation
— `--trace-level=trace` was unusably slow, hanging elaboration itself for
10-15s with zero output even scoped narrowly) to: `Ara`'s shared 8-slot
`pending_insns[]` queue gets permanently stuck full from cycle ~6092, head
instruction `vle32.v v20, (t2)` (`pc=0x800007cc`) never marked `done`,
head-of-line-blocking all subsequent vector instructions via
`vector_insn_stub_handler`'s `queue_is_full()` gate. `AraVlsu`'s own local
bookkeeping (`nb_waiting_insn`, `pending_size`) looks idle throughout the
hang, suggesting a desync between `AraVlsu`'s three internal indices
(`insn_first`, `insn_first_waiting`, `insn_last`) and `Ara`'s single global
`insn_first` / `insn_end()` completion signal. Not yet pinned to an exact
line — next step is a careful read of `AraVlsu::fsm_handler`'s bottom
completion check against `Ara::insn_end`, not more instrumentation.

**Debug instrumentation left in tree** (gated/rate-limited, harmless, not
yet cleaned up): `spatz_vlsu.cpp` (`[VLSU_DBG]`, `[VLSU_WAIT_DBG]`,
`[VLSU_BURST_DBG]`), `ara.cpp` (`[ARA_DBG]`), `snitch.cpp` (`[STUB_DBG]`).
Strip once the real fix lands.

**Operational note:** matmul runs must be wall-clock-bounded
(`timeout ≤30s`) — a hung run's default per-cycle trace spam produces
multi-GB logs in seconds. Two separate accidental multi-GB logs were
generated and deleted during this session.

---

## 2026-06-25 (latest) — Configurable topology + AMO-fix validation + cross-core root-cause

**Configurable topology (commit pulp `419f43d`):** N tiles × M cores/tile × K banks/tile via env knobs
CACHEPOOL_NB_TILE / CACHEPOOL_CORES_PER_TILE / CACHEPOOL_BANKS_PER_TILE; NB_CORE = NB_TILE*CORES_PER_TILE;
bootrom core_count(@0x44)/tile_count(@0x68) patched from the one base blob; group when NB_TILE>1, else single
structural tile; snitch_cluster.py group path uses the configured topology (+structural_tile/amo_lane) and
the single-tile path uses banks_per_tile (interco.num_outputs tracks it). **Verified:** no-cache 2×4 EOC,
4×2 EOC; **with-cache 2×4 gemv EOC (77276 cyc)** — multi-tile cache (cross-tile remote xbars) boots+runs.
Notes: build once with CACHEPOOL_NB_TILE≥2 so the cross-tile remote_xbar model compiles (gvsoc compiles
models on-demand from the build-time graph); cores/tile ≤4 (2 KiB per-tile SPM holds ~4 stacks; 1×8 overflows).

**AMO-lane fix validated (cross-core lock visibility WORKS):** the [LCK] trace showed Core0 release (write 0)
→ Core1 read 0 → acquire — clean ping-pong. So the AMO fix (commits core `4341bbcc` + pulp `6849c06`) makes
the cross-core mutex correct. BUT spin-lock 2-core still doesn't COMPLETE (>3.3B cyc in 400s vs 5851 no-cache)
— the shared COUNTER incremented under the lock isn't terminating the loop: a separate cross-core SHARED-DATA
issue (same class as the fdotp bug), NOT the lock. Build cmd now: CXX=g++-14.2.0 CC=gcc-14.2.0
CMAKE=cmake-3.18.1 make build TARGETS=cachepool. printf has no lock (overlap cosmetic). See memory.

---

## 2026-06-25 (later) — AMO-lane fix: cross-core atomic mutex (crash + 1-core fixed; 2-core handoff WIP)

**Trigger (user):** "1 core + cache → most kernels correct; 2 cores → software-lock correctness breaks,
overlapping prints." Classic broken cross-core atomic-mutex signature (snrt_mutex = amoswap on a cached lock).

- **Commits:** core `4341bbcc` (AMO shim sync-path fix), pulp `6849c06` (enable amo_lane + re-lane scalar to
  lane n_ppc-1), pushed to `insitu-cache` (force-with-lease).
- **Root causes found + fixed:**
  1. The cachepool wired the SCALAR to tile lane 0, but the AMO/LR-SC shim sits on lane n_ppc-1 (RTL ordering)
     and was gated off → cached atomics were plain writes (no mutual exclusion). Fix: `amo_lane=True` +
     scalar→lane n_ppc-1, VLSU→0..n_ppc-2 (snitch_cluster.py).
  2. The `spatz_cache_amo` shim was async-only (resp()+PENDING); the cachepool core is synchronous
     (run_request_sync) so the RMW resolved in-call → resp()+PENDING double-completed → SIGABRT on true-AMO
     kernels (spin-lock). Fix: in_sync_call_/sync_completed_ flag → return IO_REQ_OK (no resp) when sync.
- **Verification:** spin-lock crash GONE; spin-lock 1-core now runs + prints its hello cleanly (mutex works);
  gemv/fmatmul 1-core still pass (95189 / 27142 cyc) — no regression.
- **STILL-OPEN:** spin-lock 2-core HANGS — Core0 acquires/prints/releases/finishes (wfi), Core1 spins forever
  in spin_lock never seeing the release. The xbar routes by address (shared cell, NOT private), so it's a
  cross-core write-visibility/timing issue in the shared cell — same class as the fdotp cross-core bug (likely
  one unifying root cause). See memory `cachepool_gvsoc_target.md`.

---

## 2026-06-25 — Cache in the loop ON by default + complete-model kernel run

**What/why (user):** "keep the cache in the loop by default on" + a run guide. Flipped
`CACHEPOOL_USE_CACHE` default `0→1` so `gvsoc --target=cachepool` routes cached-DRAM accesses through the
structural InSitu cache by default (the complete CachePool model). `=0` still bypasses (fast functional path).

- **Commit:** pulp `c3f45d7` (`cachepool: cache-in-the-loop ON by default`), pushed to `insitu-cache`
  (force-with-lease). Core unchanged (`0757b944`). Files: `pulp/cachepool.py`.
- **Ran all 8 CI kernels through the complete model** (cache on, 4-core, 250 s cap):
  - ✅ **gemv-opt PASS** (82635 cyc), ✅ **fmatmul PASS** (13339 cyc) — **data-correct THROUGH the cache.**
  - ⚠️ fdotp_M32768 **Check Failed** (88353 cyc) — the open uncached-A/B timing bug.
  - ⛔ fft exit 1 (SPM overflow); ⏳ spin-lock / load-store / linked-list / byte-enable **timeout**
    (AMO-lock break, CLINT gap, cache-sim slowness on the heavy kernels).
- **Key finding:** the with-cache failure is **NOT a general cache bug** — gemv+fmatmul (cached-data
  compute) are correct through the structural cache. fdotp is specific to its *uncached* `0xA0000000`
  inputs (VLSU-bypassed via `vico→narrow_axi`). Localized to the VLSU compute on that bypass path
  (timing-sensitive race), not the cache datapath.
- **Verification:** the 8-kernel suite above; build clean (`make build TARGETS=cachepool`).
- **Report:** `prompt/cachepool_complete_model_run_guide_2026-06-25.md` (build/run/knobs + per-kernel
  outputs + caveats). Memory: `cachepool_gvsoc_target.md`, `cachepool_project_goal.md` updated.

---

## 2026-06-21 — Structural TILE/GROUP integration: design + foundation (xbar + multi-lane core)

**Direction (user):** build the faithful structural tile, then multi-tile group; accept the Spatz
sync-model performance inaccuracy. Status answered: NO structural tile/group exists today (flat
single-tile `InsituCacheTile` = 1 hashed interco + N cells + flat l2 fan-in; no group/cluster composite).

**Design** (9-agent workflow `wf_3ff4f274-cdb`, 5 RTL+model readers → synthesis → 3 adversarial reviewers,
all 3 returned sound=false with must-fixes; folded into `prompt/insitu_cache_structural_tile_plan_2026-06-18.md`).
Verified RTL tile: **5 per-port-class crossbars** (one `tcdm_cache_interco` per lane j, NOT one hashed
interco); the **coalescer lives INSIDE the cache cell** (`cachepool_cache_ctrl`: par_coalescer on the 4
VLSU lanes + internal 2:1 bypass for the scalar lane); **AMO only on lane j=4** per controller; **eviction
rides the refill channel**; group = 4 tiles + 5 remote xbars with **source-tile-mod-N** slot pinning.
Key tension surfaced: the **sync-slave mode** (to drive the structural core from the Spatz VLSU, which
`trace.fatal`s on async) **degrades the cache cell's cross-lane fidelity** (sequential same-cycle delivery
→ coalescer can't batch, bank WR_CONFLICT smears) — so the build order validates **open-loop first** (full
fidelity), then adds the sync mode (analytic, NOT a virtual-cycle FSM loop — the reviewers showed that
re-entrant-`resp()` crashes) for closed-loop.

**Foundation built** (core `f8e78da3`):
- `insitu_cache_xbar.{cpp,py}` — one per-port-class crossbar wrapping the validated `route.hpp`. Replaces
  the hashed interco. Not yet instantiated (zero build impact); syntax-clean.
- `insitu_cache_core.{cpp,py}` — multi-lane core port (`num_input_ports`, default 1 = backward identical;
  RTL 5-wide core port). Validated in-tree: structural sample ML=50 = 13/13, data_err=0, cold miss 56
  (b.0 unchanged); controller default byte-identical (67 / 290.8).

**Build-env fix (cost real debugging):** a CMake re-configure with `CXX`/`CC` unset picked the wrong
compiler — first `arm-linux-gnu-g++` (crt1.o fail), then `g++ 8.5.0` (ABI-mismatch: the 06-16 .so need
`GLIBCXX_3.4.32`). Fixed by pinning `CXX=/usr/sepp/bin/g++-14.2.0 CC=/usr/sepp/bin/gcc-14.2.0` and
`LD_LIBRARY_PATH=/usr/pack/gcc-14.2.0-af/lib64:...` at runtime. Recorded in memory [[build_env]].

**Next:** structural cache cell composite (coalescer `coalesce.hpp` + internal bypass + core) → AMO shim
(`amo.hpp`, lane 4) → `structural_tile` branch in `insitu_cache_tile.py` (5 xbars + 4 cells) → open-loop
multi-port validation (needs a 4-controller calib variant) → sync mode → closed-loop vfadd → group.

### 2026-06-22 — Structural TILE Phase A1 DONE (5 per-port-class xbars + per-core cells, routing validated)

Built + validated the RTL-faithful structural tile (core `9ad67c88`, pulp `6e0da96`):
- `InsituCacheXbar` (built last turn) now WIRED: `_build_structural_tile()` in `insitu_cache_tile.py`
  instantiates NrTCDMPortsPerCore (=5) per-port-class xbars + N multi-lane `InsituCacheCore` cells.
  Wiring `i_INPUT(p)→xbar[p%5].in_(p//5)`; `xbar[j].out_(cb)→core[cb].input_{j}`; refill/evict→o_L2.
  Gated by `InsituCacheTileConfig.structural_tile` (default False = flat tile, byte-identical fallback).
- Config flags: `structural_tile`, `num_remote_port_core`, `num_tiles`, `tile_id`, `addr_width`.
- Calib hook `INSITU_CALIB_STRUCTURAL_TILE` (+ `INSITU_CALIB_STRUCT_BANKS`, default 4).
- **Validated** (g++-14.2.0): structural tile, 5 xbars, 4 banks, sample ML=50 → 13/13 respond,
  **data_err=0**; lane-j accesses route across all 4 banks BY ADDRESS (0x00/0x40/0x80/0xc0→banks
  0/1/2/3), responses return to originating ports → the shared-L1 intra-tile routing is faithful +
  data-correct. Fallbacks byte-identical (flat structural core 56/278.5; flat controller 67/290.8).
- Phase A1 scope: NO MSB rotation, NO coalescer/AMO yet. **Next: A2** = structural cache CELL composite
  (par_coalescer `coalesce.hpp` on the 4 VLSU lanes + internal 2:1 bypass on the scalar + core),
  validated against the calib cell reference (warm hit 10/7, coal_cold); then A3 AMO (lane 4), A4 sync
  mode → closed-loop vfadd, A5 group (remote xbars + source-tile-mod-N).

**Phase A2 DONE** (core `a6ee0038`, pulp `4d4bb78`): the structural cache CELL — `cachepool_cache_ctrl`'s
par_coalescer (4 VLSU lanes) + scalar bypass. `insitu_cache_cell_coalescer.{cpp,py}`: per-cycle coalescer
wrapping `coalesce.hpp` — same-cycle same-line VLSU reads coalesce into ONE wide line-read to the core,
response split back per merged port (rsp_spliter); writes pass through (`req_forward`, data-correct);
1-cycle CSHR window; 64-group in-flight pool. Tile `cell_coalescer` branch: VLSU lanes → coalescer[cb] →
core input 0; scalar lane → core input 1 (2-input core). Gated `cell_coalescer` (default False = A1
n_ppc-input core). Validated (g++-14.2.0): coalescer cell, 4 banks, sample ML=50 → 13/13, data_err=0
(wide-read+split correct; scalar bypasses to 55). No regressions (A1 data_err=0; flat core 56/278.5; flat
ctrl 67/290.8). Merge benefit (multi-member groups) needs a coal trace (sample has 1-member groups only)
→ that + warm-hit 10/7 / coal_cold timing is the calibration step. **Next: A3** AMO shim (lane 4).

**Phase A3 DONE** (core `6d488974`, pulp `a679e98`): the AMO/LR-SC shim on the scalar lane (j=n_ppc-1),
one per cell (`cachepool_tile.sv:658`; VLSU lanes bypass). `insitu_cache_amo_shim.{cpp,py}` wraps the
validated `amo.hpp`: IoReqOpcode dispatch — READ/WRITE pass through (req_forward; WRITE clears a matching
reservation); LR sets the reservation + presents a plain READ; SC returns 0/1; true AMO does the RMW
(read word → amo_alu → write back → return OLD). Single in-flight (scalar LSU single-outstanding →
atomic). Tile `amo_lane` branch routes the scalar lane through `amo[cb]` before the core (works with both
the A1 5-input core and the A2 coalescer cell). Validated (g++-14.2.0): tile+coalescer+AMO, sample ML=50
→ 13/13, data_err=0 (scalar READ/WRITE pass-through correct; calib has no AMO traffic, so the LR/SC/AMO
RMW paths rely on amo.hpp's standalone validation + closed-loop). No regressions (A2 55/279.4, A1
53/275.7, flat core 56/278.5). **Structural TILE is now structurally complete** (5 xbars + coalescer cell
+ AMO shim). **Next: A4** = the synchronous-slave mode (analytic, per the review — NOT a virtual-cycle
loop) → closed-loop vfadd on the structural tile (validates A1+A2+A3 end-to-end + exercises the AMO RMW);
then A5 group (remote xbars + source-tile-mod-N + DDR4).

**Phase A4 DONE — structural tile runs CLOSED-LOOP vfadd** (core `7886617e`, pulp `0f89037`+`b2d943a`).
Design: 7-agent workflow `wf_577e09d4-51c` (deadlock reviewer SOUND; fidelity reviewer must-fixes folded).
- `insitu_cache_core.cpp` run_request_sync(): ANALYTIC one-shot synchronous-slave (mirrors the
  controller's inline_sync_miss — NOT a virtual-cycle loop, which the review showed crashes on re-entrant
  resp()). decode → HIT (serve + lru + inc_latency(hit_latency_cycles) + IO_REQ_OK) / MISS (evict dirty
  victim copying bytes BEFORE the refill overwrite; lru BEFORE status writes; refill; on OK refill_lat =
  get_full_latency()+refill_bank_write_cycles+miss_penalty_cycles; install; serve; inc_latency; OK).
  Write-commit = added latency, never DENY. NO save/resp/tick/FIFO. Gated `inline_sync_` (default off).
  core.py publishes inline_sync_miss/hit_latency_cycles/write_commit_cycles.
- Cluster: opt-in property `use_structural_insitu_cache` → structural_tile + cell_coalescer=False +
  amo_lane=False + controllers_track_cores + line-granular dynamic_offset; same facade (no binding change).
- **Validated** (g++-14.2.0): calib sync path data_err=0, all IO_REQ_OK, warm hit 9 / cold miss ML+12
  (RTL 10 / ML+17 — gap = calibration). **CLOSED-LOOP vfadd on the structural tile: 15/15 PASSED,
  retval=0, cycles=59001** (flat-tile default unregressed: 15/15, 58001 — +1.7%). The RTL-faithful tile
  (5 per-port-class xbars + per-core sync-slave cells) now runs real Spatz kernels end-to-end.
- **Next: A5** group (4 tiles + 5 remote xbars + source-tile-mod-N + DDR4); then the timing-calibration
  pass (warm hit 9→10, cold miss ML+12→ML+17, coal_cold via a same-line multi-lane trace).

**Phase A5 DONE — multi-tile GROUP + cross-tile shared L1** (core `c5d67024`, pulp `038117e`). The full
hierarchy GROUP→TILE→cell→core is now built. `insitu_cache_remote_xbar.{cpp,py}`: one per-port-class
inter-tile router (num_tiles×num_tiles), routes a cross-tile request to the TARGET tile by the address
TileID (route.hpp addr_tile); the GVSoC response auto-routes back via the preserved resp-port chain, so
the RTL source-tile-mod-N slot pinning is a timing-only detail (not needed for functional correctness).
`insitu_cache_tile.py`: per-port-class remote-OUT/IN ports (o_REMOTE_OUT/i_REMOTE_IN) when
num_remote_port_core>0. `insitu_cache_group.py`: InsituCacheGroup = N tile_id-stamped tiles + 5 remote
xbars + L2 fan-in. Validated (g++-14.2.0): 2-tile group, calib sample ML=50, driving tile-0's 5 ports →
13/13 respond, data_err=0; addresses route local (tile 0) OR cross-tile (tile 1) by TileID, a tile-0 core
reading a tile-1-homed line gets correct data via the remote xbar. **The structural rewrite is now
STRUCTURALLY COMPLETE** (decode/bank/fwd/core/coalescer/xbar/SPM/sync/AMO/L2 components + cell + tile +
group), single-tile runs closed-loop vfadd (A4), multi-tile cross-tile data-correct (A5). **Next: the
timing-CALIBRATION pass** (warm hit 9→10, cold miss ML+12→ML+17, coal_cold via a same-line multi-lane
trace; closed-loop region_cyc) + the cluster-level group wiring (DDR4 L2, peripheral/flush) for a real
16-core run.

**A5b — group config matches RTL cachepool_fpu_512.mk @ f5c3ef4** (core `a8f13797`, pulp `db96de0`).
`make_cachepool_fpu_512_config()`: num_tiles=4, 4 cores/tile, NumL1CacheCtrl=NumCores=16 (4 ctrl/tile),
5 TCDM ports/core, **num_remote_ports_per_tile=2** (NumRemotePortCore=2); per-controller 4-way×256-set×64B
= 64 KiB (256 KiB/tile), L1BankFactor=2 (pkg hardcodes 2; the .mk's l1d_bank_factor=1 is dead),
folded+hash+fwd; L1CoalFactor=2; L2 4ch/interleave 16. Fetched the exact commit via WebFetch (matches the
local config except num_remote_ports_per_tile: local=1, f5c3ef4=2). Generalized the remote ports to
NumRemotePortCore≥1 (remote xbar = NumTiles*nrpc in/out, source-tile-mod-N slot; tile exposes nrpc
remote-out/-in per port-class). Validated: fpu_512 group, calib sample ML=50, tile-0/core-0's 5 ports →
13/13, data_err=0, cross-tile to tiles 1/2/3 correct; single-tile unregressed (53/275.7).

**FULL CachePool path — 16-core config, 6/8 CI kernels pass** (pulp `66ebb3c` → `5ec8cb6`). Extended the
cachepool target to 16-core (`CACHEPOOL_NB_CORE=16` selects nb_core + a 16-core bootrom: the RTL
`bootrom.bin` patched to core_count=16/tile_count=4). **Resolved the 16-core SPM model empirically** (the
snrt crt0 gives every hart the SAME `sp` VA — `init_core_info` returns the same `tcdm_start/end` for all
16, cluster_idx=mhartid/16=0): a single shared SPM collides 16 stacks (hang); fully per-core-private breaks
shared l1alloc (`cluster_mem`=the SPM; fdotp/gemv fail even at 4 cores); the right model is **per-TILE-shared
SPM** (`snitch_cluster.py` `arch.spm_num_groups`; cachepool sets it = NB_TILE → 4 SPMs × 4 cores; 4-core
= 1 shared SPM = the passing MINIMAL case). **16-core suite (per-tile SPM): spin-lock / load-store_M16 /
fdotp_M32768 / gemv-opt / fmatmul_M32 [was a 4-core timeout] / byte-enable all retval=0 — 6/8.** Remaining:
fft (SIGABRT — overflows the shared 2 KiB tile SPM at 16; and is independently wrong, retval=1 at ALL SPM
configs incl. 4-core where everything else passes → an fft-specific functional bug) + linked-list (SIGABRT,
needs CL_CLINT inter-core IRQ + likely SPM overflow). The 2 aborters reveal the SPM ultimately needs
**per-core stacks + shared heap** (the partitionable SPM the structural cache provides) — the next FULL item,
along with CL_CLINT and wiring the cache to front DRAM.

**FULL — cache-fronting-DRAM WIP (gated, data-incorrect)** (pulp `2867db2`). Opt-in `CACHEPOOL_USE_CACHE=1`
routes the cores' cached-DRAM region [0x80000000,0x84000000) through the structural `InsituCacheGroup`
(16-core) / single tile (4-core); SPM/peripheral/uncached stay direct; cache `o_L2` refills DRAM via
wide_axi→o_WIDE_SOC (the existing TCDM-only local map leaves DRAM to the SoC). Peripheral cachepool mode
widened to 0x14..0x4c scratch (the cache path reads SPATZ_CYCLE@0x1c). **Default OFF — the validated no-cache
path is unchanged.** When enabled: **DATA-INCORRECT** (fdotp prints `Check Failed!` — and fdotp `return 0`s
regardless, so retval=0 HID it) + slow (16-core / spin-heavy kernels time out). Needs cache-data-path debug
(likely the VLSU wide-read / refill under load) + sim-perf work. **Key lesson:** retval≠correctness for
several kernels (fdotp/etc. always `return 0`; the real verdict is the `Check Failed!`/`Error:` print). The
no-cache passes ARE genuine (direct DRAM = exact data; fdotp/gemv/byte-enable print no Check-Failed).

**MINIMAL CachePool SoC target — snrt CI benchmarks boot/print/exit on gvsoc** (core `b5ed7dd4`, pulp
`85ed0ef`). New `gvsoc --target=cachepool` (`pulp/cachepool.py`) + `cachepool_uart.cpp` (snrt printf→stdout)
+ a gated `cachepool` mode in `cluster_registers` (L1D-config 0x28..0x4c RW scratch, FLUSH_STATUS 0x3c reads
0, EOC@0x24→quit retval). Reproduces the CachePool boot env/map: bootrom@0x1000 (reuses RTL `bootrom.bin`,
BOOTDATA core_count=4), DRAM@0x80000000, uncached/.pdcp@0xA0000000, SPM@0xBFFFF800 (2 KiB cluster local
mem, shrunk+adjacent to peri), peripheral@0xC0000000, fake-UART@0xC0010000. 4-core/1-tile, no cache (cores
hit DRAM directly; the structural cache fronting DRAM = FULL path). **KEY boot fixes:** (1) install the
bootrom `.bin` via a `vp_files()` CMakeLists (dir-install copies only `*.py`); (2) wake the wfi'd bootrom
via **MSIP** (mip bit 3, enabled by the bootrom's `mie=0xF`), NOT MEIP (bit 11) — gvsoc wfi wakes only
when `(mie & mip)!=0`. Reuses SnitchCluster's blocking HW barrier @0x10 + HTIF. **Validated:** the
UNMODIFIED CachePool CI binaries now boot/print/exit on gvsoc — cache-line-rw-smoke / spin-lock (prints
"Tile0, Core1:hello") / byte-enable / load-store_M16 / fdotp-32b_M32768 / gemv-opt all `retval=0`. This is
the MINIMAL path of `prompt/gvsoc_cachepool_soc_boot_scope_2026-06-22.md`; FULL = 16-core/4-tile bootdata
+ CL_CLINT IRQ + L1D-config wired into the cache + cycle calibration.

**A5c — group wired into the Spatz cluster** (pulp `14c456d`). Opt-in property `use_cachepool_group` →
the cluster builds `InsituCacheGroup` from `make_cachepool_fpu_512_config()` (4 tiles × 4 cores, same
i_INPUT/o_L2 facade as the tile; assert nb_core=16). **Validated CLOSED-LOOP on the full 16-core group:**
`vfadd` 15/15 PASSED, retval=0, cycles=69001 (single-tile 59001, flat 58001). The 16-core 4-tile
structural group elaborates + a gvsoc-native kernel boots + runs through it data-correct.
**BLOCKER — CachePool CI benchmarks can't run on gvsoc:** the `configs-ci.sh` binaries
(`software/build/CachePoolTests/test-cachepool-*`, 8 kernels) are `snrt`-based RTL-sim binaries run by the
auto-benchmark via **vsim** (`cachepool_cluster.vsim`), built for the **CachePool SoC**. On gvsoc
`--target=spatz` they hang at boot (no output, baseline + nb_core=16) — the gvsoc spatz target is a
different SoC (no snrt boot env / cluster peripheral / print path). Running them on gvsoc needs a **GVSoC
CachePool SoC model**, not just the cache. Full report: `prompt/cachepool_fpu_512_group_run_report_2026-06-22.md`.

---

## 2026-06-16 — (b) open-loop structural calibration kickoff: b.0 refill-latency emergence + deadlock fix

**Direction (user):** go with (b) — calibrate the STRUCTURAL model — but NOT via the current Spatz cluster
for now (open-loop only). This drops the synchronous-slave mode (must-fix #1) off the critical path: the
structural core's existing async park+resp is exactly what the open-loop calib testbench speaks.

**Pre-decision finding (workflow `wf_949f6097-32a`, 8 agents, all 3 refuters failed):** the prior premise
"the Spatz v1 LSU only accepts synchronous IO_REQ_OK" is FALSE. The v1 scalar LSU (`cpu/iss/src/lsu.cpp`,
the one the `spatz` target builds) handles a non-OK return by stalling + resuming on its `data_response`
callback. The REAL closed-loop blocker is the Spatz **VLSU** (`cpu/iss/src/ara/spatz_vlsu.cpp`): it
`trace.fatal("Unimplemented async response")` on any non-OK and binds no resp handler. Verdict:
`needs_sync_slave_only`, and a sync-slave mode is SUFFICIENT (no VLSU rework) when closed-loop is revisited.
For open-loop the async structural core works as-is. So the (b)-open-loop decision is confirmed sound and
the eventual closed-loop gap is one well-scoped sync-slave mode, not a Spatz rewrite.

**b.0 DONE** (core `0c297356`, pulp `5d78298`):
1. **Refill latency emerges** (`insitu_cache_core.cpp`). `drain_outputs()` discarded the serializing
   responder's stamped `inc_latency` on an `IO_REQ_OK` refill → cold miss ≈ pipeline cycles regardless of
   MemLatency. Now captures `refill_req_.get_full_latency()`, defers install to `refill_ready_cycle_ =
   now + lat`, and gates the next refill on it (serialized miss throughput). Cold miss scales:
   56@ML50 / 106@ML100; misses serialize ~+53 each (RTL ~+55).
2. **Deadlock fix** (the deferral exposed it). Refill install was routed through `preread_q_`/stage0; a
   stalled request also occupies `preread_q_` and blocked stage0 from promoting the refill that would
   drain `retr` to clear the stall (circular → 5M-cycle watchdog abort, 7/13 responded). Refactored:
   `process_request()` returns done/stalled (a stall stays latched + retries), and `maybe_install_refill()`
   installs a ready refill as a priority bank op on its OWN path (more RTL-faithful — the refill block is a
   separate `always`, refill wins bank arbitration via the retr-room gate). Now 13/13 respond, data_err=0.
3. **Harness async-measurement fix** (`calib_driver.cpp`): `t_resp = now + full_lat` (was
   `t_issue + full_lat`). The sync controller calls `on_response` inline at issue (`now==t_issue`, numbers
   unchanged); the async structural core resp()s at the real completion cycle and conveys latency via
   wall-clock, which the old formula collapsed to ~t_issue. Plus `INSITU_CALIB_STRUCTURAL_CORE` env hook
   (default off) to run the structural core through the calib replay.

**Validated:** structural calib sample ML=50/100 → 13/13 respond, data_err=0, cold miss scales with ML,
misses serialized; **default controller path byte-unchanged** (sample ML=50: 290.8 avg / cold miss 67).
**Open b.1:** cold-miss isolated = ML+6 vs RTL ML+17 (tune the fixed cache-overhead constant); warm-hit
10/7, throughput 0.86, gap sweep — needs the phase traces (only `sample.trace` ships under
reports/cache_calib/traces/; the phase traces come from `gen_traces.py`). Then b.2 (structural coalescer).

---

## 2026-06-16 — Structural rewrite Step 7 (datapath components): AMO/LR-SC + L2 scramble/NAPOT

Two more RTL-faithful header-only datapaths transcribed + standalone-validated (core `32950f40`,
gated default-off, zero build impact). This completes the **component** transcription mandate — every
planned microarchitecture/architecture component now has real RTL logic (no approximations):

- `insitu_cache_amo.hpp` — `spatz_cache_amo.sv` RMW/LR-SC shim (scalar lane j=4): the 4-state RMW FSM
  Idle→DoAMO→WriteBackAMO→Wait with **atomicity via core back-pressure** (core_ready=0 in every non-Idle
  state), the 32-bit `amo_alu` (swap/add/and/or/xor/signed Max,Min/unsigned Maxu,Minu via the a−b
  sign-bit), and the `{valid,addr,core}` reservation (LR sets/overwrites; foreign write or true-AMO to
  the reserved addr clears; owner SC clears + success=addr-match; SC returns 0 success/1 fail; only
  writes on success). 64-bit handled by 32b-half select (idx → strb 0xF<<idx*4).
- `insitu_cache_l2_addr.hpp` — `cachepool_pkg` scrambleAddr/revertAddr (Scramble↔InterChange field swap
  to interleave lines across channels, gated on `granule < per-ch size`) + `cachepool_cluster` NAPOT
  channel decode (`channel = scrambled>>SizeOffsetBits & (NumL2Channel-1)`). DDR4, DramAddr 0x8000_0000,
  1GiB, 4 channels. revertAddr kept for a DRAMSys-side linear-address need (RTL routes responses by
  tile_id/bank_id sideband, not un-scramble).

**Validation:** `/tmp/insitu_step7_selftest.cpp` (g++ -std=c++17) — 38 checks, ALL PASS: every ALU op,
the full LR/SC reservation rule set, the complete RMW walk (Idle→Idle, atomicity asserted each state,
64b upper-half), and scramble/revert round-trip + channel extraction + inactive identity. RTL read-only
refs: `hardware/src/{spatz_cache_amo,cachepool_cluster,cachepool_pkg,cachepool_tile}.sv` (extracted via
two Explore agents). **Remaining Step-7 = COMPOSITION** (cachepool_tile/group/cluster.py wiring the
structural components + remote/inter-tile xbar + DDR4 refill + the cluster **synchronous-slave inline
mode** for the structural core — master-plan must-fix #1), then the **calibration pass** (wire the
validated headers' per-cycle timing into the tick; diff per-access + region_cyc vs `rtl_ref_1t_2026-06-16`).

---

## 2026-06-16 — Structural rewrite Steps 3, 5, 6 (RTL-faithful headers, validated standalone)

Continuing the structural rewrite (master plan `prompt/insitu_cache_structural_plan_2026-06-16.md`).
Three more components transcribed as header-only, RTL-faithful datapaths, each with a standalone g++
self-test. All gated default-off; zero build impact (headers, not yet referenced by a compiled target);
the calibrated controller/interco/coalescer path is untouched (fallback stays default).

**Step 3 DONE** (core `d0abdeed`): `insitu_cache_fwd_buffer.hpp` — single-entry SRAM forwarding buffer
(`sram_forwarding_buffer.sv`): read-suppress (serve resident line from buffer, skip bank read),
write-absorb (lazy byte-mask merge, mark dirty), lazy writeback of a dirty victim, partial-validity
bitmap (per-part residency), RAW forward. SCOPE: single-entry in-order; deferred to calibration — the
double-buffered `_q/_d` same-cycle split, in-flight-SRAM-populate merge, and the N-entry variant.
Validated standalone; NOT yet wired into the core data path (lands with calibration).

**Step 5 DONE** (core `54815e22`): `insitu_cache_coalesce.hpp` — the real par_coalescer datapath
(`par_coalescer_equal_window.sv` / `req_coalescer_v2.sv` / `rsp_spliter_v2.sv`): same-cycle narrow ports
to the SAME line + SAME type coalesce into ONE wide 512b beat (write-bit folded into the key MSB so R/W
never co-merge), per-port word offsets + hitmap, wide write merge (last-writer-wins), and the read-split
back to each merged port's word. Replaces the `enable_input_coalesce` latency-trick. SCOPE: functional
group-coalesce + wide-merge + split; deferred to calibration — the CSHR FSM (IDLE/VALID + watchdog),
per-port depth-4 FIFOs, equal-vs-extend window policy, RR next-line arbiter. Validated standalone.

**Step 6 DONE** (this commit): three headers for the programmable xbar + SPM partition + flush/sync FSM.
- `insitu_cache_route.hpp` — `tcdm_cache_interco.sv` request routing (3 partition modes:
  all-private/single-tile, all-shared, mixed — with modulo-fold `bank%num_private` /
  `num_private+bank%num_shared` and remote-slot `tile%NumRemotePort`), response routing (by core_id;
  remote tiles return on `tile%NumRemotePort`), and the **MSB address rotation** (`+`inverse for refill):
  the N routing bits above `dynamic_offset` (BankSel, +TileID for shared banks) rotated to the MSB so the
  cache tag/index never sees them. Plus the 2:1 `reqrsp_xbar` bypass (coalescer-aggregate | scalar) with
  RR arbitration + response demux on the `bypass_coalescer` bit.
- `insitu_cache_spm_remap.hpp` — `partitionable_flushable.sv` SPM address translation: the exact integer
  DIV/MOD remap `tag=line/cache_sets, set=line%cache_sets + spm_sets` (NOT a power-of-2 mask) carving
  `NumPseudoDualBanks*bank_depth_for_SPM` sets out as scratchpad; `restore_downstream` is the exact
  inverse for refill/eviction. Collapses to identity when `bank_depth_for_SPM=0` (the common case).
- `insitu_cache_sync_fsm.hpp` — the 7-state flush/sync FSM (`insitu_cache_tcdm_wrapper.sv`
  gen_sync_ctrl_fsm): IDLE→READ_BANK→CHECK_PEND→{INIT|FLUSH}→FINISH, 4 opcodes (flush+inv/flush/inv/
  init), the **CheckPendDrainCycles=20 consecutive-stable drain interlock**, the per-set walk with
  per-dirty-way write-through eviction (stay-on-ptr re-check drains multi-way dirty sets), bank-init walk
  from set 0, and `sync_block_upstream` gating ALL upstream traffic for the whole walk. Owner indexes
  `dirty_rf[fsm.ptr()]` (the RTL `dirty_rf[sync_ctrl_ptr_q]` combinational read). PartSplit>1
  `flush_full_*` multi-cycle dance stubbed (canonical PartSplit=1).

**Validation:** `/tmp/insitu_step6_selftest.cpp` (g++ -std=c++17) — 51 checks, ALL PASS: single-tile +
all-shared + mixed routing, addr rotation round-trip, response routing, bypass RR + demux; SPM
no-partition identity + partitioned line→set placement + restore round-trip; sync FSM full flow
(IDLE→FINISH, 20-cycle drain enforced, dirty-line eviction of set1/way2, bank-init walks all sets).
RTL read-only refs: `hardware/src/{tcdm_cache_interco,reqrsp_xbar}.sv`,
`insitu_cache_tcdm_wrapper{,_partitionable_flushable}.sv`. Open: Step 7 (tile/group/cluster composite +
remote/inter-tile xbar + DDR4 refill + cluster synchronous-slave inline mode), then the calibration pass.

---

## 2026-06-16 — Structural rewrite kickoff: master plan + Step 1 (decode/encode datapath)

**Direction (user):** implement EVERY microarch/arch component with the REAL RTL logic (not the
cycle-approximate latency knobs), THEN calibrate. So the build-time gate is now functional correctness
+ structural fidelity; performance calibration is a final pass. Keep the existing calibrated model as a
selectable parallel fallback (switch only at the cluster integration boundary).

**Master plan:** `prompt/insitu_cache_structural_plan_2026-06-16.md` (from a 10-agent workflow:
8 RTL-port readers → synth → adversarial review = SOUND-WITH-FIXES). 7-component, dependency-ordered
build: Step0 scaffold → **Step1 decode/encode** → Step2 bank array → Step3 fwd buffer → Step4 cache core
→ Step5 par_coalescer → Step6 xbar/bypass/SPM/sync → Step7 system composite (+DRAMSys DDR4 on refill).
Review must-fixes folded into the plan: (1) the structural core MUST keep a **synchronous-slave mode**
(run the per-cycle FSM internally, return OK inline) for the cluster — same constraint inline_sync_miss
solves; (2) validate by diffing per-access data/latency vs the RTL reference dataset, not the RTL SV
scoreboard; (3) reuse insitu_calib_mem as the Step-4 refill responder; (4) resolve FIFO depths / MRP /
BankFactor from cachepool_cache_ctrl.sv before Step 4. (The refill-evict-fsm reader hit a transient API
error — re-read cachepool_cache_ctrl.sv directly at Step 4.)

**Step 1 DONE:** `core/models/cache/insitu/insitu_cache_decode.hpp` (committed) — a header-only,
RTL-faithful transcription of `insitu_cache_decoder.sv` + `insitu_cache_encoder.sv`: address decode,
the real **hash-way = lowtag^lowset** (replaces the model's Knuth-hash approximation), the SOP
hit/hit_pend/hit_conflit/all_pend classify (status bit-encoding INVALID=0/VALID=1/READ_PEND=2/
WRITE_PEND=3), the full-assoc LRU victim (first-credit-0 / min-LRU), the encoder LRU-credit update
(max_lru_credit = #VALID|INVALID ways; allocate→ways-1, complete→mlc, MRU-bump), and masked byte merge.
Pure logic, no ports/events; used by the Step-4 core. Validated standalone (g++ self-test, all checks
pass); not yet referenced by any compiled target → zero build impact.

**Step 2 DONE:** `insitu_cache_bank_array.hpp` (core `d6d244b8`) — RTL-faithful pseudo-dual-port bank model
(transcribes `pseudo_dual_port_tcdm_wrapper` + `pseudo_dual_port_bank.sv` + `folded_data_bank.sv`): the
6-state R-vs-W classify, `bank_select = low log2(BankFactor) bits of the set/row`, and the **WR_CONFLICT
penalty via a PER-CYCLE write scoreboard** (a read to the same way + same bank-select + different row
that a write took this cycle → retry next cycle, +1) — the structural replacement for `set_busy_until_`.
Ways are independent SRAMs (no cross-way conflict); same-row = WR_SAME_ADDR forward (no penalty); SRAM
read latency=1. Validated standalone (classify + scoreboard + per-cycle reset all pass); header, zero
build impact.

**Step 4 DONE (first runnable):** `insitu_cache_core.{cpp,py}` (core `07203629`) — the RTL-faithful
STRUCTURAL cache core: a per-cycle ClockEvent FSM (2-stage pipeline: stage-0 arbitrate {request,
refill} → preread reg; stage-1 decode+FSM+one bank write+output drain) consuming Step-1 decode +
Step-2 bank. REQ_PROC: read-hit / write-hit / read-hit-pend (in-situ MSHR append) / miss-allocate /
victim dirty-writeback; single-outstanding refill install + drain of all queued readers; bank
WR_CONFLICT → read retries next tick; functional data path. **Latency EMERGES from pipeline cycles**
(not knobs) — calibration deferred. Gated by `InsituCacheTileConfig.use_structural_core` (default
False → the calibrated controller, byte-identical: default-off fmatmul mean-Δ 3.9 confirmed); the tile
swaps InsituCacheCore for InsituCacheController when set. Open-loop/async ONLY (the cluster keeps the
controller until the synchronous-slave inline mode lands). **Validated:** compiles; runs synthetic
(cold_miss/warm_stream/raw/cold_stream) + the real single-tile fmatmul t0c0 (5488 acc) with
**data_err=0**, no hangs. **Concurrency fidelity fix (core `05e856b2`):** replaced the 1-deep input
buffer with a bounded streaming accept queue (~NumSpatzOutstandingLoads=32) — `max_outstanding` now
tracks the budget (3 → 34 on fmatmul t0c0, 32 on cold_stream), data_err=0. KNOWN/deferred: per-access
latency still over-predicts (fmatmul t0c0 ~251 vs RTL ~18) = single-outstanding-refill serialization +
the open-loop replay-backpressure double-count (the `per_cycle_arb`/fix-#5 effect) → the CALIBRATION
phase. New config knobs: `bank_factor` (RTL L1BankFactor=2), `use_structural_core`. Open: Steps 3/5/6/7
(fwd-buffer FSM, real par_coalescer, xbar/SPM/sync, composite + DDR4) + the cluster sync mode + the
core timing-calibration pass.

---

## 2026-06-16 ~03:00 +0200 — Miss-path diagnosis vs the new single-tile RTL reference (no code change)

**Status:** diagnosis only (a temp `enable_multi_read_pend=True` experiment was run and **reverted** —
zero effect; tree clean at P2-inc1). RTL reference received from the RTL side:
`ManyRVData_rebase/reports/cache_calib/rtl_ref_1t_2026-06-16/` (single-tile 4-core, Burst=4; closed-loop
mem = DRAMSys DDR4-1866, NOT MemLatency=50; per-access CSVs at ML=50 = open-loop reference).

**What.** Open-loop per-access replay of 5 single-tile kernels (idotp/fmatmul/fft/fdotp/gemv) through the
calib model, diffed vs the new RTL `.rtl.csv`. Hit path faithful (+0.2…+7.5 cy); **miss path
over-predicts +17…+80 cy under deep saturation** (these are memory-bound; RTL per-miss latency up to
330 cy). **Root-caused to the `max_outstanding` gap (calib_report §13):** GVSoC bounds outstanding by
the per-port requester budget (4 VLSU × 32 = **128**) vs RTL's cache-internal cap (~**56**) → ~2× deeper
queue → flat +40…+80 cy. NOT multi-read-pend (flipping it, verified live in the dumped config, had zero
effect — queue is budget-bounded, not retr_fifo-bounded). The over-prediction is flat across the trace
(steady-state queue depth, not an unbounded backup); `max_outstanding=128` confirmed in CALIB_REPORT.

**Why hard:** capping outstanding at ~56 regresses the matched synthetic miss-throughput (coal_cold/
cold_stream/evict) — the §13 coupled/NO-GO result. And the open-loop saturated latency likely
over-states the error that matters: the real metric (closed-loop cycle count) is throughput-driven, and
throughput IS matched (≤7%).

**Recommendation (in `prompt/insitu_cache_misspath_diagnosis_2026-06-16.md`):** don't chase the open-loop
saturation latency in isolation; validate **closed-loop** `region_cyc` vs the §D RTL table (needs DDR4
DRAMSys on the refill path + single-tile topology + dynamic_offset≈6 + the RTL ELFs). Only model the
per-resource MSHR cap (P3) if closed-loop cycles are off in a way attributable to outstanding depth — in
which case ask the RTL side for per-kernel `max_outstanding` to set the cap precisely.

---

## 2026-06-15 20:59 +0200 — Phase-2 increment 1: per-core controller cardinality (gated, default-off)

**Status:** committed — core `d821214b`, pulp `b88f878` (pushed force-with-lease to forks); parent
pointer bumped locally. First Phase-2 (topology) step. Approach from a 3-strategy design workflow +
adversarial review (verdict GO-WITH-FIXES); chose Strategy 1 (per-core cardinality first).

**Why pivot from Phase-1 front-end increments:** after inc1 (par_coalescer), the remaining P1
front-end micro-steps were found to be open-loop-neutral and/or topology-entangled (response-split is
a no-op since the RTL splits in ~1 cyc; scalar-bypass/single-wide need the per-core structure;
miss-coalesce duplicates the controller MSHR). The design workflow verified the model's address
routing is ALREADY RTL-faithful, and the model is wrong in two separable ways: (1) cardinality
(num_controllers fixed at 4 vs RTL one-cache-per-core), (2) one monolithic arbitration domain vs RTL's
per-port-class xbars. Phase-2 fixes these and unlocks closed-loop cycle comparison (the real goal).

**What (inc1).** `InsituCacheTileConfig.controllers_track_cores` (default **False**). When on, the
cluster site (`snitch_cluster.py`) sets `num_controllers = nb_core` — one L1 cache per core (RTL
`NumL1CacheCtrl = NumCores`, `cachepool_pkg.sv:121`), instead of the factory's fixed 4. Power-of-two
`nb_core` asserted (the interco routes by `(addr>>dynamic_offset)&(num_outputs-1)`). No `.cpp` change —
routing/wide-split/tile-loop already handle `num_outputs>1` generically.

**Files:** core `models/cache/insitu/insitu_cache_config.py` (flag field); pulp
`pulp/snitch/snitch_cluster/snitch_cluster.py` (set num_controllers when flag on, power-of-two guard).

**Verification (full build+install):**
- Default-off (committed): fmatmul-M32 3.9, coal_cold 0.4961, vfadd 15/15 cyc=58001 — byte-identical
  (calib uses a separate single-controller factory; flag read only at the cluster site).
- Flag-on @nb_core=2 (temp flip in the production factory, then reverted): interco elaborates
  **N=10 M=2** (2 per-core controllers, `ctrl_0`+`ctrl_1`), vfadd **retval=0** (passes). Cycle count
  unchanged at 58001 because vfadd isn't bank-contention-bound — a correctness test, not a
  discriminating benchmark; the topology effect needs a contention kernel + the RTL reference.

**Caveats / follow-ups:** per-controller capacity is NOT yet RTL-scaled (total tile capacity tracks
controller count) → Phase-2 inc3. The diffable closed-loop number needs (a) the per-port-class xbars
(inc2), (b) capacity scaling (inc3), and (c) an **RTL single-tile reference cycle count** (`cachepool_1t.mk`,
BurstLength=4 regime) — which requires an RTL sim run (outside this environment; flagged as inc0, a
user/RTL-sim task). Structure map: `prompt/insitu_cache_structure_map_2026-06-15c.md`.

---

## 2026-06-15 20:22 +0200 — Phase-1 increment 1: structural par_coalescer (gated, default-off)

**Status:** committed — core `040fdef3` (pushed force-with-lease to fork); parent pointer bumped
locally. First implementation step of the dev-plan Phase 1 (structural per-core cache refactor).
Approach chosen via a 3-strategy design workflow + adversarial calibration/Spatz-safety review; user
picked "build P1 at the par_coalescer."

**What.** Added `InsituCacheParCoalescer` (`insitu_cache_par_coalescer.{cpp,py}`) — a standalone
per-controller front-end that is the structural extraction of the interco's inline
`enable_input_coalesce` window: same-cycle/same-line read merge (followers inherit the leader's warm-
hit latency, return OK, no re-forward, no accept slot) + output-accept arbitration + interco_latency.
Gated by `InsituCacheTileConfig.use_structural_coalescer` (default **False**). When on, the interco
becomes a pure address router via a new `defer_to_coalescer` flag (skips merge+arb+latency, just
routes), and the tile inserts one par_coalescer between each interco output and its controller.

**Why this placement.** The merge and the output-arb must move *together* (a merged follower must not
consume an interco accept slot); so the interco's per-output body was relocated wholesale into the
coalescer, fed by a route-only interco — reproducing the calibrated numbers by construction.

**Files:** core `models/cache/insitu/`: `insitu_cache_par_coalescer.{cpp,py}` (new),
`insitu_cache_interco.{cpp,py}` (defer_to_coalescer router gate), `insitu_cache_config.py`
(`InsituCacheParCoalescerConfig` + tile `use_structural_coalescer` + interco `defer_to_coalescer`),
`insitu_cache_tile.py` (structural wiring). No pulp change.

**Verification (full build+install of calib + spatz):**
- Default-off (committed): fmatmul-M32 mean-Δ **3.9**, coal_cold wide@ML50 **0.4961**, vfadd **15/15
  cyc=58001** — byte-identical (interco path unchanged; component not instantiated).
- Structural-on (temp flip in calib, then reverted): **all 19 calib traces' per-access latency
  byte-IDENTICAL** to the default interco-merge path (verified by CSV diff; incl. the coal_warm
  same-line VLSU tail = 124×7-cyc + 4×10-cyc merged hits). Proves the extraction is faithful — the
  par_coalescer merge == the interco merge, exactly.

**Open-loop payoff:** none expected, and none seen — by design (the dominant residual is already
fixed/inherent; see the design-workflow finding). The value is *structural foundation* for the
remaining Phase-1 increments and eventual closed-loop fidelity. Structure map:
`prompt/insitu_cache_structure_map_2026-06-15b.md`. Plan: `prompt/insitu_cache_dev_plan_2026-06-15.md`.

---

## 2026-06-15 (later) — RTL deep-read: microarch/arch reference rewrite + gap analysis + dev plan

**What.** Did a complete, verified deep read of the CachePool InSitu cache RTL (IP + cachepool
integration, ~22k lines) and produced three docs. Driven by a 15-agent workflow (10 parallel RTL/
model readers → 3 synthesis agents → 2 adversarial verifiers that re-checked claims against source;
both verifiers returned **high accuracy**). No code changed — docs only.

**Files (prompt/):**
- `insitu_cache_architecture_v2.md` — **rewritten** (471→635 lines) as the authoritative RTL
  microarchitecture+architecture reference. Tracked file (shows `M`); old version recoverable via git.
  Added §0.1 "Verified resolutions" capturing the 8 fact-check corrections (WordWidth=32 active not 64;
  L1BankFactor=2 hardcoded; config-512 geometry 1024/256/128/64KiB; refill burst is a line-width effect
  at fixed 128b refill, committed=Burst4 vs uncommitted-working-tree Burst1; dynamic_offset FF reset=14
  vs CSR resval=0; tcdm_id_remapper unused in CachePool; pseudo_dual modules live inside the wrapper;
  cache_sync_insn has 4 modes).
- `insitu_cache_rtl_coverage_matrix.md` — **replaced** (was 2026-06-08; old backed up to
  /tmp/coverage_matrix_2026-06-08.bak) with the RTL-vs-GVSoC gap analysis (arch + microarch + full
  matrix). Untracked.
- `insitu_cache_dev_plan_2026-06-15.md` — **new** phased GVSoC dev plan (Phase 0 done → Phase 1
  structural per-core controller + par_coalescer + bypass → Phase 2 Tile/Group shared-bank substrate →
  Phase 3 caps → Phase 4 SPM+flush/sync → Phase 5 AMO → Phase 6 bank-conflict → Phase 7 async-Spatz).
  Untracked. Applied the verifier fix: Phase 0 re-scoped to **DONE** (closed-loop hang already fixed/
  committed core 3d712809/pulp d8abb08; vfadd 15/15), residual closed-loop gaps reassigned to Phase 4
  (DMA/flush) + Phase 2 (topology); resp/wt-FIFO "quick win" reworded (counters not yet wired).

**Key RTL facts now documented (corrected understanding):** Group(4 tiles)→Tile(4 CC + 4 per-core L1
ctrls)→CC; NumL1CacheCtrl=NumCores (one cache/core), fully-shared L1 via per-lane tcdm_cache_interco +
remote ports + inter-tile xbar with register-programmable mapping + runtime bank partitioning; per-core
ctrl = single wide-line cache + par_coalescer (equal-window CSHR, hitmap, last-writer-wins wide merge,
rsp_spliter) + 2:1 scalar bypass reqrsp_xbar + 4-beat refill burst FSM; 7-state core FSM; 7-state
flush/sync FSM (4 cache_sync opcodes, CheckPendDrainCycles=20); the GVSoC model is structurally v1
(4 address-interleaved ctrls + hashed interco) and matches none of the shared-L1 substrate → Phase B.

**Memory:** [[rtl-integrated-topology]] updated to point at these docs. No commit (docs; per the
docs-stay-local convention). Related: [[insitu-cache-closedloop-state]].

---

## 2026-06-15 14:17 +0200 — Closed-loop Spatz bring-up: cache runs vfadd end-to-end; open-loop regression fixed

**Status:** committed — core `3d712809`, pulp `d8abb08` (pushed force-with-lease to forks;
parent pointer bumped locally, not pushed). Files: core `models/cache/insitu/{insitu_cache_controller.cpp,
insitu_cache_controller.py,insitu_cache_interco.cpp,insitu_cache_config.py,insitu_cache_tile.py}`,
pulp `pulp/snitch/snitch_cluster/snitch_cluster.py`.

**What.** Made the InSitu cache work CLOSED-LOOP on `--target=spatz --target-property
use_insitu_cache=True` — `examples/spatz/test-riscvTests-vfadd` now PASSES all 15 TCs
(`retval=0, cycles=58001`), where it previously hung at boot.

**Why it hung (4-bug cascade, all fixed; gated to the cluster config):**
1. *No data modelling* — cache was a pure timing overlay; every load returned garbage → program
   derailed into a bogus HTIF syscall (router livelock). Added per-line `line_data_` flat store +
   `exchange_line_data()` (serve reads / apply writes / install refills), all gated behind
   `carry_data_ = inline_sync_miss_ || functional_writethrough_`.
2. *Write-back invisible to HTIF backdoor* — `functional_writethrough`: every write also pushes its
   real bytes straight to backing memory (via the evict port) so the ISS/HTIF backdoor reader sees
   them.
3. *Refill-address rewrite deadlock* — `wide_axi` rewrites the refill req addr in place
   (subtract remove_offset); `refill_resp_handler` re-decoded set/tag from the mutated addr → never
   matched the pending line → MSHR never drained. Fixed: stash `pending_refill_addr_`.
4. *LSU synchronous-slave protocol* — spatz uses the **v1 ISS** (`iss/`, NB_OUTSTANDING off); all 3
   snitch LSUs accept only synchronous `IO_REQ_OK` (PENDING/DENIED fatal; re-entrant resp() aborts).
   `inline_sync_miss`: misses that resolve synchronously complete INLINE (return OK like a hit, no
   park/resp); write-commit backpressure → ADDED LATENCY instead of DENIED.

**The actual data bug (not DMA/flush):** wide-access spanning. The interco interleaves controllers
at 4-byte granularity (`dynamic_offset=2`, bits[3:2] WITHIN the line), so an 8-byte memcpy store
routed wholesale to ctrl0 left ctrl1's copy of the upper word stale. Fix: interco now SPLITS an
access crossing the granule, routing each byte-range to its owning controller (gated
`num_outputs_>1` → calib with `num_outputs=1` is byte-identical). vfadd is cache-unaware, so the
split alone fixes it. A flush/invalidate (`flush_all()` + `i_FLUSH` ports, tile `i_FLUSH(ctrl)`) is
implemented cache-side but DORMANT (not wired to the cluster L1D peripheral) — kept for future
cache-aware DMA-staging kernels.

**Open-loop regression — ROOT-CAUSED & FIXED (this was the commit blocker).** The uncommitted work
regressed calib (fmatmul M32 +3.9→+7.5, coal_cold 0.4961→0.6531) deterministically. Cause:
`make_cachepool_512_config()` (the shared base factory) set `inline_sync_miss=True` /
`functional_writethrough=True`, and the open-loop calib config DERIVES from it
(`make_cachepool_512_calib_config()` → `cfg = make_cachepool_512_config()`), inheriting the flags.
With `inline_sync_miss=True` the calib miss path took the inline-completion branch that stamps
`refill_lat` directly and never calls `reserve_install_pipe`, so the `defer_refills` occupancy
serialization (§10) was bypassed → miss throughput/latency inflated to the pre-occupancy numbers.
(The earlier inspection-bisect was blind because the *installed* `.py` under `install/generators/`
was never refreshed during quick `.so`-only rebuilds — the run always saw the stale True flags.)
**Fix (Option B):** the two flags are DRIVER/integration flags, not cache geometry — removed them
from the base factory (left at field default False, so calib/conventional/legacy all inherit the
calibrated path) and set them explicitly at the closed-loop cluster site (`snitch_cluster.py`,
which always needs them: the LSU protocol requires a synchronous slave + functional coherence).

**Verification (clean full build `make all TARGETS="insitu_cache_calib spatz:use_insitu_cache=True"`):**
- Open-loop calib: fmatmul M32 mean Δ **3.9** (hit +3.3), coal_cold wide @ML50 **0.4961** — both
  exactly the fix #5 targets.
- Closed-loop: vfadd all 15 TCs PASSED, `retval=0 cycles=58001`.
- No temp diagnostics left in the C++; `defer_refills=False` (Spatz default) path untouched.

Related: `prompt/insitu_cache_calib_report.md §10` (occupancy model), `[[insitu-cache-closedloop-state]]`,
`[[insitu-cache-gap-state]]`. Open follow-up: closed-loop cycle comparison vs RTL needs geometry
reconciliation (GVSoC spatz ≈ 4-core vs RTL 16-core CachePool traces).

---

## 2026-06-13 (later) — Phase-B fix #5: per-cycle output arbitration (THE hit-latency lever)

**Status:** committed — core `6362b3da`, pulp `f0706bc` (local; not yet pushed). This is the
big real-kernel alignment result: it closes 85–97% of the per-access latency gap on 4 of 5
kernels. Driven by taking the §6 "fix the hit-path serialization" item.

**Diagnosis.** A latency-component discriminator (env-gate each queue-wait term, re-measure fft —
whose misses align so shared paths are isolable) pinned the residual on the **interco output
arbitration**, NOT the per-set bank: removing the bank wait moved fft by 0.1 cy; removing the
output wait collapsed it +36.7 → +3.9. This overturned the prior abstract hypothesis (set_busy)
*and* the §8 "gemv is inherent cascade" conclusion.

**Root cause.** `output_busy_until_` was a monotonic per-output busy-until cyclestamp — it
accumulates across cycles, modelling sustained 1/cyc backpressure. Correct for CLOSED-LOOP (Spatz:
the core stalls on the returned latency) but DOUBLE-COUNTS in open-loop replay, where the trace's
t_issue already encodes the RTL's cross-cycle backpressure → ~+33 cy phantom hit inflation.

**Fix.** New `per_cycle_output_arb` interco mode: reset the accept counter each cycle, serialize
only genuinely same-cycle requests (`output_accept_width`/cyc, default 1). Mode tracks the trace's
**injection semantics**: default accumulate (Spatz + max-rate synthetic phases that rely on
accumulate backpressure for saturated throughput); per-cycle for real-kernel replay (opt-in via
`INSITU_CALIB_PER_CYCLE_ARB=1`, set by the replay tool).

**Result (clean sequential before→after, mean Δ vs RTL):** fmatmul M32 26.5→**3.9**, fft 34.6→
**3.2**, fmatmul M128 62.7→**6.4**, gemv 76.1→**2.6**, fdotp 75.0→**21.1**. Hit Δ now +0.3…+4.5
on EVERY kernel. fdotp's hit path is exact (+0.3); its whole residual is the miss-path cascade
(+62.7, unchanged) = the inherent open-loop limit. gemv → +2.6 proves it was a model defect, not
inherent.

**No regression.** Accumulate `else`-branch is byte-identical to the original → synthetic phases
(coal_cold 0.4961, evict 0.1659, warm_hit 10, cold_miss 67) and closed-loop microbench (7 lines:
3.88/3.73/1.98/3.70/3.73/2.05/3.73) provably unchanged (they never set the env knob).

**Methodology note.** gvsoc writes `gvsoc_config.json` into the cwd, so concurrent replay
processes sharing one cwd race on it (±0.3 cy nondeterminism). All numbers from strictly
sequential runs (verified reproducible).

**Files.** core `6362b3da`: `insitu_cache_config.py` (+per_cycle_output_arb, +output_accept_width;
calib config left at default + comment), `insitu_cache_interco.{cpp,py}` (two-mode arbitration).
pulp `f0706bc`: `insitu_cache_calib/__init__.py` (env knob). parent:
`insitu_cache_realkernel_alignment_2026-06-12.md` §9 + §8 NB + resolution banner, this log,
`weekly_report_2026-06-15.md`.

---

## 2026-06-13 — Phase-B fix #4 (scalar bypass) + fix #2 (same-cycle MSHR-drain coalescing)

**Status:** committed in `core` `49c377d9` (continuation of the real-kernel alignment work; fix #1
was pushed earlier as `37982db9`). Both are RTL-faithful refinements with marginal real-trace
impact; the dominant gemv/fdotp residual remains the open-loop refill cascade (not a cache-model
fix — see `insitu_cache_realkernel_alignment_2026-06-12.md` §6/§8).

**Fix #4 (APPLIED) — scalar bypass port.** The Snitch scalar request goes through the RTL 2:1
`reqrsp_xbar`, not the VLSU coalescer: a read hit returns ~3 cy and doesn't contend for the per-set
bank. New `controller.scalar_bypass_port` / `scalar_hit_latency_cycles`, fed by an
`interco.forward_initiator` knob that tags each forwarded req with its input-port index (via
`IoReq::set_initiator(int)`, V1 io.hpp). All three default OFF → Spatz path byte-identical; calib
DUT sets port=4, latency=3. Trims the scalar-port Δ but it's a minor fraction of each kernel mean.

**Fix #2 (APPLIED) — same-cycle MSHR-drain coalescing.** The `par_coalescer` merges same-cycle
same-line reads into one entry, so they retire together. `fsm_drain_mshr` now advances the
per-subarray stagger only when a pending reader's `arrival_cycle` differs from the previous one,
not once per reader. Correct RTL behaviour but **zero measured impact** on these traces (few
same-cycle same-line readers survive to the drain). Kept as a harmless refinement.

**Result (mean per-access latency Δ vs RTL):** fmatmul M32 +27.0→**+26.5**, fft +34.7→**+34.6**,
fdotp +75.0 (flat), gemv +76.1 (flat). **Synthetic regression fully unchanged** — microbench 7
lines, cold_stream wide 0.254, evict wide 0.166, warm_stream 7/7, coal_cold 0.496, warm_hit 10,
cold_miss 67.

**Files.** core (`49c377d9`): `insitu_cache_config.py` (+scalar_bypass_port, +scalar_hit_latency_cycles,
+interco.forward_initiator; calib config wires port=4/lat=3), `insitu_cache_controller.{py,cpp}`
(is_scalar branch + arrival-cycle-aware drain stagger), `insitu_cache_interco.{py,cpp}`
(forward_initiator tagging). parent: `insitu_cache_realkernel_alignment_2026-06-12.md` §8, this log.

---

## 2026-06-08 (later) — Phase-B fix #1: pipelined-bank set_busy (real-kernel hit-inflation)

**Status:** fix #1 implemented + verified (ready to commit). Fix #3 attempted + reverted. Fixes
#2/#4 scoped. Driven by the real-kernel alignment finding (`insitu_cache_realkernel_alignment_2026-06-12.md`).

**Fix #1 (APPLIED) — `bank_accept_cycles` (default 1).** The per-set `set_busy_until_` stamp now
advances by the bank ACCEPT interval (pipelined, 1 cyc) instead of the full hit latency, so
back-to-back accesses to a hot/reused set pipeline rather than serialize. This was the #1 cause of
the real-kernel per-access latency over-prediction (hot-set serialization on multi-port reuse).
Result: meanΔ vs RTL — fmatmul M32 +61→**+27**, fft +73→**+35**, fmatmul M128 +85→**+63** (big
wins); gemv +77→+76 (neutral); fdotp +71→+75 (slight). **Synthetic calib + microbench fully
unchanged** (the stamp only fires under same-set contention, which the synthetic distinct-set/
coalesced phases avoid) — warm hit 10, streaming 7, cold-miss ML+17/+13, cold_stream 0.254,
coal_cold 0.496, coal_warm 3.37, microbench 7 lines identical. So fix #1 is a strict improvement
with no regression.

**Fix #3 (single-outstanding-refill backpressure) — ATTEMPTED, REVERTED.** A cache-side gate
(DENY a new miss while a refill is outstanding) backfired (gemv/fdotp miss latency +400-600).
Root cause: the gate stalls misses but not hits, so a replayed hit to a not-yet-refilled line
runs ahead and waits — but in the RTL the *core* stalled on that line's miss. **Open-loop trace
replay can't reproduce the core's data-dependency stall when the cache's miss-timing differs.**
Same wall as the coal_cold deferred-completion NO-GO. Machinery removed.

**Fixes #2/#4 scoped** (structural coalescer, scalar bypass) — secondary; neither addresses the
gemv/fdotp refill-cascade residual (which is partly inherent to open-loop replay). Left as clean
follow-ups.

**Files.** core: `insitu_cache_config.py` (+bank_accept_cycles), `insitu_cache_controller.{py,cpp}`
(pipelined set_busy). pulp: `insitu_cache_calib/__init__.py` (INSITU_CALIB_COALESCE_MAX_LAT debug
knob from the discriminator). parent: `insitu_cache_realkernel_alignment_2026-06-12.md` §8.

---

## 2026-06-08 (later) — Alignment check vs RTL run_2026-06-12 → ALIGNED-CONFIRMED

**Status:** assessment only (doc update: calib report §14). No code change.

**What.** Verified the model still works post-upstream-pull and re-checked alignment against the
latest RTL reference `ManyRVData_rebase/reports/cache_calib/run_2026-06-12` (BurstLength=1, DUT
`93d1c11`). Model smoke + full wide-mode sweep ran clean. The RTL run's REPORT.md states it is
**cycle-identical to the Jun-3 char_bl1 baseline (0 mismatches, 20 phases × 4 ML)** — the RTL
timing-opt batch is performance-neutral, so the reference is unchanged from the calibration
baseline; this is a post-pull re-confirmation.

**Result — ALIGNED-CONFIRMED** (independent GVSoC re-measure + RTL re-parse + adversarial audit,
workflow `wwvh8r7bx`, 3 agents). Every number reproduced exactly on both sides. Throughputs +
headline latencies match within tolerance: warm hit 10, streaming 7, write 8, RAW 7, cold-miss
ML+13 exact across the sweep; coal_warm 3.37 vs 3.28; coal_cold thr ≤6.2% across the full ML
sweep; cold_stream ≤10% (L≥50); evict ~6%; memory traffic matches. All divergences are the
**pre-documented residuals** (saturation hit ceiling, coal_cold latency/out shape, evict out +
write-allocate latency, cold_stream low-ML plateau) — **none introduced by the 2026-06-08 pull**
(calib byte-identical). Coverage gaps (no model issue): `bw_hit_1/2/3port`, `mshr_depth_1p` have
no GVSoC trace. Audit nits (cosmetic): a "≤6%" bucket header understated 4 cells (in-line figures
correct); CLAUDE.md's ML+17 cold-miss headline is the Burst=4 default (Burst=1 here is ML+13, as
the calib report already notes). Full table: calib report §14.

**Files.** `prompt/insitu_cache_calib_report.md` (§14), `prompt/WORKLOG.md`.

---

## 2026-06-08 — Pull upstream: rebase dev branches + engine bump + elfutils build dep

**Status:** rebased + build-verified + parent committed locally + **dev branches pushed to the
forks** (`--force-with-lease`). Recovery SHAs: core `edfc99d2`, pulp `cd04829`, engine `a6d92918`.

**What.** Pulled the latest upstream into both dev branches.
- Synced fork views from real `gvsoc/gvsoc-{core,pulp}` (fetch upstream): core/master 15
  behind, pulp/master 7 behind, both 0 ahead (clean ff).
- Rebased `insitu-cache` onto `upstream/master` in each: **no conflicts** — all 6 core + 7 pulp
  cache commits replayed. core `edfc99d2→9364002e`, pulp `cd04829→b8d08e4`. Local `master`
  refs fast-forwarded to upstream.
- **Engine bump `a6d92918→5863c25e`** (origin/main, +15): required — upstream core
  `iss/iss_v2/riscv.py` now calls `Component.add_libraries(['dw','elf'])`, added to the engine
  in `a3d410b4`. (Error before bump: `'SnitchFast' object has no attribute 'add_libraries'`.)
- **New upstream build dep — elfutils headers.** Upstream `e1346286/33945126` made the ISS
  trace resolve PC→symbol via libdw (`<elfutils/libdwfl.h>` + `add_libraries(['dw','elf'])`).
  The host (AlmaLinux 8) has the runtime libs but not `elfutils-devel`, no passwordless sudo.
  Resolved without sudo: `scripts/setup_elfutils_headers.sh` dnf-downloads the matching
  `elfutils-devel-0.190` RPM into gitignored `third_party/elfutils-devel/`, extracts the headers,
  and makes the missing `libdw.so` link symlink. Build exports `CPATH` (include) + `LIBRARY_PATH`
  (link). Documented in CLAUDE.md "Build environment". (User-approved: provide elfutils-dev.)

**Verification.** `make build TARGETS="insitu_cache_calib insitu_cache_microbench
spatz:use_insitu_cache=True rv64"` clean (exit 0) with `CPATH`/`LIBRARY_PATH` set. Calibration
**byte-identical post-rebase**: warm hit 10, cold miss 67 (BL4) / 63 (wide), coal_cold wide
0.496 (mem_rd 32), cold_stream wide 0.254, coal_warm 3.37/lat 7, microbench hit_repeat_r4 1.98.
Used `make build` (NOT `make all`, which would `git submodule update` and reset the rebase to
the stale parent pointers — so the parent pointer bump below must precede any `make all`).

**Files / pointers.** parent: submodule bumps core/pulp/engine + `scripts/setup_elfutils_headers.sh`
(new) + `CLAUDE.md` (elfutils build-env note) + this log. Submodule working trees: rebased
(content of the cache files unchanged → objects identical → calib unaffected).

**Pushed (2026-06-08):** core `insitu-cache` `6347ea65→9364002e` (forced), pulp `f80254b→b8d08e4`
(forced); fork `master` refs fast-forwarded to upstream (core `26c86fd4→6ca5e8f9`, pulp
`abcddd6→4319260`). Remote == local verified. Parent `main` stays local per the
submodules-only-push preference.

---

## 2026-06-04 (later) — Streaming read-hit pipelining: latency 10 → 7

**Status:** implemented + verified (regression-clean); committed — core `edfc99d2`,
pulp `2282baa` (local; not pushed).

**What.** Modelled the RTL read-hit pipeline fill/drain so a streaming hit costs 7 cyc and
an isolated hit 10 (both MemLatency-independent). New gated knob
`InsituCacheControllerConfig.streaming_hit_latency_cycles` (default -1 = OFF). In the VALID
read-hit branch of `insitu_cache_controller.cpp`, base latency =
`streaming + min(hit_latency-streaming, cycles_since_last_read_hit)` — a per-controller
warmth gradient anchored on `last_read_hit_cycle_`. The calib config sets it to
`hit_latency-3` (=6 → interco(1)+6 = 7 streaming). READ hits only (writes, forwarded reads,
and MSHR-drain responses keep their own latency).

**Why a gradient, not a binary warm/cold.** The RTL has three decoupling registers
(coalescer req-spill, resp-spill, rsp_spliter/output-FIFO) that drain 1/cycle when idle, so
the latency rises smoothly with the injection gap. The design workflow's RTL grounding
(`wbkqdkn9u`) surfaced the exact gap-sweep: gap0→7, gap1→8, gap3→10, gap7→10. The gradient
reproduces all of it; a binary model would give only 7 or 10.

**RTL grounding (workflow `wbkqdkn9u`, 3 agents).** Parallel RTL-report reader + RTL-hit-path
reader + synthesis. Mechanism confirmed: isolated 10 = end-to-end fill of every registered
stage; streaming 7 = steady-state once the three decoupling registers stay occupied; both
config-fixed, MemLatency-independent (REPORT.md §3.1, CHARACTERIZATION.md §3, the 7/7/10 CSV
signature). The synthesis also scoped the outstanding-distribution gap (Change B) as a
deferred per-resource occupancy item.

**Verification (ML50, target insitu_cache_calib).** Added `bw_hit_gap{0,1,2,3,7}` traces to
verify the gradient — GVSoC tail latency 7/8/9/10/10 **exact** vs RTL; gap≥1 throughputs also
exact (gap1 0.476 vs 0.467, gap3 0.244 vs 0.243, gap7 0.124 vs 0.124). warm_stream latency
10→7; coal_warm latency 10→7 (7/7/7) and throughput 3.12→3.37 (RTL 3.28, +2.7%, closer in
abs). Misses unchanged (cold_miss 67/63, cold_stream 0.254, coal_cold 0.496); writes/RAW
unchanged (8/7). **Spatz/microbench no-op:** build clean; microbench 7 CALIB_REPORT lines
byte-identical (hit_repeat_r4 1.98). **Spatz-safe:** pure inline-OK latency adjustment, knob
default-OFF.

**Honest residual.** With the latency now correct (7), the *saturation* single-port hit
throughput reads ~0.91 (warm_stream/bw_hit_gap0) vs RTL 0.865 (~5.7% over) — the correct
latency unmasked a small accept-ceiling over-prediction (RTL accepts ~0.955/cyc, model
~1.0). Separate sub-cycle accept-rate item; gap≥1 (below the ceiling) matches exactly.

**Files.** core: `insitu_cache_config.py` (+streaming_hit_latency_cycles, calib wiring),
`insitu_cache_controller.{py,cpp}` (gradient + last_read_hit_cycle_). pulp:
`insitu_cache_calib/gen_traces.py` + `traces/bw_hit_gap*.trace`.

**Open (Change B — THREE approaches tried + reverted → confirmed needs a structural refactor):**
outstanding *distributions* — coal_cold out 128 vs 56 (and lat 146 vs RTL 82), evict out 32
vs 4. Throughputs already match. Empirically ruled out the incremental fixes (all gated
default-OFF, defer_refills-only, cold_stream/evict held throughout):
  1. **Accept-depth cap** (`max_inflight_reads`=56, completion-multiset, DENY-when-full):
     coal_cold regressed 0.496→0.183 (lat→250). The capped same-line followers serialize on
     `set_busy` (they "hit" the inline-VALID-but-not-ready line), complete late, never retire
     → cap stuck → throughput starved.
  2. **Ride-the-refill** (a not-ready read hit skips `set_busy`, completes at ready_cycle):
     barely moved coal_cold (lat 146→142, out still 128) — proving the latency floor is the
     *drain backlog depth* (128 in flight), not `set_busy`.
  3. **Cap + ride-the-refill combined:** still regressed (0.214 / lat 234 / out 85) — the
     DENY/retry churn without faster refills.
**Structural conclusion:** the `refill_drain_cycles` cyclestamp serves DOUBLE duty — it sets
both the miss *throughput* AND the spread-out `ready_cycle`s (hence the latency). cold_stream
relies on it for throughput (0.254); coal_cold inherits its deep backlog as latency (146).
RTL instead gets coal_cold's throughput from the **cache accept depth** (≈56) with **fast
pipelined refills** (→ lat 82). Matching all of {thr, lat, out} therefore needs a real
occupancy refactor that DECOUPLES the throughput limiter (refill+writeback rate / accept
depth) from the per-access latency (refill completion) — i.e. a deferred-completion miss path
(line stays READ_PEND until a scheduled refill-done event; followers MSHR-merge), which is
exactly the "heavy event-pool" deliberately avoided in the §10 occupancy model. cold_stream's
match (32/95/0.254, requester-bound) is the regression tripwire any such refactor must hold.
**Decision pending:** high effort + regression risk for a diagnostic-out + one-phase-latency
gain, when all throughputs already match — so left for an explicit go-ahead.

**2026-06-04 — deferred-completion design workflow (`wuw0hl7ph`, 4 agents) → adversarial NO-GO.**
Ground (exact RTL timing + GVSoC event API) → design the event-scheduled deferred-completion
miss path → adversarial verify. Verdict **NO-GO**, two fatal flaws, both confirmed empirically:
  - *miss_fifo throttle:* the calib config inherits `miss_fifo_depth=4`; moving its decrement
    to event-fire time would clamp coal_cold to 4 outstanding → collapse (attempt #1 redux).
    Fixable (raise the depth).
  - *writeback-pairing throughput is false for the GVSoC trace:* coal_cold_4port is read-only,
    32 distinct lines into a 1024-entry cache → every miss lands in an INVALID way → **mem_wr=0**
    (VERIFIED: `[CALIB_MEM] mem_rd=32 mem_wr=0`). RTL coal_cold has **mem_wr=32** because the
    shared RTL TB's sets were pre-dirtied by earlier phases. So GVSoC and RTL coal_cold are
    DIFFERENT scenarios. The current GVSoC throughput match (0.496 vs 0.467) is an *artifact* of
    the followers' `set_busy` serialization (≈ RTL's writeback drain by coincidence). Removing
    that serialization — the very thing the deferred-completion fix does to cut latency — would
    make throughput OVERSHOOT to ~0.9 unless real writebacks pair.
**Net:** the faithful fix needs THREE things together — (1) regenerate coal_cold to pre-dirty
its 32 sets so writebacks fire (mem_wr=32, replicating the RTL TB state); (2) the
deferred-completion event path (followers MSHR-merge → latency ~82); (3) raise miss_fifo_depth
+ reset/event hygiene. That is substantial trace surgery + a risky MSHR-path event refactor, and
the corrected design has not been re-verified. Given all throughputs already match and the gap
is one phase's diagnostic out-count + latency, this is parked for an explicit decision rather
than barrelling past the NO-GO. Full analysis: workflow `wuw0hl7ph` output.

## 2026-06-04 (later) — coal_cold occupancy refactor: design↔verify loop → NO-GO on code, doc deliverable

**User direction:** "do the occupancy refactor" → then "re-verify, then implement." So I ran a
3-round design↔verify loop (workflow `w4ohzna7g`, agents measuring on the live tree). Final
verdict **GO-WITH-FIXES = NO-GO on any code refactor; GO only on documentation**. The loop
*proved* (not asserted) the refactor is futile/harmful:

- **Deferred completion is a measurement no-op.** `t_resp = t_issue + get_full_latency()`
  (calib_driver.cpp:304); follower latency is determined at issue (controller.cpp:654-660).
  coal_cold lat = ML+96.5 lockstep (106.5/146.5/196.5/296.5) — a +6-cyc/line install ramp tail,
  not a deferrable stagger. Deferring `resp()` moves the metric by zero.
- **Pre-dirty regresses:** measured 0.31 thr / 169 lat / 96 out (double-reserves the install pipe).
- **Accept-throttle breaks coalescing:** DENYs cold followers before MSHR-merge; port-0 race.
- **thr/lat/out are one coupled knob:** D-sweep D={0,1,3,6,9} → coal_cold {0.653,0.653,0.496,
  0.365,0.288}, cold_stream {0.408,0.408,0.254,0.145,0.102}; D=3 is the joint optimum.

**Decision:** did NOT implement any refactor (no ClockEvent / finish_refill / accept-throttle /
new knob; even the "optional" miss_fifo=64 bump omitted — verified inert: in wide mode the memory
returns OK synchronously so miss_fifo never fills, peak ~1). **Landed only docs:** calib report
§13 (the four proofs + the Phase-B scoping) + a gen_traces.py comment warning not to pre-dirty
coal_cold. The model stays well-calibrated: all throughputs + headline latencies match;
coal_cold lat/out are coupled RTL-shape residuals whose only convergent fix is a Phase-B
controller same-line MSHR-collapse + ~14-line install cap (scoped, unproven, not implemented).

**Spatz/inline byte-identity:** trivially held — no model code (.cpp/.py) changed; the
gen_traces.py edit is comment-only (traces byte-identical after regen). **Files:** core: none;
pulp: `insitu_cache_calib/gen_traces.py` (comment); parent: `prompt/insitu_cache_calib_report.md`
§13, `prompt/WORKLOG.md`.

---

## 2026-06-04 — Phase-B input par-coalescer: close coal_warm (0.06 → 3.12 acc/cyc)

**Status:** implemented + verified (regression-clean); ready to commit (core + pulp).

**What.** Modelled the RTL input `par_coalescer` as a **same-cycle, same-line read-HIT merge
inside `insitu_cache_interco`** (the per-cycle arbitration point), default-OFF. The first
read of a line in a cycle forwards normally; same-cycle followers to the same line inherit
its latency and do **not** re-consume the per-output accept slot — so N VLSU words to one
line cost ~one bank access (RTL: ~4× the single-port hit rate). New gated knobs on
`InsituCacheIntercoConfig`: `enable_input_coalesce` (False), `cache_line_bytes` (64),
`coalesce_max_latency` (-1). The calib config sets them (coalesce on, threshold = hit+7 ≈ 16).

**Why the interco, not the controller (overrode the design's first pick).** A controller-only
merge can't close the gap: the interco's `output_busy_until` serializes the 4 same-cycle
reqs (grows 4/cyc while `now` grows 1/cyc), capping throughput at ~1/cyc regardless of the
controller. Merging at the interco removes that serialization at its source.

**Two fixes the first build exposed:**
1. *Only 3 of 4 ports merged.* The coal_warm trace preloaded via **port 0**, so port 0
   entered the measured phase ~32 cyc behind ports 1–3 (its preload tail) → it never shared
   a cycle with them. Fix: preload via the **scalar port (4)** so all four VLSU ports stay
   cycle-aligned. (gen_traces.py)
2. *coal_cold regressed 0.49 → 0.65.* The inline refill makes a cold line VALID immediately,
   so cold same-cycle followers were wrongly merged as warm hits. Fix: `coalesce_max_latency`
   — only a forwarded read whose latency is warm-hit-sized (≤16) seeds the window; a
   refill-sized "hit" (≥60) does not, so cold followers fall through to the MSHR-merge path.

**Result (ML50):** coal_warm **0.06 → 3.122** acc/cyc (RTL 3.282, −4.8%), latency flat 10
(RTL 7 — the known hit-pipelining residual). coal_cold held at **0.494** (RTL 0.467),
mem_rd=32. **All other phases byte-identical** (warm_stream 0.877, warm_write 8.0/0.478,
raw_same_word 7.0, cold_miss wide 63, cold_stream wide 0.254, evict mem_wr 1024). Spatz/
microbench no-op proven: build clean; microbench 7 CALIB_REPORT lines unchanged; merge
gated off (`make_cachepool_512_config` leaves `enable_input_coalesce`=False).

**Spatz-safe by construction.** Pure same-cycle latency adjustment on the already-inline-OK
hit path: never holds a req, never defers a resp, never returns non-OK, never touches
`IoReq::get_args()`. Default-OFF; only the calib config flips it.

**Scalar bypass — deferred (low value).** The RTL scalar "~60" is the *isolated* cold-miss
latency, which the model **already** matches (`cold_miss_isolated` = 63–67). The sample
trace's idx11=175 is *memory-refill contention* (port 0 issues 4 serializing misses at the
same instant) that RTL would also show; it is not a cache-path issue. Modeling the bypass
precisely is a memory-arbitration refinement on a synthetic trace, not a headline metric.

**Files.** core: `insitu_cache_config.py` (interco knobs + calib wiring),
`insitu_cache_interco.{py,cpp}` (merge logic). pulp: `insitu_cache_calib/gen_traces.py`
(coal_warm preload via scalar port).

---

## 2026-06-03 04:30 +0200 — Calibration check vs REPORT_BL1.md (20-phase BurstLength=1)

**Status:** assessment only (no code change). Doc-only update (calib report §9.1).

**Result — partially calibrated.** Ran every GVSoC trace in wide mode @ML50 vs the RTL
`REPORT_BL1.md` 20-phase table:
- ✅ **Matches:** all hit/write/RAW latencies+throughputs (warm hit 10, warm write 8, RAW 7,
  warm_stream 0.877 vs 0.865, warm_write_stream 0.478 vs 0.489) — the report's "unchanged"
  invariant holds; cold-miss latency ML+13 exact across the sweep; memory-traffic structure
  (cold_stream rd=64, coal_cold rd=32, evict rd=2048/wr=1024) on every miss phase;
  cold_stream max_outstanding=32 (requester-bound).
- ⚠ **Over-predicts wide-mode miss throughput:** cold_stream 0.41 vs 0.243 (1.7×),
  coal_cold 0.65 vs 0.467 (1.4×, out 128 vs 56), evict 0.49 vs 0.177 (2.8×, out 32 vs 4).
- ❌ coal_warm 0.06 vs 3.282 — pre-existing input-coalescer gap (not BL-related).

**Root cause:** GVSoC bounds outstanding by the per-port budget (32) with flat per-access
latency (63); RTL bounds by cache-internal resources that differ per access type (MSHR
accept ~56, write-allocate accept ~4) AND inflates latency under load (→100/82/98). So
GVSoC pegs at the ~0.5 plateau for every miss-heavy phase; RTL varies 0.18–0.47. Closing it
needs the cache-occupancy model (deferred refill + per-resource caps + under-load latency)
— the recurring Phase-B item (calib report §5(7)/§9.1).

**Files touched.** `prompt/insitu_cache_calib_report.md` (§9.1).

---

## 2026-06-03 20:27 +0200 — Occupancy model: close wide-mode miss throughput (cold_stream/coal_cold/evict)

**Status:** committed — core `6347ea65`, pulp `f80254b` (pushed); parent committed locally.
This commit also carries the 2026-06-03 03:45 wide-refill experiment work (same files).
Builds clean; default + spatz provably unchanged.

**Context.** §9.1 showed GVSoC over-predicts wide-mode miss-heavy *throughput* (inline
resolution → flat 63-cyc latency, no contention; only the per-port budget bound). Ran a
research+design multi-agent workflow (7 agents) to ground the fix in the RTL resource
structure, then implemented a **simpler** mechanism than the proposed event-pool rewrite.

**What was done (all gated behind new `defer_refills`, default False = inline = spatz path):**
- `insitu_cache_controller`: `refill_resp_handler` serializes refill *completion* cycles via
  a monotonic cyclestamp `refill_drain_busy_until_` (+`refill_drain_cycles` per completion;
  refill_lat REPLACED, no double-count) → queued-miss latency inflates under load → the
  driver's slot-deferral paces issues → install-rate-bound throughput + latency ramp.
  `issue_eviction` advances the same cyclestamp (+folded penalty) so writebacks share the
  pipeline (evict ≈ ½ read-miss rate). Reset in reset(); knobs read in ctor; mirrored in
  controller.py.
- New config knobs (no-op defaults): `defer_refills` + `refill_drain_cycles` (these two
  produce the entire effect). Calib wide block (`__init__.py`) sets defer_refills=True,
  refill_drain_cycles=3 (env `INSITU_CALIB_REFILL_DRAIN`); make_cachepool_512_config (spatz)
  keeps defaults. (An adversarial-review workflow found 3 further knobs I'd added for a
  pool/DENIED approach — `max_outstanding_refills`/`writeback_outstanding`/
  `model_backpressure_denied` — were DEAD; removed them + factored the two cyclestamp
  advances into one `reserve_install_pipe()` helper.)
- `gen_traces.py`: cold_stream_long (already added) for the plateau.

**Calibration vs RTL BL1 (@ML50):** cold_stream 0.254 (RTL 0.243), coal_cold 0.494 (0.467),
evict_dirty 0.166 (0.177), evict_wb 0.166 (0.178), cold_miss isolated 63 (=ML+13), lat ramp
63/95/125 (RTL 63/100/130). **All four miss-heavy throughputs within ~7%** (was 1.4–2.8×
over). Sweep: coal_cold ≤6%, cold_stream ≤10% (24% @ML10 — fixed drain can't match RTL's
flat install-cap at low ML).

**No regression:** default (BL4) calib unchanged (cold miss ML+17, cold_stream 0.0188, warm
hit 10, write 8/0.478, RAW 7, coal mem_rd 32); wide hits/writes unchanged; `spatz:use_insitu_
cache=True` builds (93 targets); microbench identical. Spatz-safe by construction
(defer_refills=False → inline path verbatim, no new non-OK).

**Verification.** Adversarial-review workflow (3 agents: C++ correctness + spatz-safety +
synthesis) → **GO-WITH-FIXES → GO**: confirmed no latency double-count, monotonic+reset
cyclestamp, head-of-line unaffected, defer_refills=False path byte-identical, no new non-OK
on any path. Applied its must-fix (removed 3 dead knobs) + nit (helper). Post-fix: all
numbers unchanged, builds clean (100 targets).

**Residuals (secondary):** per-phase max_outstanding + latency *distributions* (coal_cold
out 128 vs 56, evict out 32 vs 4) would need an explicit per-resource pool/event model
(future phase). Throughputs + latencies match. See calib report §10.

**Files touched.** `core/models/cache/insitu/insitu_cache_config.py`,
`insitu_cache_controller.{cpp,py}`, `pulp/insitu_cache_calib/__init__.py`,
`prompt/insitu_cache_calib_report.md` (§10).

---

## 2026-06-03 03:45 +0200 — Wide single-beat refill throughput experiment (mirror RTL)

**Status:** committed (with the occupancy round) — core `6347ea65`, pulp `f80254b`.
Builds clean; default-config calibration fully preserved.

**Context.** Mirrors `ManyRVData_rebase/reports/cache_calib/THROUGHPUT_EXPERIMENT.md`
(+ `char_bl1/*.csv`): RTL `refill_data_width=512` ⇒ BurstLength=1, misses pipeline (no
single-outstanding gate), deep memory queue; the binding limit becomes the requester's
32-outstanding budget (Little's law plateau ≈ 32/(ML+13) ≈ 0.5). RTL cold_stream jumps
0.018 → 0.243 (64-burst).

**What was done (toggle `INSITU_CALIB_WIDE_REFILL=1`; default config untouched).**
- `insitu_calib_mem`: new `serialize_refills` (default True) + `max_outstanding` (default 8)
  knobs. When False, refill reads run concurrently (no `mem_busy_until` one-at-a-time).
- `calib_driver`: a request now holds its per-port outstanding slot until the response
  returns (deferred slot-free via an inflight-completion multimap), so `outstanding_budget=32`
  genuinely binds (`max_outstanding` reads 32, not the prior artifactual 1). This is the
  §3 requirement. Verified non-regressive for the default config.
- `__init__.py`: `INSITU_CALIB_WIDE_REFILL` → refill_beat=cache_line (single beat),
  serialize_refills=False, max_outstanding=64, and miss_penalty=9 (cold miss ML+17→ML+13).
- `gen_traces.py`: added `cold_stream_long` (512 lines) to show the sustained plateau.

**Calibration (wide config) vs RTL bl1:**
- cold miss isolated = **ML+13** (23/63/113/213) ✅ exact across the sweep.
- mem_rd = **64** (one refill/miss) ✅; max_outstanding = **32** (ML≥50) ✅.
- **sustained plateau** (512-line stream, ML50) = **0.49** ≈ doc's `32/63 ≈ 0.5` ✅ —
  matches the doc's Little's-law plateau (the actual stated limit).
- 64-line burst throughput = 0.41 @ML50 (RTL 0.243) — over; the doc labels 0.243 a
  fill/drain short-burst artifact and computes the true plateau as ~0.5, which GVSoC hits.
  The residual is RTL's under-load latency inflation (lat_avg 100 vs my 63) from
  cache-internal miss-handling serialization — the same cache-occupancy gap as the
  calib report §5(7). Without the driver budget the wide config would run unbounded
  (~1/cyc); with it, bounded to ~0.5 — the doc's requirement is met.

**Verification.** `make build TARGETS=insitu_cache_calib` clean. **Default (serialized)
config fully preserved:** cold miss ML+17, cold_stream 0.0188, warm hit 10, write 8/0.478,
RAW 7, coal mem_rd 32, evict 0.0189/1024, microbench unchanged (max_outstanding now 32 vs
prior 1, no throughput change). Shared controller/config NOT touched this round
(miss_penalty=9 is a per-instance runtime override in the calib target) → spatz unaffected.

**Files touched.** `core/models/cache/insitu/insitu_calib_mem.{cpp,py}`,
`pulp/insitu_cache_calib/{calib_driver.cpp,__init__.py,gen_traces.py}`,
`prompt/insitu_cache_calib_report.md` (§9).

**Follow-up.** Exact 64-burst match (0.243) needs a cache-occupancy model that inflates
the under-load round-trip — the recurring deferred item (calib report §5(7)).

---

## 2026-06-02 11:29 +0200 — Commit all WIP + rebase dev branches onto upstream, bump engine

**Status:** committed (submodules pushed; parent committed locally).

**Commits.**
- `core` insitu-cache `233850f4` — "insitu-cache: calibration memory model + timing knobs".
- `pulp` insitu-cache `3d15e5d` — "insitu-cache: calibration + microbench testbench targets".
- parent `1e0586a` — docs/reports/worklog/rebase-tooling; parent `e1c7342` — submodule pointer bumps.

**Rebase / upstream pull.**
- Synced the `core` fork master from real upstream `gvsoc/gvsoc-core` (fast-forward
  `455488f8→26c86fd4`, +5 commits); `pulp` fork master already current.
- Rebased both `insitu-cache` branches onto `origin/master` via
  `scripts/rebase_dev_branches.sh` — **no conflicts** (core replayed 3 commits onto the
  5 new upstream ones). Force-with-lease pushed: core `671a27a5→233850f4` (forced),
  pulp `0d3625d→3d15e5d` (fast-forward).
- **Bumped `engine` `a8c57439→a6d92918`** — required: upstream core's new `fst_dumper`
  uses `Signal::description_set` (engine `3a6dd2dc`) and `memory_v3` advertises the
  `IoV2Sync` signature (engine `a6d92918`). gvrun unchanged (current).
- Gotcha: `make all` runs `git submodule update` which resets submodules to the
  parent-recorded SHAs — so the engine bump must be recorded in the parent (or use
  `make build`, which skips checkout) before building. Verified with `make build`.

**Verification.** `make build` of insitu_cache_calib / microbench / spatz / rv64 — clean
(116 targets, 0 errors; `fst_dumper` + `memory_v3` compile against the bumped engine).
Calibration metrics unchanged post-rebase: cold miss = MemLatency+17, warm hit 10,
write 8, RAW 7, cold-stream throughput 0.0188. Commit messages verified free of any
co-author / tool attribution. Parent submodule pointers == pushed remote SHAs.

**Note.** Parent (`main`) committed locally, not pushed (per the submodules-only push
preference). `.claude/` left untracked.

---

## 2026-06-02 10:47 +0200 — Close calib performance gaps: write path, forwarding buffer, writeback overlap

**Status:** uncommitted. Builds clean (calib + microbench + spatz:use_insitu_cache=True);
no regression on primary metrics.

**Context.** User asked to fill the documented performance gaps by further developing
the model. Closed the tractable ones (those not needing the Phase-B topology refactor).

**What was developed.**
- **Write path** (`insitu_cache_controller`): new `write_hit_latency_cycles` (write hit
  acks faster than a read returns) and `write_commit_cycles` (controller-wide
  write-commit backpressure — a write hit is DENIED while the prior write's commit slot
  is busy; upstream retries). Production config: 7 and 2.
- **Forwarding buffer**: new `fwd_hit_latency_cycles` + 1-entry `fwd_buffer_line_`. A
  read on the just-touched line forwards combinationally, **bypassing the bank** (no
  `set_busy` stall). Populated on hits only (cold-miss preloads don't populate it).
  Production config: 6.
- **Writeback overlap** (`insitu_calib_mem`): new `writeback_overlap` — eviction writes
  don't advance `mem_busy_until` (overlap the refill, as in RTL) but still count
  `mem_wr`. Enabled on the calib target's memory.
- All new controller knobs default to no-op; only `make_cachepool_512_config`
  (production) opts in. New config fields wired through `.py` + `.cpp`.

**Verification (@ ML50) — gaps closed:**
- warm-write latency 10 → **8** (RTL 8).
- write throughput (tail) 0.877 → **0.478** (RTL 0.489).
- read-after-write same-word 13 → **7** (RTL 7).
- eviction-stream throughput 0.0126 → **0.0189** (RTL 0.018); mem_wr=1024 preserved.
- **No regression:** cold miss = ML+17 (sweep 27/67/117/217), warm hit = 10,
  cold_stream throughput 0.0188, coal_cold mem_rd=32 — all unchanged.
- `spatz:use_insitu_cache=True` + `insitu_cache_microbench` build & run clean
  (microbench hit_repeat 2.55→1.98 c/p: forwarding buffer speeds repeated same-line reads).

**Remaining gaps (documented, need Phase-B topology or full occupancy model):**
scalar bypass port, input par-coalescer *warm throughput* (mem traffic already matches),
and bounded accept-depth / hit pipelining / multi-port hit ceiling (need PENDING +
real completion event + bounded outstanding — deferred to avoid perturbing spatz).

**Files touched.** `core/models/cache/insitu/insitu_cache_config.py`,
`insitu_cache_controller.{py,cpp}`, `insitu_calib_mem.{py,cpp}`,
`pulp/insitu_cache_calib/__init__.py`, `prompt/insitu_cache_calib_report.md` (§5/§6/§7/§8).

---

## 2026-06-02 09:51 +0200 — Mirror the new RTL calib phases (write / RAW / coalesce / evict) + mem-traffic counters

**Status:** uncommitted. Builds clean.

**Context.** The RTL `cache_calib` TB grew 7 new built-in phases since our harness
was built (RTL `reports/cache_calib/CHARACTERIZATION.md`, 2026-06-01): warm-write
latency/throughput, read-after-write same-word (forwarding buffer), cold/warm
coalesced 4-port, and dirty-fill / writeback-miss eviction. Its aggregate CSV also
gained `mem_rd`/`mem_wr` columns. User asked to add any new TB/trace patterns on the
GVSoC side.

**What was done.**
- `pulp/insitu_cache_calib/gen_traces.py`: added 7 traces mirroring the RTL phases —
  `warm_write_isolated`, `warm_write_stream_1p`, `raw_same_word`, `coal_cold_4port`,
  `coal_warm_4port`, `evict_dirty_fill` (2× capacity), `evict_wb_miss_stream`.
- `core/models/cache/insitu/insitu_calib_mem.cpp`: added a `stop()` end-of-sim hook
  (block.cpp invokes it recursively at sim close) emitting
  `[CALIB_MEM] mem_rd=… mem_wr=…` — refills = mem_rd, dirty evictions = mem_wr — so
  coalescing and eviction can be verified against the RTL `mem_rd`/`mem_wr` columns.
- `prompt/insitu_cache_calib_report.md`: new §7 with the GVSoC↔RTL comparison.

**Verification (@ ML50).**
- **Memory-traffic counts match:** `coal_cold_4port` **mem_rd=32** (= RTL; 128
  same-line accesses collapse to 32 refills — the controller's MSHR-merge reproduces
  the RTL input-coalescer's traffic reduction). `evict_dirty_fill` **mem_wr=1024**
  (RTL 1051); `evict_wb_miss_stream` mem_rd/wr=2048/1024 (RTL 2054/1029). All
  `data_err`-free, builds clean.
- **Throughput/latency gaps are the known Phase-B items** (not new): warm-write
  latency 10 vs RTL 8; write-stream throughput 0.877 vs RTL 0.489 (no write-path
  serialization); RAW same-word 10 vs RTL 7 (no explicit fwd-buffer forward); coal
  warm throughput ~0.06 vs RTL 3.28 (no input coalescer); evict throughput 0.0126 vs
  RTL 0.018 (GVSoC serializes the writeback fully vs RTL overlapping it).

**Files touched.** `pulp/insitu_cache_calib/gen_traces.py`,
`core/models/cache/insitu/insitu_calib_mem.cpp`,
`prompt/insitu_cache_calib_report.md`.

**Follow-ups.** The throughput/latency gaps map to the existing backlog (write
early-ack + write-info serialization, input par-coalescer, fwd-buffer same-row
forward, writeback/refill overlap, bounded accept-depth/occupancy). Upstream pull
still pending (see prior entry).

---

## 2026-06-01 22:49 +0200 — Track RTL update: cachepool_512 default → production (folded+hash+fwd-buffer)

**Status:** uncommitted. Builds clean; calibration re-verified.

**Context.** Re-reviewed the RTL (per `CLAUDE.md` §"Tracking new RTL revisions").
Found substantive updates since the v2 doc (2026-05-22): the insitu-cache submodule
moved to branch `zexin/sync-flush-fixes`; the integrating repo gained
`3af9362 [CFG] make L1 folded/hash-way/fwd-buffer config-selectable` and
insitu-cache `fbabd6a` (forwarding buffer → top-level parameter).

**Key finding.** The shipping `cachepool_512` default **flipped to the production
cache**: folded + hash-way + forwarding-buffer ON (`l1d_use_folded/hash/fwd_buf=1`).
Unfolded+LRU+no-fwd is now the opt-in "conventional" cache. Constraint:
`fold OR fwd-buffer ⇒ hash-way=1`. Default size also dropped to 1 tile / 4 cores.
My v2 doc was correct on 2026-05-22 but is now stale on the default.

**What was done.**
- `prompt/insitu_cache_architecture_v2.md`: header ⚠ note; new §0.1 (config-selectable
  folded/hash/fwd, the two supported configs, the constraint, forwarding-buffer
  description) + §0.2 (RTL fixes since 2026-05-22); corrected §0 delta-table rows.
- `core/models/cache/insitu/insitu_cache_config.py`: new `use_forwarding_buffer` knob
  (default True); `use_hash_way_select` default → True; **`make_cachepool_512_config`
  is now production** (hash, folded `refill_bank_write=2`/`folded_evict=3`, fwd on,
  `miss_penalty=7`); new `make_cachepool_512_conventional_config` (unfolded+LRU+no-fwd,
  `miss_penalty=8`); legacy config sets fwd=False.
- `insitu_cache_controller.{py,cpp}`: publish/read `use_forwarding_buffer` (informational).
- New track report: `prompt/insitu_cache_rtl_update_2026-06-01.md`.

**Verification.**
- `make all TARGETS="insitu_cache_calib insitu_cache_microbench"` — clean.
- Re-calibration under production config holds **exactly**: cold miss = ML+17
  (27/67/117/217 @ ML 10/50/100/200), warm hit = 10, cold-stream throughput 0.0188
  (RTL 0.0181). The `miss_penalty 8→7` + `refill_bank_write 1→2` swap keeps totals.
- Microbench runs clean, numbers unchanged (patterns don't trigger evictions/conflicts).

**Files touched.** `prompt/insitu_cache_architecture_v2.md`,
`prompt/insitu_cache_rtl_update_2026-06-01.md` (new),
`core/models/cache/insitu/insitu_cache_config.py`,
`core/models/cache/insitu/insitu_cache_controller.{py,cpp}`,
`prompt/insitu_cache_calib_report.md` (calibration note).

**Follow-ups.** Phase-B backlog unchanged (topology refactor, explicit fwd-buffer
model, flush FSM, write early-ack, occupancy model).

**Upstream check (2026-06-01, fetch only — no rebase/bump performed):**
- `engine`: **5 behind** `gvsoc/gvsoc-engine` main — `a8c57439 → a6d92918`
  (incl. `signature: add IoV2Sync sub-protocol signature`).
- `core`: fork `origin/master` and our `insitu-cache` are **5 behind** real
  `gvsoc/gvsoc-core` master (`26c86fd4 memory_v3: drop latency/bandwidth model,
  advertise IoV2Sync`, verilator/fst/iss_v2 fixes). **Coupled with the engine
  bump** — `memory_v3` advertises the `IoV2Sync` signature that engine
  `a6d92918` adds, so pulling core needs the engine bump too.
- `pulp`: **0 behind** (fork master == real upstream == our branch). Nothing to pull.
- `gvrun`: **0 behind**.
- **Blocked on:** uncommitted WIP in `core`/`pulp`/parent must be committed before
  rebasing (`scripts/rebase_dev_branches.sh`, runbook "with uncommitted changes"
  path). Not executed — user commits their own WIP. Recommended sequence: commit
  WIP → `scripts/rebase_dev_branches.sh --push` (rebases insitu-cache onto fork
  master; sync fork master from real upstream first) → bump `engine` to a6d92918
  → commit parent submodule pointers.

---

## 2026-06-01 22:01 +0200 — Adopt dev-log convention + build GVSoC-side calibration testbench

**Status:** uncommitted (no git commit yet). Builds clean; primary calibration
metrics matched.

**Context / motivation.** The RTL repo (`ManyRVData_rebase`) now ships a
standalone performance-calibration testbench around one `cachepool_cache_ctrl`
plus a deterministic fixed-latency refill responder, with a documented
trace + result-CSV interchange format and reference numbers
(`ManyRVData_rebase/reports/cache_calib/`: `PLAN.md`, `TRACE_SPEC.md`,
`CALIB_IMPLEMENTATION.md`, `REPORT.md`, `results_memlat*.csv`,
`traces/sample.trace`). Goal: build the GVSoC-side twin so both engines run the
*same* trace through the *same* memory-timing model and we diff the per-access
`latency` column to calibrate the GVSoC perf model.

**What was done.**
1. Adopted the RTL repo's "Development log" convention into this repo's
   `CLAUDE.md` (new §"Development log (for weekly reports)"), pointing the
   worklog at `prompt/WORKLOG.md` (this file). Added `CLAUDE.md`
   §"Calibrating the model against the RTL standalone testbench".
2. Built the GVSoC-side calibration testbench (twin of the RTL `cache_calib`):
   - `core/models/cache/insitu/insitu_calib_mem.{cpp,py}` — serializing
     fixed-latency refill memory (`mem_busy_until` cyclestamp; synchronous-OK so
     the controller's inline refill path works). MemLatency/BeatGap/AcceptEvery.
   - `pulp/insitu_cache_calib/calib_driver.{cpp,py}` — trace-replay driver +
     per-access monitor. Reads `port,rw,addr,size,delay`; per-port file-order +
     concurrent-port semantics (an access's `delay` gates *its own* offer from
     the prev accept — initial bug fixed); emits per-access + aggregate CSVs in
     the shared schema.
   - `pulp/insitu_cache_calib/__init__.py` — target wiring (driver → 1-ctrl tile
     → calib mem); trace/knobs via env vars; trace path resolves to the source
     repo even when run from the installed copy.
   - `make_cachepool_512_calib_config()` — single-controller DUT geometry
     (5 ports, 4-way × 256-set = 64 KiB), matching one RTL `cachepool_cache_ctrl`.
   - `pulp/insitu_cache_calib/gen_traces.py` — trace suite (warm-hit/cold-miss
     isolated, cold/warm streams). Sample trace copied byte-identical from RTL.
3. **Calibration knobs.** Added `miss_penalty_cycles` (default 0, non-invasive)
   to `InsituCacheController`. Set the canonical `make_cachepool_512_config`
   to the RTL-matched constants `hit_latency_cycles=9`, `miss_penalty_cycles=8`
   (the spatz integration + microbench inherit these).

**RTL reference numbers (config 512) the GVSoC model must reproduce:**
- Warm read-hit = **10 cyc** isolated, **7 cyc** streaming (MemLatency-independent).
- Cold read-miss first word = **MemLatency + 17 cyc** (verified at MemLatency∈{10,50,100,200}).
- **Serialized refills**: ≤1 outstanding line-refill; miss throughput ≈
  1/(MemLatency+17), NOT divided by accept depth. *(Most important to match.)*
- Single-port hit-throughput ceiling ≈ **0.86 acc/cyc**; 4-port all-hit ≈ 0.86 (sub-linear).
- Burst = 4 × 128b beats per 512b line, LSB-first.

**Calibration result (config 512, ML=50 unless noted) — primary metrics matched:**
- Warm read-hit isolated = **10 cyc** (RTL 10), MemLatency-independent. ✅ exact
- Cold read-miss isolated = **MemLatency + 17** (27/67/117/217 @ ML 10/50/100/200,
  RTL identical). ✅ exact across the sweep
- Cold-stream miss throughput = **0.0188 acc/cyc** (RTL 0.0181). ✅ within 4% —
  the serializing memory reproduces the RTL single-outstanding-refill behaviour.
- Single-port hit-throughput ceiling = **0.877 acc/cyc** (RTL 0.86). ✅ within 2%
- Sample mixed trace: clean read-misses match near-exactly (idx2 279=279);
  writes (idx6) + scalar port (idx11) diverge — known Phase-B gaps.

Full comparison + gap analysis: `prompt/insitu_cache_calib_report.md`.

**Files touched.**
- `CLAUDE.md` (+2 sections)
- `prompt/WORKLOG.md` (new)
- `prompt/insitu_cache_calib_report.md` (new)
- `core/models/cache/insitu/insitu_calib_mem.{cpp,py}` (new)
- `core/models/cache/insitu/insitu_cache_config.py` (new `miss_penalty_cycles`,
  calibrated canonical config, new `make_cachepool_512_calib_config`)
- `core/models/cache/insitu/insitu_cache_controller.{cpp,py}` (`miss_penalty_cycles`)
- `pulp/insitu_cache_calib/{__init__.py,calib_driver.cpp,calib_driver.py,gen_traces.py,traces/*}` (new)

**Verification.**
- `make all TARGETS=insitu_cache_calib` — clean (make exit 0).
- `make all TARGETS="insitu_cache_microbench insitu_cache_tb"` — clean; microbench
  runs, numbers shifted as expected for the calibrated config (e.g. hit_repeat_r4
  1.30 → 2.55 c/p, cold_stream_r4 2.67 → 4.11 c/p — reflects hit_latency 4→9 and
  miss_penalty +8). No regression.

**Follow-ups / open (Phase B / occupancy model).**
- Write early-ack (RTL acks at request acceptance; GVSoC over-charges a write miss).
- Scalar bypass port (RTL port 4 bypasses coalescer ≈60 cyc; GVSoC routes all 5
  ports identically).
- Bounded miss accept-depth + true occupancy: GVSoC resolves refills inline, so
  `max_outstanding` reads 1 and the queue-inflated *avg* miss latency over-predicts
  (throughput unaffected). Needs PENDING-with-completion-event instead of inline.
- Hit pipelining (RTL streaming hit 7 vs GVSoC 10) and the 4-port shared-controller
  hit ceiling (clean number needs synchronized stimulus + occupancy model).
- Optional finer cold-stream match: +~2 cyc memory occupancy to track RTL at low ML.
