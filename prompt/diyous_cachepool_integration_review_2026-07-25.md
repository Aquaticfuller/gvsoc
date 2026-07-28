# Integration + review report — DiyouS's `cachepool` work

**Date:** 2026-07-25
**Source:** `https://github.com/DiyouS/gvsoc` branch `cachepool` (`0acc24d`), plus `DiyouS/gvsoc-core` and
`DiyouS/gvsoc-pulp` branch `insitu-cache`.
**Action:** integrated onto our repos (parent `main`, `core`/`pulp` `insitu-cache`) and reviewed.

---

## 1. Executive summary

- **His branch descends from our work** — parent merge-base is exactly our `main` (`f9ebafd`), so the parent
  integrated as a **fast-forward**. He has all of our commits; nothing of ours was rejected.
- **He solved a chain of seven distinct real defects** in a 256-core CachePool model: a permanent boot hang,
  three memory-response-loss bugs, an Ara/AraVlsu completion-signaling bug, a router mapping collision, a
  never-blocking hardware barrier, and an undersized backing memory. The investigation is well documented
  (his `prompt/cachepool_v2_architecture.md` grows to 1045 lines) and includes honest negative results.
- **He added a new, parallel target `cachepool_v2`** — a 256-core hierarchical L1/L2 model (TeraNoC/MemPool
  derived, FlooNoc 4×4 mesh). It is **additive**: it touches zero lines of our `pulp/cachepool.py` and does
  **not** use our structural tile/group or AMO-lane work.
- 🎉 **The headline: acting on his diagnosis CLOSED our longest-standing bug.** The fdotp cross-core reduction
  failure was **not a cache bug at all** — the CachePool binaries read the HW barrier at `PERIPH+0x10`, but the
  spatz regmap puts `HW_BARRIER` at `0x40` (`0x10` is `HART_SELECT_0`), so **`snrt_cluster_hw_barrier()` never
  blocked in any `cachepool` run we ever made**. Routing `0x10` to the real counting barrier makes
  `fdotp-32b_M32768` pass: **`[EOC] retval=0 cycles=88916`, no `Check Failed`**. See §4.
- **His own patches did not fix it** (all three were v2-only or wrong-component); the *diagnosis* transferred,
  the code did not. And the **spin-lock half of our symptom is a separate, still-open AMO/lock-word bug**.
- **But his branch regressed our `cachepool` target**, because he retargeted shared code at a newer software/
  RTL revision (`cachepool_fpu_16g` / `dev/multi-group`) while our target runs the older `cachepool_fpu_512`
  CachePoolTests binaries. I found and fixed three of these; one is still open (§6).
- **Two defects in his commits should be fixed before they bite us:** a **build break on a default target**
  (`snitch_testbench`) and a **latent hard deadlock** in his refill-slot fix (§5).
- His engine bump is **unpublished/unobtainable**, so I pinned an upstream engine that works (§3).

---

## 2. What he built / fixed

### A. `cachepool_v2` — a 256-core hierarchical model (new, parallel target)

| SHA (pulp) | What |
|---|---|
| `687daca` | Adds the `cachepool_v2` target: own entry point (`pulp/cachepool_v2.py` → `CachepoolV2System`), own component tree, own bootrom blob, own cluster-peripheral C++ model, own topology env knobs. |
| `1d75592` | Restores the `l1_noc` wrapper after the upstream teranoc restructuring (upstream moved `pulp/teranoc/l1_noc.py` under `l1_interconnect/` onto a different base class). **Solid.** |
| `fde4a20` | `mempool`: skip constructing `Hierarchical_Interco`'s `Cache` sub-block when disabled (removes an elaboration crash exposure). |
| `942a5a2` | Debug-topology override + bootrom BOOTDATA patcher for v2 — shortened the 256-core repro from ~8 min to ~15 s, which is how the later bugs were actually found. **Notably he reused our patcher approach and our exact BOOTDATA offsets (`core_count@0x44`, `tile_count@0x68`).** |
| `53effd9` | "fix cached/uncached DRAM overlap, per-core SPM default, cluster-register offsets" — **the risky one; see §5/§6.** |

**Relationship to our work:** v2 is structurally *not* our model. It instantiates raw `iss.SnitchFast` cores
plus mempool's `Hierarchical_cache`/`Hierarchical_Interco`/`L2_subsystem` and a real FlooNoc mesh. It **does**
reuse our Phase-A `InsituCacheController` + `InsituCacheCoalescer`, but not our structural tile/group, not our
`use_insitu_cache`/`use_cachepool_group` plumbing, and not our AMO lane.

### B. Boot-hang and livelock root causes (the strongest part of his work)

| SHA (pulp) | Root cause | Quality |
|---|---|---|
| `1f349a3` | **Permanent boot hang**: a wrong composite port name in the `Hierarchical_Interco` binding meant every core sat forever at PC `0x1000` (bootrom's first instruction). | solid |
| `38b9d8e` | **Silently dropped L1 NoC bursts** — the `0xa0000000` region plus tag-bit aliasing in the FlooNoc address windows. | solid |
| `72d76d9` | **`Router.add_mapping()` dict-key collision**: mappings are stored in a dict keyed by name (`core/models/interco/router.py:161`), so reusing the name `'l1'` overwrote the previous mapping — silently routing **every scalar `0x8000_0000`-region access around the L1 cache entirely**. fdotp result went from 28 % off → 3.8 % off. | solid |
| `f20d48a` | **`REG_HW_BARRIER` never blocked**: the read handler returned `IO_REQ_OK` synchronously, so `snrt_cluster_hw_barrier()` was a no-op and cores drifted up to two loop iterations apart. Replaced with a real counting barrier. | solid |
| `bcd0066` | **Undersized `pdcp_mem`** (256 MB backing a region the L1 advertises as ~512 MB) — the last 256-core-only fdotp/fmatmul livelock. | solid |
| `7c8e758` | Strips the debug instrumentation from the investigation. | cleanup |

### C. ISS / Ara fixes (`core`)

| SHA (core) | What | Quality |
|---|---|---|
| `7e07bed1` | **Ara**: run the head-of-queue completion check unconditionally, not only while a newer instruction is mid-issue. `pending_size` only tracks *issuing*, so with async completions the queue head was never retired. **The cleanest commit in the set** — correct diagnosis, minimal fix. | solid |
| `3e4db5c5` | `spatz_vlsu` async-response support + a real `fpu_sequencer` argument-convention bug (`args[nb_out_reg + i]`). Together with `7e07bed1` this turns AraVlsu from "fatal on any non-OK status" into a working async initiator. | mixed (see §5) |
| `a02a541d` | Debug instrumentation for the fdotp `result[]` investigation + pre-existing FpuLsu async WIP. **Contains a build break** (§5). | risky |
| `d7d6c50f` | Strips the debug instrumentation. | cleanup |

### D. InSitu-cache controller fixes (`core`)

| SHA (core) | What | Quality |
|---|---|---|
| `a5e964eb` | Hold and retry `IO_REQ_DENIED` requests in `inline_sync_miss_` mode instead of dropping them. The problem is real (a capacity DENIED is a dead end for a closed-loop master that does not retry), but it makes `handle_request()` re-entrant. | questionable |
| `68503b61` | **Unguarded shared refill slot**: `refill_req_`, `refill_data_buf_` and `pending_refill_addr_` are a single slot, so a second `issue_refill()` before the first response clobbered it. The gap is real and accurately described. **But the fix has a deadlock (§5).** | reasonable, needs a fix |

---

## 3. Integration performed

| Repo | Before | After | How |
|---|---|---|---|
| parent | `f9ebafd` | `97f5b91` | **fast-forward** to his `0acc24d` + 4 corrective commits |
| `core` | `4341bbcc` | `d7d6c50f` | **fast-forward** (7 new commits) |
| `pulp` | `419f43d` | `43d1470` | **adopted his `7c8e758d`** + 2 compatibility commits |
| `engine` | `5863c25e` | `ea216770` | pinned to upstream (his bump unobtainable) |

**Why pulp was adopted rather than cherry-picked.** He **rebased** our pulp branch onto a newer upstream base,
so our commits exist in his history as rewritten duplicates (`419f43d`→`c9a09a6`, `6849c06`→`c9e0919`,
`c3f45d7`→`294b807`, …). I verified **7 of our 8 cachepool patches are byte-identical** by patch-id; the 8th
(MINIMAL boot path, `85ed0ef`→`6ec9143`) differs only in rebase context — same file set, same 387/3 line
counts. His new work depends on the newer upstream base (e.g. `1d75592` adapts to the teranoc restructuring),
so replaying his 11 commits onto our older base would conflict and produce a broken tree.

**Three adaptations were required:**

1. **engine — his bump is unobtainable.** His parent bumps engine `5863c25e` → `9033115a`, which exists in
   neither `gvsoc/gvsoc-engine` nor a public `DiyouS/gvsoc-engine` (that repo 404s). The bump is **not
   optional**: his rebased pulp needs `vp/debug_mem.hpp` (upstream, added 2026-06-10), without which
   `pulp/cluster/l1_interleaver_impl.cpp` fails to compile. Upstream `main` (`e84b52d1`) is **too new** —
   `6c3fb708` "memcheck: buffer-ID registry replacing fake-address tracking" (2026-07-03) removes
   `vp::MemCheckRequest` / `MemCheck::register_memory`, which `core/models/memory/memory.cpp` still uses.
   I pinned **`ea216770`** (2026-06-30), the last upstream commit before that break that still has
   `debug_mem.hpp`. **Build verified clean for both `cachepool` and `cachepool_v2`.**
2. **`.gitmodules`** — he repointed `core`/`pulp` at `DiyouS/*`; restored to `Aquaticfuller/*`.
3. **`CLAUDE.md`** — merged: kept his new "CachePool v2 target" section, restored our fork URLs, our build
   environment (his documented a personal conda env at `/home/msc26f31/...` and paths under `/scratch/diyou/...`),
   and our standing **structure-map convention**, which his revision had deleted. `prompt/WORKLOG.md` merged
   too (his 07-09/07-13 entries + our 06-16…06-25 entries, which his branch did not have because ours were
   uncommitted).

**Recovery refs** (nothing is lost): `recovery/main-pre-diyou` (parent), `recovery/insitu-cache-pre-diyou`
(core, pulp), `recovery/engine-pre-diyou` (engine).

---

## 4. Does his work fix OUR open bug? — **RESOLVED: our fdotp bug is now FIXED**

> **Outcome (verified after this report's first draft):** acting on his diagnosis, `fdotp-32b_M32768` with the
> cache in the data path now reaches **`[EOC] retval=0 cycles=88916` with NO "Check Failed"** — the bug we
> spent the most time on is **closed**. It was **not** a cache bug. Details below.

### 4.1 The actual root cause (his diagnosis, our target, our fix)

The CachePool binaries read the cluster hardware barrier at **`PERIPH+0x10`** (snRuntime
`cachepool_peripheral.h`: `HW_BARRIER_REG_OFFSET 0x10`; `_snrt_cluster_barrier` is a single **blocking `lw`**).
But the generated **spatz** regmap has `regwidth 64` and places **`HART_SELECT_0` at `0x10`**, with
**`HW_BARRIER` at `0x40`**. So the barrier read never reached `hw_barrier_req()`: it returned 0 with
`IO_REQ_OK`, `barrier_status` stayed 0, and the `barrier_req`/`barrier_ack` wires were dead.

**`snrt_cluster_hw_barrier()` therefore never blocked in *any* `cachepool` run we ever made** — and our own
comment in `pulp/cachepool.py` ("the barrier@0x10 / boot-control@0x20 already match the regmap") was simply
wrong, as was the claim in `prompt/gvsoc_cachepool_minimal_results_2026-06-22.md`.

Why that produced exactly our symptom: fdotp's `vfredusum.vs v0, v24, v0` never resets `v0`, so across the
kernel's 3 measurement iterations each core's `acc` is 1×/2×/3× its partial. Each core writes `result[cid]`,
"barriers", and core 0 sums `result[1..n-1]` against `dotp_result × measure_iter`. With a **no-op barrier**,
core 0 mixed values from *different iterations* → a wrong result that **moved when timing was perturbed** and
**vanished when all cores stayed symmetric** (cache off). That matches every observation we recorded, including
"read hits verified == DRAM, no byte mismatch".

A coherence/private-copy explanation is **ruled out**: the structural tile routes by address to one shared
cell, so `result[]` was always coherent. **The barrier was the necessary root cause; the cache was only the
trigger** (it desymmetrises core timing).

**Our fix** (pulp `c20bd51`): in `cachepool_mode`, dispatch offset `0x10` to `hw_barrier_req()` and honour
`stall_core`, so each arriving core parks with `IO_REQ_PENDING` and all are released when the last checks in.

### 4.2 What his *patches* did and did not do

His three nominated commits were **all refuted as fixes for our path** — they are v2-only or wrong-component:

| Commit | Why it could not fix ours |
|---|---|
| pulp `f20d48a` | Touches `cachepool_v2_cluster_peripheral.cpp`; our target's peripheral is `spatz/cluster_registers.cpp`. **The *diagnosis* transferred; the code did not.** |
| pulp `72d76d9` | v2-only, and **no equivalent collision exists in our path** — every `o_MAP` name on `cores_ico` and on each per-lane `vico` is distinct, and each `vico` is a separate `Router`. (So this did *not* explain our "~40 accesses" after all.) |
| core `68503b61` | **`InsituCacheController` is never instantiated in our failing config** — `use_structural_insitu_cache` routes to `InsituCacheCore`. Also needs a refill returning `PENDING`, which our memory-backed refill path never does. |

### 4.3 The spin-lock half is a *separate*, still-open bug

`spin_lock.c` has **no shared-counter loop** — the only loop is `while (__sync_lock_test_and_set(lock,1))` and
the "counter" is a single `result += cid` under the lock. Its non-termination is an **AMO / lock-word
visibility** problem on the cached lock word: unrelated to the barrier, the router mapping, or the refill slot,
and untouched by any of his commits. **This remains entirely ours** (our AMO-lane work is where it lives).

### 4.4 Two more of our own latent bugs the review surfaced (still open)

- `insitu_cache_core.cpp:348-354` — when a refill does **not** return OK, the sync path serves data from a line
  that was never filled **and marks it VALID**, i.e. stale/zero bytes returned as valid, silently.
- `functional_write_mem()` (`insitu_cache_core.cpp:77-85`) — ignores the returned status.

---

## 4bis. (superseded) original assessment of the bug question

Our open bug: with the InSitu cache in the data path, fdotp's cross-core `result[]` reduction is wrong
(Check Failed), **timing-sensitive** (adding benign latency makes it pass), and a spin-lock shared counter
never converges.

**Answer: his *root causes* very likely ARE our bug — but his *code fixes* are in his v2 components, so they
do not fix our target as-is. And the one core-side commit that looked like the fix is not.**

- ✅ **His §13.1.2 — `REG_HW_BARRIER` never blocked** (`f20d48a`). The read handler returned
  `IO_REQ_OK` synchronously, so `snrt_cluster_hw_barrier()` never blocked and cores ran up to two loop
  iterations apart; a group leader summed siblings' **future-iteration** values. His arithmetic:
  `512 + 3×1536 = 5120` observed vs `2048` expected; a sibling wrote its iteration-2 value at cycle 12988
  while the leader read iteration-0 at ~14366. **This is exactly the shape of our symptom** — cross-core
  `result[]` reduction wrong, timing-sensitive, no data corruption anywhere.
- ✅ **His §13.1.1 — `Router.add_mapping()` dict-key collision** (`72d76d9`) silently routed **all** scalar
  `0x8000_0000`-region accesses **around the L1**. This independently explains one of our most confusing
  observations: our instrumented cache saw only **~40 accesses** with `evict=0`, and our VLSU-reroute change
  produced **byte-identical cycle counts**. Same class of bug, same signature.
- ❌ **`core 68503b61` (shared refill slot) does NOT fix our bug.** Decisive reason: **wrong component.** All
  three of his InSitu commits touch `insitu_cache_controller.cpp`, but our failing run does not instantiate
  that at all — `pulp/cachepool.py` sets `use_structural_insitu_cache`, so `insitu_cache_tile.py` dispatches
  to `_build_structural_tile()` which instantiates **`InsituCacheCore`** (`insitu_cache_core.cpp`) per cell.
  `InsituCacheController` is only live in the calib target, the microbench, `insitu_cache_tb`, and plain
  `spatz --target-property use_insitu_cache=True`.

**What this means for us:** the fix we need is to **port his barrier and router findings into our `cachepool`
target** — make our HW barrier actually block, and audit our per-lane `o_MAP`/`add_mapping` names for the same
dict-key collision. That is now the highest-value follow-up (§7), and it is strong independent corroboration
of our own conclusion that the bug was *ordering/visibility*, not cache data.

> Caveat: the two adversarial verification agents for this claim had not returned when this report was written;
> the above rests on the code reviews plus our own matching evidence. Treat "very likely" as exactly that.

---

## 5. Defects and risks found in his commits

| # | Severity | Finding |
|---|---|---|
| 1 | **HIGH** | **Build break on a default target.** `a02a541d` leaves two compile errors in `core/models/cpu/iss/src/snitch_fast/fpu_lsu.cpp` (:235, :280) whenever `CONFIG_GVSOC_ISS_LSU_NB_OUTSTANDING` is defined — `Lsu::stall_callback` / `FpuLsu::stall_callback` are arrays in that configuration. **`snitch_testbench` is in the default Makefile `TARGETS`** and uses `nb_outstanding=8`. Baseline `4341bbcc` is clean. Fix: `#ifdef` guards as in `lsu_implem.hpp:146-150`. *(We did not hit this because we only built `cachepool`/`cachepool_v2`.)* |
| 2 | **HIGH** | **Latent hard deadlock in `68503b61`.** `refill_resp_handler`'s early `if (pending_way < 0) return;` (`controller.cpp:870-874`) bypasses the new `refill_busy_ = false` (:913). One unmatched refill response latches `refill_busy_` forever; every later miss queues into `refill_wait_queue_` and no refill is ever issued again. Fix: clear `refill_busy_` and drain the queue on **all** exits (scope guard). |
| 3 | MED | **`a5e964eb`** makes `handle_request()` re-entrant at an awkward point (DENIED hold/retry). Worth a second look under load. |
| 4 | MED | **`53effd9` regressed our v1 target** — three concrete breakages, all fixed by me (§6). Reviewers flagged the same commit independently as "risky", and noted the headline "cached/uncached overlap" it claims to fix **did not actually exist** (GVSoC router maps are `[base, base+size)` and the old map ended exactly at `UNCACHED_BASE`). |
| 5 | MED | **`cachepool_v2` bypasses our AMO-lane work entirely** — no lane-ordering convention, no AMO/LR-SC shim, no structural tile to mediate atomics; `pdcp_mem` is constructed **without** `atomics=True`. Any snrt atomic on cached DRAM in v2 goes unmediated. If v2 becomes the primary target, the AMO work must be redone there. |
| 6 | LOW | The **DENIED contract** is now inconsistent: his ISS work makes the VLSU accept `DENIED` and wait for a `resp()`, but our `InsituCacheCore::req_handler` still *drops* the request on accept-queue-full (and its comment at `insitu_cache_core.cpp:244-245` — "the Spatz VLSU rejects async" — is now false). He patched the `inline_sync_miss_` controller path but not the structural core. |
| 7 | LOW | Process: he repointed `.gitmodules` at his own forks, replaced our environment/conventions in `CLAUDE.md`, and bumped `engine` to an unpublished commit. All handled here, but worth agreeing on. |

---

## 6. Post-integration status of our `cachepool` target

His `53effd9` retargeted shared code at the newer software layout. Three concrete regressions for the older
`cachepool_fpu_512` CachePoolTests binaries, **found empirically and fixed** (pulp `3321c02`, `43d1470`):

1. **`CLUSTER_BOOT_CONTROL` (0x20) was swallowed.** His `if (offset < 0x30)` perf-counter scratch intercept
   also captured `0x20`, where the ElfLoader writes the ELF entry and the bootrom reads it back. Every core
   read 0 and jumped to 0 → the run executed forever with no output (observed 79 M+ cycles, no EOC).
   **This was the killer.** Fixed by letting `0x20` fall through to the regmap.
2. **EOC moved to `0x68`.** Our binaries signal end-of-computation by writing **`0x24`** (retval in
   bits[3:1]); it was being swallowed as scratch. Restored `0x24` handling *before* the scratch range, keeping
   his `0x68` path — both revisions now work (`0x24` is `PERF_COUNTER_0+4` in the new layout, read-only there).
3. **`spm_num_groups` `NB_TILE` → `NB_CORE`.** Per-core SPM breaks snrt's **shared** `l1alloc` for these
   binaries. Restored our verified per-tile default, with `CACHEPOOL_SPM_GROUPS` to select his per-core mode.

A fourth breakage was found later, when the completed review flagged it: after `53effd9` the **older-layout L1D
config block (`0x28`–`0x4c`)** falls through to the regmap, which aborts the run with *"Accessing invalid
register"* and `exitcode: 1` (hit at `0x3c` = `L1D_FLUSH_STATUS`, which snrt's `l1d_wait()` spins on, and at
`0x4c`). Restored as RW scratch with `0x3c` reading 0. While fixing it I also found that his `0x58`–`0xa4`
handler indexes `cp_l1d[16]` up to **19** — an out-of-bounds write; the indices are now offset by 10.

**Verified after all fixes — the final result (2026-07-25):**

- **4-core, cache ON: 7/8 pass** — spin-lock (`result: 6; gold: 6`), load-store, fdotp, gemv, fmatmul,
  linked-list, byte-enable; fft reaches EOC with retval=1 (the 4-vs-16 core-count partition mismatch only).
- **16-core (4 tiles × 4), cache ON: ALL 8/8 PASS** — incl. spin-lock (`result: 120; gold: 120`), fft
  (57477 cyc, correct at the full config), linked-list, byte-enable. The multi-tile cache (cross-tile remote
  xbars) is data-correct across the full CachePool.
- Additional fixes that landed after §6: per-core-private SPM default (pulp `9aaa78d`, fixes the stack-frame
  collision found here), the AMO shim `get_second_data()` result fix (core `dc2e82ca`, fixes the spin-lock
  livelock), and four hygiene fixes (core `19a1797d`: the fpu_lsu build break, the refill_busy_ leak, an
  unfilled-line-VALID bug, and the structural-core DENIED-drop).

**Still open (updated):** only the **fft partition mismatch at non-16-core counts** (passes at the full 16
config; a milestone-4 partitionable-SPM item). Everything else in this section is **closed**: `spin-lock` was
fixed by the AMO shim `get_second_data()` result bug (core `dc2e82ca`), `byte-enable` by per-core-private SPM
(pulp `9aaa78d`, fixes the stack-frame collision — also validating §4.3's AMO-lane framing), and the
cache-OFF no-output issue was the same `0x20`/`0x24`/`0x3c` scratch-swallowing family, fixed earlier.

---

## 7. Recommended follow-ups (ordered)

1. ✅ **DONE — barrier routed to the real counting barrier** (pulp `c20bd51`); fdotp now passes. The router
   collision was checked and **does not exist in our path**. Remaining from this item: **`spin-lock` (AMO /
   lock-word visibility)** and **`byte-enable`**, both still hanging — these are ours, in the AMO-lane area.
2. **Fix his build break** (`fpu_lsu.cpp` `#ifdef` guards) before anyone builds the default `TARGETS`, and run
   `make build` with the default target list to confirm.
3. **Fix the `refill_busy_` leak** in `68503b61` (clear on all exits) — it is a hard deadlock waiting to happen.
4. **Root-cause the remaining no-cache non-termination** on our target (§6).
5. **Ask him to push his engine fork**, or agree to pin upstream `ea216770` as I have (and record it).
6. **Decide target strategy.** `cachepool` (ours: structural RTL-faithful cache, AMO lane, configurable
   N-tile topology, 4–16 cores) and `cachepool_v2` (his: 256-core hierarchical, FlooNoc, Phase-A controller)
   are now two parallel models with different software revisions. Either converge them or document clearly
   which is authoritative for which experiment — otherwise fixes will keep diverging.
7. **Re-run the 8-kernel CI suite** on our target post-integration and refresh the run guide numbers.
8. Consider agreeing on shared conventions (`.gitmodules` URLs, `CLAUDE.md` ownership, who bumps `engine`).

---

## 8. Commits made during this integration

| Repo | SHA | Subject |
|---|---|---|
| parent | `9c19864` | integrate DiyouS's cachepool work; keep our fork URLs, engine pointer and conventions |
| parent | `608638b` | bump engine to `ea216770` (required by the integrated pulp/core) |
| parent | `b58e94e` | bump pulp pointer for the cachepool_fpu_512 compatibility fixes |
| parent | `97f5b91` | bump pulp pointer for the CLUSTER_BOOT_CONTROL fix |
| pulp | `3321c02` | keep the cachepool_fpu_512 software layout working alongside cachepool_v2 |
| pulp | `43d1470` | don't swallow CLUSTER_BOOT_CONTROL (0x20) in the perf-counter scratch range |
| pulp | `c20bd51` | **route HW_BARRIER (0x10) to the real counting barrier — fixes the fdotp cross-core reduction** (+ restore the 0x28–0x4c L1D block, fix the `cp_l1d[]` index overrun) |
| parent | `d5994cf` | bump pulp pointer for the HW_BARRIER routing fix (fdotp now passes) |

Nothing has been **pushed** — all of the above is local, and the recovery refs make the whole integration
reversible.
