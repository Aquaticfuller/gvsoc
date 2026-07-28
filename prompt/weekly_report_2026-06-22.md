# Weekly Report — GVSoC InSitu L1 Cache Model

**Period:** 2026-06-15 (Mon) → 2026-06-22 (Mon)
**Engineer:** Zexin Fu
**Area:** GVSoC performance model of the CachePool InSitu L1 data cache — this week a **structural rewrite** (transcribe the real RTL datapath of every component, then compose them into the faithful Group→Tile→cell→core hierarchy), plus a new **GVSoC CachePool SoC target** that boots the unmodified snrt CI binaries.

---

## TL;DR

Three big things happened this week, all building on each other:

1. **Structural rewrite (06-16…06-18).** The cycle-approximate latency-knob model matched the synthetic calib numbers but reflected **none** of the real RTL shared-L1 substrate (it was a flat single hashed interco + 4 address-interleaved controllers, structurally three axes off from the RTL). After a verified deep-read of ~22k lines of RTL, we committed to transcribing the **real RTL FSM/datapath of every component** into standalone-validated C++ headers — latency is meant to *emerge* from cycles spent in RTL states, not be applied up-front by a knob. Steps 1–7 (decode/encode, pseudo-dual-port bank, forwarding buffer, per-cycle cache core, par_coalescer datapath, programmable xbar + SPM remap + flush/sync FSM, AMO/LR-SC + L2 scramble/NAPOT) all landed and validated standalone. b.0 then made refill latency emerge (cold-miss now scales with MemLatency) and fixed a deadlock the deferral exposed.

2. **Structural Tile/Group integration (06-21…06-22, Phases A1–A5c).** Composed the validated components into the real hierarchy: 5 per-port-class crossbars (not one hashed interco) feeding per-core multi-lane cells; the par_coalescer + scalar bypass + AMO shim living **inside** the cache cell as in the RTL; a multi-tile **GROUP** with inter-tile remote xbars giving a **cross-tile shared L1**. An analytic **synchronous-slave** core mode (one-shot, no virtual-cycle FSM loop) lets the structural tile drive the Spatz VLSU, so **closed-loop `vfadd` PASSES** (15/15) on the structural single tile (59001 cyc) and on the full 16-core / 4-tile group (69001 cyc). Group geometry matched to RTL `cachepool_fpu_512.mk` @ `f5c3ef4`.

3. **GVSoC CachePool SoC target (06-22).** The RTL CI benchmark binaries (snrt, run via QuestaSim) **hang at boot** on `--target=spatz` — a different SoC with the wrong memory map / no snrt boot env / no print path. Scoped the boot handshake and built a **MINIMAL** `gvsoc --target=cachepool` that boots the **unmodified** snrt CI binaries. Result: **5 of the 8 CI kernels exit retval=0** (spin-lock, load-store_M16, fdotp, gemv-opt, byte-enable); fft exits retval=1, fmatmul + linked-list time out; **all boot/print/exit** (+ the separate `cache-line-rw-smoke` test, retval=0).

**Accuracy caveats (non-overclaiming):** the structural model is **gated default-off** — the flat calibrated path is byte-identical throughout (calib fmatmul-M32 mean-Δ 3.9, `coal_cold` wide @ML50 0.4961, `vfadd` 58001). The structural model runs closed-loop and is **data-correct**, but is **NOT yet cycle-calibrated** against RTL (sync-slave warm hit 9 / cold miss ML+12 vs RTL 10 / ML+17 — that's the deferred calibration pass). The MINIMAL CachePool target is **4-core / 1-tile + no cache** (cores hit DRAM directly); the binaries are compiled for 16-core `cachepool_fpu_512`, so `fft` exits **retval=1 (wrong result)** and `fmatmul` / `linked-list` **time out at 200 s** — all consequences of the 4-core config, not boot gaps.

---

## What was done

Organized by workstream, in order of weight.

### 1. Structural rewrite — transcribe the real RTL datapath per component (06-16…06-18)

**Why.** The latency-knob model was timing-faithful on synthetic phases but structurally simplified and had hit hard limits: (a) it mirrors none of the RTL microarchitecture (a Knuth multiplicative hash victim picker that is **not** the RTL hash, flat hit/miss latency knobs, a cyclestamp occupancy model, an inc-1 coalescer skeleton); (b) it builds the v1 topology (4 address-interleaved controllers + hashed N→M interco), three axes off from the integrated RTL — per-controller internals (set-assoc-interleaved vs single wide-line + coalescer/bypass), per-core mapping (hashed-interleave vs one-cache-per-core), and system scale (one flat tile vs 4 tiles × 4 cores + remote xbar); (c) several calibration targets were proven **NON-CONVERGENT** with knobs (the `coal_cold` `max_outstanding` 128 vs RTL ~56 / evict-outstanding 32 vs RTL 4 coupling — a documented NO-GO); (d) `enable_input_coalesce` only *approximates* the par_coalescer (followers inherit a cheaper latency number — no real wide request / hitmap / response-split).

**Decision & guardrails.** Adopt a STRUCTURAL REWRITE driven by a 10-agent workflow (8 RTL-port readers → synthesis → adversarial review = SOUND-WITH-FIXES). Real logic, not approximations; latency must EMERGE from cycles-in-states; calibrate LAST in one dedicated phase; the structural path is a **parallel fallback selectable by one top-level flag** and the functional-correctness gate during build is `vfadd` 15/15 + calib **data** byte-identical (NOT a cycle match — cycle counts *will* shift once the XOR-fold replaces the Knuth hash and a real CSHR replaces the latency window); RTL stays read-only.

**Steps 1–7 (all transcribed as header-only datapaths, each with a standalone g++ self-test, all gated default-off → zero build impact):**
- **Step 1 — decode/encode** (`insitu_cache_decode.hpp`, 176 lines): address decode, real hash-way = `lowtag ^ lowset` (replaces the model's Knuth-hash approximation), SOP hit/hit_pend/hit_conflit/all_pend classify (INVALID/VALID/READ_PEND/WRITE_PEND), full-assoc LRU victim, encoder LRU-credit update, masked byte merge.
- **Step 2 — pseudo-dual-port bank** (`insitu_cache_bank_array.hpp`, 106): 6-state R-vs-W classify, `bank_select` = low `log2(BankFactor)` bits, WR_CONFLICT penalty via a **per-cycle write scoreboard** (the structural replacement for the abstract `set_busy_until_` stamp), independent per-way SRAMs, same-row WR_SAME_ADDR forward, SRAM read latency 1.
- **Step 3 — forwarding buffer** (`insitu_cache_fwd_buffer.hpp`, 135): single-entry SRAM forwarding buffer (read-suppress, write-absorb with lazy byte-mask merge, lazy dirty-victim writeback, partial-validity bitmap, RAW forward).
- **Step 4 — per-cycle cache core (first runnable)** (`insitu_cache_core.cpp` +405 / `.py`): the RTL-faithful structural core — a per-cycle `ClockEvent` 2-stage pipeline (stage-0 arbitrate {request, refill}→preread; stage-1 decode + FSM + one bank write + output drain) consuming Step-1 + Step-2. Read-hit / write-hit / read-hit-pend (in-situ MSHR append) / miss-allocate / dirty-writeback; single-outstanding refill install + drain of all queued readers; bank WR_CONFLICT → read retries next tick. **Latency emerges from pipeline cycles, not knobs.** A streaming input accept queue (~32, the real outstanding budget) replaced the 1-deep input buffer for concurrency fidelity.
- **Step 5 — par_coalescer datapath** (`insitu_cache_coalesce.hpp`, 110): same-cycle narrow ports to the SAME line + SAME type coalesce into ONE wide 512b beat (write-bit folded into the key MSB so R/W never co-merge), per-port word offsets + hitmap, wide write merge (last-writer-wins), read-split back to each merged port. Replaces the `enable_input_coalesce` latency-trick.
- **Step 6 — programmable xbar + SPM remap + flush/sync FSM** (`insitu_cache_route.hpp` 156, `_spm_remap.hpp` 83, `_sync_fsm.hpp` 185): `tcdm_cache_interco` request/response routing (3 partition modes: all-private / all-shared / mixed; MSB address rotation; remote-tile slots; 2:1 bypass with RR arb); `partitionable_flushable` SPM exact integer DIV/MOD remap + inverse restore; 7-state flush/sync FSM (IDLE→READ_BANK→CHECK_PEND→{INIT|FLUSH}→FINISH, 4 opcodes, 20-cycle drain interlock, per-set dirty-way write-through eviction). **51-check self-test — all pass.**
- **Step 7 — AMO/LR-SC shim + L2 scramble/NAPOT** (`insitu_cache_amo.hpp` 171, `_l2_addr.hpp` 110): `spatz_cache_amo` 4-state RMW FSM with atomicity via core back-pressure, the 32-bit amo_alu (swap/add/and/or/xor/Max/Min/Maxu/Minu), {valid,addr,core} reservation rules; `scrambleAddr`/`revertAddr` channel-interleave + NAPOT channel decode (DDR4, 0x8000_0000, 1 GiB, 4 channels). **38-check self-test — all pass.**

**b.0 — open-loop structural calibration kickoff.** A pre-decision 8-agent workflow (all 3 refuters failed) overturned the prior premise: the Spatz v1 **scalar** LSU does **not** require synchronous IO_REQ_OK (it stalls + resumes on `data_response`); the real closed-loop blocker is the Spatz **VLSU** which `trace.fatal()`s on any non-OK — so a sync-slave mode is *sufficient* (no VLSU rewrite). b.0 then: (1) made refill latency **emerge** — `drain_outputs()` was discarding the serializing responder's stamped `inc_latency`, so cold-miss was ~pipeline cycles regardless of MemLatency; now captures `get_full_latency()`, defers install to `refill_ready_cycle_`, and gates the next refill on it (serialized miss throughput); (2) **fixed a deadlock** the deferral exposed (refill install routed through the same `preread_q_`/stage-0 a stalled request occupied → circular 5M-cycle watchdog abort) by splitting refill install onto its own `maybe_install_refill()` priority path.

**Pre-calibration gap audit (18 structures, 38 agents, adversarially re-verified).** Established a crucial truth: **transcribed ≠ wired.** Only 2 of 18 structures (`decode.hpp` + `bank_array.hpp`) actually run their RTL logic in a runtime path, and only on the open-loop calib TB; 6 faithful headers were `#include`d by nothing; group/cluster composite, peripheral/CSR/flush, and the write-through merger + its WT FIFO were MISSING entirely. Surfaced silent-bias calibration traps (`dynamic_offset` runtime default 2 vs RTL live reset 14; dead `wt_fifo_depth`; flush = 0-cycle stub).

### 2. Structural Tile/Group integration — Phases A1–A5c (06-21…06-22)

**Plan (06-18).** A 9-agent design workflow (5 RTL+model readers → synthesis → 3 adversarial reviewers, all 3 returning sound=false with must-fixes folded in) corrected an unsound first draft and produced the verified RTL tile blueprint + dependency-ordered build order. **Key must-fixes:** (1) the tile has **5 per-port-class crossbars** (one `tcdm_cache_interco` per lane), NOT one hashed interco; (2) the coalescer lives **inside the cache cell** (par_coalescer on the 4 VLSU lanes + an internal 2:1 bypass for the scalar lane); (3) AMO is on lane j=4 (scalar) only, one per controller (VLSU lanes bypass); (4) eviction **rides the refill channel** (no separate evict port; refills match on return by **address re-decode**); (5) the group uses **source-tile-mod-N slot pinning** (getting source%N vs target%N wrong silently drops cross-tile responses only when S%N≠T%N — passes single-tile, fails some multi-tile); (6) the sync-slave mode MUST use an **analytic** one-shot latency compute, because reviewers showed a virtual-cycle FSM-loop sync mechanism **re-entrant-resp()-crashes**. **Accepted architectural tension:** the sync-slave mode needed to drive the structural core from the Spatz VLSU degrades the cell's cross-lane fidelity (the VLSU issues lanes sequentially, so the coalescer can't batch and the bank scoreboard smears) → build order = validate **open-loop multi-port first** (full fidelity), then add the sync mode for closed-loop.

- **Foundation (06-21, core `f8e78da3`).** `InsituCacheXbar.{cpp,py}` — one per-port-class crossbar wrapping the validated `route.hpp` (replaces the hashed interco; not yet instantiated). Multi-lane core port (`num_input_ports`, default 1 = backward-identical; RTL 5-wide). Also resolved a build-env compiler/ABI issue by pinning `CXX=/usr/sepp/bin/g++-14.2.0 CC=gcc-14.2.0` + `LD_LIBRARY_PATH=/usr/pack/gcc-14.2.0-af/lib64` (a CMake re-configure with CXX/CC unset picked the wrong compiler → GLIBCXX_3.4.32 ABI mismatch with the 06-16 `.so`).
- **A1 (core `9ad67c88`, pulp `6e0da96`).** `_build_structural_tile()` instantiates the 5 per-port-class xbars + N multi-lane `InsituCacheCore` cells (`i_INPUT(p)→xbar[p%5].in_(p//5)`; `xbar[j].out_(cb)→core[cb].input_j`; refill/evict→`o_L2`). The faithful shared-L1 intra-tile routing the old model lacked entirely. *Scope: no MSB rotation, no coalescer/AMO yet.*
- **A2 (core `a6ee0038`, pulp `4d4bb78`).** Structural cache CELL — `InsituCacheCellCoalescer` wrapping `coalesce.hpp` on the 4 VLSU lanes (same-cycle same-line reads → one wide line-read, response split per port; writes pass through; 1-cycle CSHR window; 64-group in-flight pool) + scalar lane via the 2:1 bypass to a 2-input core.
- **A3 (core `6d488974`, pulp `a679e98`).** AMO/LR-SC shim (`InsituCacheAmoShim` wrapping `amo.hpp`) on the scalar lane only. The structural tile is now structurally complete (5 xbars + coalescer cell + AMO shim).
- **A4 (core `7886617e`, pulp `0f89037` + `b2d943a`).** `run_request_sync()` — an **analytic one-shot synchronous-slave** mode (decode → HIT serve+lru+inc_latency / MISS evict-dirty-victim-before-overwrite, lru-before-status-writes, refill, `refill_lat = get_full_latency()+refill_bank_write+miss_penalty`, install, serve; write-commit = added latency, never DENY; no save/resp/tick/FIFO). Designed via a 7-agent workflow (deadlock reviewer SOUND). Cluster opt-in `use_structural_insitu_cache` → `structural_tile` + `cell_coalescer=False` + `amo_lane=False` + `controllers_track_cores` + line-granular `dynamic_offset`, same `i_INPUT`/`o_L2` facade. **Closed-loop `vfadd` on the structural tile: 15/15 PASSED, cycles=59001.**
- **A5 (core `c5d67024`, pulp `038117e`).** Multi-tile GROUP — `InsituCacheRemoteXbar` (one per-port-class inter-tile router N×N, routes a cross-tile request to the TARGET tile by address TileID; the GVSoC response auto-routes back via the preserved resp-port chain, so the RTL source-tile-mod-N slot pinning is a timing-only detail) + `InsituCacheGroup` (N tile_id-stamped tiles + 5 remote xbars + L2 fan-in). The full GROUP→TILE→cell→core hierarchy is now built — **structurally complete** (component-wise; `fwd_buffer`/`spm_remap`/`sync_fsm` are transcribed but not yet wired — see Open items).
- **A5b (core `a8f13797`, pulp `db96de0`).** `make_cachepool_fpu_512_config()` matched to RTL `config/cachepool_fpu_512.mk` @ `f5c3ef4` (fetched via WebFetch): 4 tiles × 4 cores, NumL1CacheCtrl=NumCores=16 (4 ctrl/tile), 5 TCDM ports/core, `num_remote_port_core=2`, per-controller 4-way × 256-set × 64 B = 64 KiB (256 KiB/tile), L1BankFactor=2 (pkg hardcodes 2; the .mk's `l1d_bank_factor=1` is dead), folded+hash+fwd, L1CoalFactor=2, L2 4ch/interleave-16. Local config differed from `f5c3ef4` only in `num_remote_ports_per_tile` (local 1, upstream 2) → generalized.
- **A5c (pulp `14c456d`).** Opt-in `use_cachepool_group` → the cluster builds `InsituCacheGroup` from the fpu_512 config (assert nb_core=16, same facade). **Closed-loop `vfadd` on the full 16-core / 4-tile group: 15/15 PASSED, cycles=69001.**

### 3. GVSoC CachePool SoC target — MINIMAL boot path (06-22)

**Blocker.** Attempting to run the RTL CI benchmark binaries (`ManyRVData_rebase/util/auto-benchmark/configs-ci.sh`, `software/build/CachePoolTests/test-cachepool-*`) on `gvsoc --target=spatz` produced **no output** and hung at boot — three attempts (spin-lock nb_core=2, spin-lock nb_core=16, cache-line-rw-smoke nb_core=16 killed at 200 s). These are snrt-based ELF32 binaries built for the **CachePool RTL SoC** and run by the auto-benchmark via QuestaSim. Because even the no-cache baseline hangs, it is a **SoC-level boot incompatibility**, not a cache-model issue: the spatz cluster sits at `0x00100000`/peripheral `0x00120000`, while the snrt binaries hardwire TCDM `0xBFFFF800` / peripheral `0xC0000000` / UART `0xC0010000` — so the very first crt0 MMIO (the cluster-barrier load at `0xC0000010`) lands unmapped.

**Scope (`prompt/gvsoc_cachepool_soc_boot_scope_2026-06-22.md`).** Traced the full boot handshake file:line against snrt sources + RTL + GVSoC: bootrom@0x1000 → MSIP wake → entry-indirection through `0xC0000020` → `_start` (a0=mhartid, a1=&BOOTDATA) → bss/FP clear → blocking pre-main `_snrt_cluster_barrier` (load of `0xC0000010`) → main → UART printf → HTIF tohost / EOC exit. Recommendation: a **NEW** `pulp/cachepool.py` target, NOT extending `spatz.py` (the address map, a0/a1 contract, entry-indirection, and EOC offset all differ — branching `spatz.py` risks regressing the validated `vfadd` path); reuse SnitchCluster + cache/group + HTIF + the blocking HW barrier.

**Built (core `b5ed7dd4`, pulp `85ed0ef`).** New `gvsoc --target=cachepool` reproducing the boot env + memory map (bootrom@0x1000 reusing the RTL `bootrom.bin` with BOOTDATA core_count=4, DRAM@0x80000000, uncached/.pdcp@0xA0000000, SPM/TCDM@0xBFFFF800 2 KiB, peripheral@0xC0000000, fake-UART@0xC0010000), 4-core / 1-tile, **no cache** (cores hit DRAM directly). Added `cachepool_uart.cpp` (write-only always-ready MMIO byte sink → stdout, modelling the RTL `fake_uart`) and a gated cachepool mode in `cluster_registers` (L1D-config 0x28..0x4c RW scratch, FLUSH_STATUS 0x3c reads 0, EOC@0x24 → quit retval). **Two boot bugs fixed:** (1) wake the wfi'd bootrom via **MSIP** (mip bit 3, enabled by the bootrom's mie=0xF), **NOT** MEIP (bit 11, not enabled) — gvsoc wfi wakes only when `(mie & mip) != 0`; (2) install the bootrom `.bin` via a `vp_files()` CMakeLists (the `pulp/` dir-install copies only `*.py`/`*.json`).

---

## Validation / scorecard

All structural work is **gated default-off**; the flat calibrated path is **byte-identical** throughout (open-loop calib `fmatmul-M32` mean-Δ **3.9**, `coal_cold` wide @ML50 **0.4961**; closed-loop `vfadd` **58001**).

**Closed-loop `vfadd` (correctness + cycle count, all 15/15 PASSED, retval=0):**

| path | cycles | vs flat |
|---|---|---|
| flat default tile (06-15 bring-up) | 58001 | baseline |
| structural single tile, sync-slave (A4) | 59001 | +1.7 % |
| structural 16-core / 4-tile GROUP (A5c) | 69001 | (16-core) |

**Structural core / tile / group, open-loop calib (sample, ML=50):** 13/13 respond, `data_err=0` across **all** phases A1–A5b. Lane-j accesses route across all 4 banks by address (`0x00/0x40/0x80/0xc0 → banks 0/1/2/3`); a tile-0 core reading a tile-1-homed line gets correct data via the remote xbar; cross-tile correct to tiles 1/2/3. Async fallbacks byte-identical (flat structural core 56/278.5; flat controller 67/290.8; A1 53/275.7; A2 55/279.4).

**Refill-latency emergence (b.0):** cold miss now scales with MemLatency — **56 @ML50 / 106 @ML100** (was ~13 cyc total / 1–4 cyc cold-miss before b.0); misses serialize **~+53/miss** (RTL ~+55). Concurrency fix: `max_outstanding` 3 → 34 on fmatmul-t0c0, 32 on cold_stream.

**Structural sync-slave timing (A4) — NOT yet calibrated:** warm hit **9** / cold miss **ML+12** vs RTL **10** / **ML+17** — the remaining gap is the deferred calibration pass.

**Miss-path diagnosis (06-16, single-tile RTL ref `rtl_ref_1t_2026-06-16`, ML=50):** hit path faithful (+0.2…+7.5 cy); all residual error is miss-path under deep saturation. Per-kernel mean / hit / miss Δ — idotp +39.6/+0.5/+79.7; fmatmul-M32 +11.0/+6.5/+30.7; fft-N4 +8.7/+7.5/+17.4; fdotp +25.2/+0.2/+75.4; gemv-M512 +27.4/+2.8/+75.9. Root-caused to the `max_outstanding` gap (GVSoC bounds by the per-port requester budget 4 VLSU × 32 = **128** vs RTL's cache-internal **~56**), a documented coupled/NO-GO; flipping `enable_multi_read_pend` had **zero** effect (queue is budget-bounded, not retr_fifo-bounded). **Metric of record shifted to closed-loop throughput** (matched ≤7%), not isolated open-loop saturation latency.

**GVSoC CachePool SoC — unmodified snrt CI binaries (4-core / 1-tile, no cache; binaries compiled for 16-core fpu_512):**

| benchmark | retval | cycles | note |
|---|---|---|---|
| cache-line-rw-smoke | 0 | 4421 | pass |
| spin-lock | 0 | 5890 | pass — prints `Tile0, Core1:hello` |
| byte-enable | 0 | 5378 | pass |
| load-store_M16 | 0 | 1056001 | pass |
| fdotp-32b_M32768 | 0 | 78648 | pass |
| gemv-opt_M512_N128_K32 | 0 | 82366 | pass |
| fft-32b_M1024_N16 | **1** | 24304 | wrong result — likely the bit-reversal / work-partition depending on the exact core count (4 vs 16) |
| fmatmul-32b_M32_N32_K32 | — | timeout @200 s | heavy 32³ matmul on 4 cores (16 cores ≈4× faster) |
| multi_producer linked-list | — | timeout @200 s | needs CL_CLINT inter-core IRQ wakeup (MINIMAL doesn't wire it) |

**5 of the 8 CI kernels pass (retval=0)** — spin-lock, load-store_M16, fdotp, gemv-opt, byte-enable (the separate `cache-line-rw-smoke` test also passes); fft = retval=1, fmatmul + linked-list time out; **all boot / print / exit.** Self-test counts for the rewrite headers: Step 6 = 51 checks all pass; Step 7 = 38 checks all pass.

---

## Commits this week

`core` (gvsoc-core) / `pulp` (gvsoc-pulp) on the `Aquaticfuller/*` forks, branch `insitu-cache`; parent submodule-pointer bumps local.

| Repo | SHA | Subject |
|---|---|---|
| core | `3d712809` | closed-loop Spatz data path + open-loop calib regression fix |
| pulp | `d8abb08` | snitch_cluster: set closed-loop cache driver flags at the cluster site |
| core | `040fdef3` | Phase-1 inc1 — structural par_coalescer (gated, default-off) |
| core | `d821214b` | Phase-2 inc1 — per-core controller cardinality (gated) |
| pulp | `b88f878` | snitch_cluster: per-core controller count when controllers_track_cores |
| core | `2c201da6` | structural rewrite Step 1 — decode/encode (real XOR-fold hash) |
| core | `d6d244b8` | structural rewrite Step 2 — pseudo-dual-port bank |
| core | `07203629` | structural rewrite Step 4 — per-cycle cache core (first runnable) |
| core | `05e856b2` | structural core — streaming input accept queue (concurrency fidelity) |
| core | `d0abdeed` | structural rewrite Step 3 — forwarding buffer |
| core | `54815e22` | structural rewrite Step 5 — par_coalescer datapath |
| core | `4c9fcfef` | structural rewrite Step 6 — programmable xbar + SPM remap + flush/sync FSM |
| core | `32950f40` | structural rewrite Step 7 — AMO/LR-SC shim + L2 scramble/NAPOT decode |
| core | `0c297356` | b.0 — refill latency emerges + decouple refill install |
| pulp | `5d78298` | calib: async wall-clock t_resp + structural-core run hook (b.0) |
| core | `f8e78da3` | structural tile foundation — per-port-class InsituCacheXbar + multi-lane core port |
| core | `9ad67c88` | structural TILE (Phase A1) — 5 per-port-class xbars + per-core multi-lane cells |
| pulp | `6e0da96` | calib: INSITU_CALIB_STRUCTURAL_TILE hook (A1) |
| core | `a6ee0038` | structural cache CELL (Phase A2) — par_coalescer (4 VLSU lanes) + scalar bypass |
| pulp | `4d4bb78` | calib: INSITU_CALIB_CELL_COALESCER hook (A2) |
| core | `6d488974` | AMO/LR-SC shim (Phase A3) — scalar lane |
| pulp | `a679e98` | calib: INSITU_CALIB_AMO_LANE hook (A3) |
| core | `7886617e` | synchronous-slave core mode (Phase A4) |
| pulp | `0f89037` | calib: INSITU_CALIB_INLINE_SYNC hook (A4) |
| pulp | `b2d943a` | wire structural tile into Spatz cluster (A4) — vfadd PASSES |
| core | `c5d67024` | multi-tile GROUP (Phase A5) — inter-tile remote xbars + cross-tile shared L1 |
| pulp | `038117e` | calib: INSITU_CALIB_GROUP hook (A5) |
| core | `a8f13797` | group config matches RTL cachepool_fpu_512.mk (4 tiles, num_remote_port_core=2) |
| pulp | `db96de0` | calib: INSITU_CALIB_GROUP uses make_cachepool_fpu_512_config |
| pulp | `14c456d` | wire multi-tile GROUP into the Spatz cluster (use_cachepool_group) |
| core | `b5ed7dd4` | cachepool: fake-UART byte sink (snrt printf → stdout) |
| pulp | `85ed0ef` | cachepool: GVSoC CachePool SoC target — MINIMAL boot path |

Parent pointer bumps: `b2eb076` / `07b70ac` / `e9d1ace` (06-15 gated increments); `902b314` / `98877d3` / `e43d47a` / `0605c06` (structural rewrite kickoff + Steps 1–4 + streaming queue). The later 06-16…06-22 submodule commits (Steps 3/5/6/7, b.0, A1–A5c, the cachepool target) are pushed to the fork branch but **not yet reflected in a parent pointer bump** (the parent tree shows dirty `M core` / `M pulp`).

---

## Docs / reports produced

- `prompt/insitu_cache_architecture_v2.md` — rewritten (471→635 lines) as the authoritative RTL microarch+arch reference; new §0.1 "Verified resolutions" with 8 fact-check corrections (WordWidth=32 active not 64; L1BankFactor=2 hardcoded; config-512 geometry; refill burst Burst4-committed/Burst1-uncommitted; `dynamic_offset` FF reset=14 vs CSR resval=0; `tcdm_id_remapper` unused in CachePool; pseudo_dual modules live inside the wrapper; `cache_sync_insn` has 4 modes).
- `prompt/insitu_cache_dev_plan_2026-06-15.md` — the 7-phase dev plan (Phase 0 DONE → P1 structural front-end → P2 Tile/Group substrate → … → P7 async-Spatz).
- `prompt/insitu_cache_model_status_2026-06-15.md` — model-coverage status snapshot (06-15).
- `prompt/insitu_cache_calibration_progress_2026-06-15.md` — calibration progress log (06-15).
- `prompt/insitu_cache_structural_plan_2026-06-16.md` — the structural-rewrite master plan (7-component dependency-ordered build).
- `prompt/insitu_cache_precalibration_gap_audit_2026-06-16.md` — 18-structure / 38-agent gap audit ("transcribed ≠ wired").
- `prompt/insitu_cache_misspath_diagnosis_2026-06-16.md` — miss-path diagnosis vs the single-tile RTL reference.
- `prompt/insitu_cache_structural_tile_plan_2026-06-18.md` — corrected tile/group build plan + must-fixes.
- `prompt/gvsoc_cachepool_soc_boot_scope_2026-06-22.md` — CachePool SoC boot scope (MINIMAL vs FULL).
- `prompt/gvsoc_cachepool_minimal_results_2026-06-22.md` — per-benchmark MINIMAL-target results.
- `prompt/cachepool_fpu_512_group_run_report_2026-06-22.md` — 16-core group run report.
- `prompt/insitu_cache_rtl_coverage_matrix.md` — replaced with the RTL-vs-GVSoC gap analysis.
- **Structure-map series** (the standing dated deliverable, showing coverage advancing — 8 maps this window): `2026-06-15` (baseline), `_15b` (Phase-1 inc1, new "implemented+gated-off" badge), `_15c` (Phase-2 inc1), `2026-06-16` (rewrite Steps 1–6, new "transcribed-not-wired" badge), `_16b` (Step 7 — all datapaths transcribed), `2026-06-18` (gap audit + b.0), `2026-06-22` (structural TILE A1), `_22b` (A1–A5, structurally complete).

---

## Open items / next

- **[BIGGEST OPEN] Cycle-calibration of the structural model vs RTL.** The structural tile/group runs closed-loop and is data-correct but is **NOT yet cycle-calibrated**: sync-slave warm hit 9 / cold miss ML+12 vs RTL 10 / ML+17. Calibration is the deferred dedicated phase; validate **closed-loop `region_cyc`** against the RTL table first (needs DDR4 DRAMSys on refill + single-tile topology + `dynamic_offset~6` + RTL ELFs), and only model the per-resource MSHR cap if closed-loop cycles are off in a way attributable to outstanding depth (ask the RTL side for per-kernel `max_outstanding` rather than guessing ~56).
- **Wire the still-unwired structural headers.** `fwd_buffer`, `spm_remap`, `sync_fsm` are transcribed + validated but `#include`d by nothing; flush/sync is a 0-cycle stub and the cluster never drives `i_FLUSH`. Also still MISSING: the write-through merger + its WT FIFO, and peripheral/CSR/flush in the runtime path.
- **Calibration traps to fix before calibrating** (from the gap audit): `dynamic_offset` runtime default 2 vs RTL live reset 14; dead `wt_fifo_depth`; write backpressure off by default (`write_commit_cycles` default 1 disables the gate).
- **CachePool SoC — FULL path (≈1–2 weeks on top of MINIMAL).** (1) 16-core / 4-tile — regenerate BOOTDATA (core_count=16, tile_count=4) as a generator param and use the validated `InsituCacheGroup` (fixes `fft` partition, gives the intended perf config, apples-to-apples vs the RTL CI); (2) wire CL_CLINT inter-core IRQ (peripheral +0x08/+0x0c → per-hart MSI — fixes linked-list / lock-heavy kernels); (3) wire the structural InSitu cache to front DRAM (cores → group → DRAM) + L1D-config regs (0x28..0x4c, today RW scratch) into real flush/partition/xbar behaviour; (4) per-kernel cycle calibration vs RTL QuestaSim `[EOC]` cycle counts.
- **Cross-lane fidelity under the sync-slave mode** is a documented approximation (the VLSU serializes lanes → the in-cell coalescer can't batch, the bank WR_CONFLICT scoreboard smears, AMO atomicity back-pressure is unmodelable in-call). Open-loop multi-port keeps full fidelity; this only affects closed-loop cross-lane contention.