# RLC Kernel — Handover Doc for the GVSoC-side Agent

**Audience:** the agent continuing RLC kernel development with **GVSoC** as the simulator (no RTL
simulation needed for day-to-day work).
**Scope:** where things live, current state, what to do next and why, and exactly how to build and
run the kernel.
**Date:** 2026-08-10. **Repo state:** branch `fix/cache-refill-throughput`, kernel commit
`d172ae5` ("rlc: multi-user RLC kernel with use-case switching").

---

## 1. Repositories and key paths

| What | Path |
|---|---|
| RTL + software repo (the kernel lives here) | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase` |
| The RLC kernel | `software/tests/multi_producer_single_consumer_double_linked_list/` |
| GVSoC repo | `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_GVSoC/gvsoc` |
| Email thread driving the plan | `ManyRVData_rebase/reports/email/` (Johannes Pfau ↔ Zexin, Aug 4–5 2026) |

Kernel directory layout:
```
multi_producer_single_consumer_double_linked_list/
├── README.md                       # build/run quickstart (verified commands)
├── main.c                          # entry: init, barrier, dispatch
├── kernel/
│   ├── rlc.c / rlc.h               # THE kernel: tasks, rlc_context_t, use-case config
│   ├── llist.c / llist.h           # intrusive doubly-linked list + locks; Node has user_id
│   ├── mm.c / mm.h                 # node page allocator (MM_POOL_PAGES knob)
│   ├── data_move_vec.{c,h}         # RVV memcpy variants (1360 fast path + generic)
│   └── printf_lock.{c,h}
├── data/                           # generated headers data_<users>_<len>_<pkgs>.h (+ flowchart)
├── script/generate_pdcp_pkg.py     # data generator (+ pdcp_pkg*.json configs)
└── doc/
    ├── KERNEL_REVIEW_NOTES.md          # READ FIRST: protocol + kernel mechanism notes
    ├── MULTI_USER_EXTENSION_REPORT.md  # multi-user design, before→after diagrams
    ├── HANDOVER_GVSoC_AGENT.md         # this file
    └── (3 source spec docs: DP Introduction.docx, ETH RLC Introduce v0.2.pptx,
         ManyRVDataPlaneV2.docx — see KERNEL_REVIEW_NOTES.md §2 for what each contains)
```

## 2. Current state (verified results)

**Working and verified on RTL (`cachepool_fpu_512`, 16 cores / 4 tiles):**

| Config | EOC cycles | kernel work-phase cycles | status |
|---|---|---|---|
| TC1 `M1_N1350_K100` (1 UE, 2P2C) | 241,905 | 130,828 | clean; +0.23% vs pre-extension baseline (241,344) |
| TC1 `M1_N1350_K300` 2P8C | 524,537 | 400,684 | clean |
| TC1 `M1_N1350_K300` 4P8C | 328,572 | 205,583 | clean |
| TC2 `M48_N800_K300` (48 UE, 2P2C) | 651,553 | 530,059 | clean |
| TC2 `M48_N800_K1000` 2P2C | 1,872,345 | 1,742,383 | clean |
| TC2 `M48_N800_K300` 4P4C | 438,205 | 316,688 | clean |

**Open bug (documented in the commit message):** TC2 with `CONSUMER_CORE_NUM ≥ 8` corrupts
memory — `2P8C`: 1 scoreboard violation (wild access `0x38000930`); `4P8C`: catastrophic (wild
stores → corrupted text → illegal instruction → deadlock). Details + evidence in §5.

**What the kernel does now (one paragraph):** one RLC entity per UE
(`rlc_ctx[NUM_USERS]`, 64 B-aligned, `NUM_USERS` from the data header's `ACTIVE_USER_NUMBER`);
producers pull PDCP packet descriptors `{user_id, src, tgt, len}` and enqueue nodes to
`rlc_ctx[uid]` under per-user locks; consumers serve a static partition of users
(`{u : u % min(C,N) == c % min(C,N)}`, N=1 ⇒ all consumers share user 0 = the old single-user
behavior); per-entity sequence numbers (`vtNext`) and poll counters; core 0 runs the STATUS-PDU
simulation per entity (`vtNextAck += 2`, frees 2 nodes). Use case is selected at build time by
the data header (M/N/K naming). Full mechanism: `doc/MULTI_USER_EXTENSION_REPORT.md`.

## 3. Plan & rationale for further development

Context: the Huawei-side contact (Johannes Pfau) is writing a **new RLC AM kernel** (free SW
redesign: TTI-based scheduling, preferred-tile UE assignment, possibly lock-free deques). Ours
becomes the **spec-faithful baseline** for an A/B comparison (emails in `reports/email/`).

**Sequencing agreed with the user (2026-08-10, final):** PRs first (done), then **functional
scope — UL processing + control/scheduling algorithm — before any performance-side features**
(near-data placement, DMA stub, TTI placement optimizations). Rationale: functional content
defines the benchmark; performance evaluation is downstream of it, and both sides' kernels must
share the same functional scope for the A/B comparison to be meaningful. Multi-group validation
is a **parallel track** (independent capability check; gates the scaling studies, not the
functional work).

### Step 0 — External PRs (done on our side 2026-08-10)

- `pulp-platform/ManyRVData#25` (bootrom toolchain de-hardcode): merged as FF to
  `fix/cache-refill-throughput` (`32ed552`); bootrom rebuilt with `install/riscv-gcc`
  (riscv32-gcc 7.1.1) and verified in RTL sim (K100: EOC 241,339, retval=0, 32/32 SB PASS).
- `Aquaticfuller/gvsoc#1` (https submodule URLs): merged into local GVSoC `main` (`f511d7d`).
- Both are **local until pushed** — the user pushes.

### Step 1 — Functional scope: UL processing + control/scheduling algorithm (their side leads)

- **What:** uplink receiving-side processing (reassembly/reordering, per the DP doc's UL test
  parameters) and the TTI control/scheduling layer (which RLC entities transmit in each TTI,
  how much data — the "Control Algorithm Tasks" of the DP Introduction doc).
- **Why first:** these define the benchmark's functional content. Performance features
  (near-data, DMA, scaling) are evaluations *of* this workload and must not be baked against a
  DL-only baseline.
- **Our role:** specify from the docs (UL params per test case; 38.322-lite semantics within the
  documented simplifications: ACK-only, no timers/retx), review the design, integrate into our
  baseline kernel so both kernels stay functionally aligned.

### Step 2 (parallel track) — Multi-group GVSoC validation

- **Target:** `--target=cachepool_v2` (4×4 groups × 4 tiles × 4 cores = 256 cores, 2D mesh).
  Build GVSoC with the right env first (see §5.1 pitfall; for v2: `CACHEPOOL_V2_*` knobs).
- **Two acceptance levels:** (a) per-group instances — 16 independent RLC kernels, one per
  group (minimal SW change: group-aware init/dispatch); (b) one shared kernel across the mesh
  (producers/consumers spanning groups — the real interconnect stress test).
- **Dataset:** start with TC2 48-user (known-good at 2P2C/4P4C on 16 cores), then sweep
  consumer counts.
- **Watch-items:** barrier scope across groups (partial-barrier semantics), bootrom core/tile
  patching for 256 cores, `.data` placement (single shared image vs per-group), UART contention.
- **Gate:** must be green before any scaling numbers are reported — not before Step 1.
- **Note:** if multi-group GVSoC runs clean at high consumer counts while RTL corrupts (the C≥8
  bug below), that's evidence the bug is RTL-timing-related — record it.

### P0 — Root-cause the C≥8 corruption (RTL-side, in parallel)

*Why:* the baseline must be trustworthy at all core counts; thread-scaling studies are a stated
project deliverable. Also: extensive analysis has NOT found a software cause, so this may be an
RTL issue the kernel exposes — valuable either way.

*Evidence so far (all exonerated):* node lifecycle (a guard validating every descriptor and
popped node fired 0×); consumer-partition logic (single-user is clean at ALL core counts,
incl. 4P8C); producer count (4P4C clean); descriptors and generated headers verified.
*Pattern:* corruption probability scales with consumer count; only in the 48-user config.
First anomaly observed at t≈24.3 µs (core 4, wild payload write to `0x480008b0`).
*Next steps:* (a) waveform-mine the first wild store's PC+operands (capture recipe in §5);
(b) check the `vector_memcpy32_m8_m4_general_opt` path (TC2-only) — inline asm without
memory/vreg clobbers around `vle32/vse32` + `vsetvli`, suspicious under shared-VLSU concurrency;
(c) check the SN store `*(volatile uint32_t *)node->tgt = sn` ordering vs. the async vector copy.

### P1 — Baseline performance package

*Why:* Johannes' kernel will be compared against ours; the numbers must be curated and
reproducible. *What:* TC1 + TC2 table (EOC + work-phase cycles, L1 hit/miss, forwarding-buffer
stats, P/C sweep), plus per-UE throughput stats if needed. Most raw numbers are already in
`reports/WORKLOG.md` (2026-07-27/28 entries) and `MULTI_USER_EXTENSION_REPORT.md` §4.

### P2 — Near-data / TTI enablement pieces (our side, not the new kernel)

*Why:* his design needs them, and they improve our baseline too; agreed in the email thread.
1. **Per-tile arena placement** for `rlc_ctx[u]` (entity state in the private partition of the
   tile that will serve it) — today cacheline interleaving scatters each entity across banks.
   Knobs: `l1d_part`, `l1d_addr`, `l1d_xbar_config`.
2. **Correlated UE distributions in the data generator** (his custom test cases): tile-affine UE
   assignment + temporally-correlated per-TTI activity instead of uniform random. Small change
   in `script/generate_pdcp_pkg.py`.
3. **TTI structure**: producers/consumers currently free-run; the spec wants 500 µs TTIs with
   4:1 DL:UL slots and ~350 µs per-entity budget. A TTI scheduler variant (even simple) makes
   the benchmark more realistic and enables static entity→core scheduling per TTI.

### P2 — GVSoC-only features (no RTL)

- **DMA payload stub** (Johannes' idea): model payload DMA-out to the network port — read from
  DRAM, don't copy, bypass L1 → no cache pollution. Implement in GVSoC only; not in RTL.
  Validation: RTL traces show payload traffic dominates L1 misses today, so the effect is
  measurable and cross-checkable.
- The volatile payload reads in the current kernel were a deliberate traffic model, not a
  product-design claim — fine to replace with the DMA model.

### P3 — deferred (per email agreement)

- **TC3 dataset** (4800 UEs): mostly a generator + memory-layout question; do when needed.
- **ACK-generation realism:** deprioritized (no timers/retx ⇒ ACKs always arrive; only delay varies).
- (UL processing + control/scheduling logic were promoted to **Step 1** — functional scope comes
  before performance features.)

## 4. How to build the RLC kernel (detailed)

The kernel is compiled **in the RTL repo** (RISC-V toolchain there); GVSoC then runs the ELF.

### 4.1 Prerequisites (once per fresh clone)

```bash
cd /usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase
make bender                 # dependency tool
make quick-tool             # ETH only: links prebuilt RISC-V toolchain into install/
                            # (else make toolchain — builds LLVM+GCC from source, hours)
make init                   # checkout deps via Bender into hardware/deps
```
Python 3 with `jinja2` + `hjson` required.

### 4.2 Full software build (first time / after changing `config=`)

```bash
make sw config=cachepool_fpu_512
```
This implies `generate` (config headers) and `bootrom`, and **wipes `software/build/`** first
(don't put anything precious there). All test ELFs land in `software/build/CachePoolTests/`.

### 4.3 Incremental build of just the RLC kernel (fast, no wipe)

```bash
cd software/build
cmake .                      # only needed after CMakeLists.txt changes
make test-cachepool-multi_producer_single_consumer_double_linked_list_M1_N1350_K100
make test-cachepool-multi_producer_single_consumer_double_linked_list_M48_N800_K300
```

### 4.4 Variant naming and where binaries land

Binaries: `software/build/CachePoolTests/test-cachepool-multi_producer_single_consumer_double_linked_list_<VARIANT>`

| Variant | Use case | Notes |
|---|---|---|
| `M1_N1350_K{10,100,300}` | TC1 single-user (1 UE, 1350 B) | K100 = CI standard |
| `M48_N800_K{300,1000}` | TC2 multi-user (48 UE, 800 B) | |
| `M48_N800_K300_P2_C2 / P2_C4 / P4_C4 / P2_C8 / P4_C8` | TC2 thread-scaling (producer/consumer counts) | P2_C8, P4_C8 currently FAIL (see §5) |
| `M48_N800_K300_sc` | TC2 + payload self-check | prints pass/fail summary |

Variant↔data mapping: `M<users>_N<pkt_len>_K<num_pkgs>` ⟷ `data/data_<users>_<len>_<pkgs>.h`
via `-DDATAHEADER` (see `software/tests/CMakeLists.txt`, `add_spatz_test_threeParam` /
`add_spatz_test_rlc`). **Never hard-include a data header in rlc.c** — that shadowed DATAHEADER
historically and made all K-variants byte-identical.

### 4.5 Adding a new use case / dataset

```bash
cd software/tests/multi_producer_single_consumer_double_linked_list/script
# create/edit a JSON (active_user_number, pkg_length, pdcp_header_length, total_pkg_number, src/tgt windows)
python3 generate_pdcp_pkg.py pdcp_pkg_48_800_300.json     # → ../data/data_48_800_300.h
```
The header emits `ACTIVE_USER_NUMBER` (→ kernel's `NUM_USERS`), `PDU_SIZE`, `PDU_STRIDE`
(4-B-aligned slot stride; required or vector copies trap on misaligned PDUs like 810 B).
Then register in `software/tests/CMakeLists.txt` and rebuild (§4.3).

### 4.6 Useful compile-time defines

| Define | Effect |
|---|---|
| `PRODUCER_CORE_NUM` / `CONSUMER_CORE_NUM` | core mapping (default 2/2); `_P_C_` variants set these |
| `RLC_ENABLE_PACING=1` | enable 7 MB/s rate pacing (64-bit fixed math; default off = flat-out) |
| `RLC_SELF_CHECK=1` | payload src/tgt compare after the barrier (skips SN word + modeled-rewrite range) |
| `RLC_NODE_GUARD=1` | debug: validate descriptor/node fields at pop time |
| `MM_POOL_PAGES=<n>` | node pool size (default 1024; live nodes ≤ min(NUM_PKGS, pool)) |

## 5. Running in GVSoC

### 5.1 Build GVSoC (once per topology)

```bash
cd /usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_GVSoC/gvsoc
export CACHEPOOL_NB_TILE=4 CACHEPOOL_CORES_PER_TILE=4 CACHEPOOL_BANKS_PER_TILE=4   # 16c/4t config
CXX=g++-14.2.0 CC=gcc-14.2.0 CMAKE=cmake-3.18.1 make all TARGETS=cachepool
source sourceme.sh
```

**Pitfall (this is the error Johannes hit):** the env vars are *runtime* knobs, but cache
components are compiled into `install/models/` at *build* time. The inter-tile remote crossbar
(`insitu_cache_remote_xbar`) is only instantiated when `NB_TILE > 1` — a single-tile build never
compiles it, so running later with `NB_TILE=4` fails with
`Couldn't find component (name: gen_cache_insitu_insitu_cache_remote_xbar_cpp_...)`.
Fix = rebuild with the env vars set (as above), then run with the same env. Default (no env) =
1 tile × 4 cores.

### 5.2 Run

```bash
gvsoc --target=cachepool --binary \
  /usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/software/build/CachePoolTests/test-cachepool-multi_producer_single_consumer_double_linked_list_M48_N800_K300 \
  run
```
EOC cycles come from the simulator output (same EOC mechanism as RTL).
`CACHEPOOL_USE_CACHE=0` disables the cache model for A/B runs.

### 5.3 RTL reference numbers (for GVSoC alignment)

Use §2's table. Note: GVSoC (not timing-exact at the pipeline level) may **not** reproduce the
C≥8 corruption — if it doesn't, that itself is evidence the bug is RTL-timing-related; report it.

## 6. The open C≥8 corruption bug — debug dossier

- **Symptom:** TC2 (48 UE) only, `CONSUMER_CORE_NUM ≥ 8`. 2P8C: 1 SB violation (payload mismatch
  at wild addr `0x38000930`). 4P8C: wild stores (addr=0, `0x480008b0`, `0x68000bc0`…),
  text corruption (`0x80001640` overwritten with `0x00000004`) → illegal instruction on
  consumer cores → deadlock.
- **Exonerated:** node lifecycle (RLC_NODE_GUARD fired 0× — every popped node's fields valid);
  consumer partition logic (M1 clean at 2P8C AND 4P8C); producer count (4P4C clean); generated
  data headers (user_id ∈ [0,47], stride-aligned); VLSU operand latching (offload bundles
  carry rs1/rs2 values).
- **Suspects (unresolved):** (a) `vector_memcpy32_m8_m4_general_opt` inline asm (TC2-only path)
  lacking `memory`/vreg clobbers around `vle32/vse32/vsetvli` — compiler reordering or
  shared-VLSU vsetvli/VRF interference under high concurrency; (b) SN scalar store racing the
  async vector copy; (c) a genuine cache RTL race exposed only by this traffic shape.
- **Reproduce:** build + run `..._M48_N800_K300_P4_C8` on RTL (`make vsim` then the launcher in
  README §3). Fails ~reliably. A 60 µs waveform capture of the failing core was taken earlier
  (do-file pattern: `log -r` the cc + L1-ctrl scopes, `run 60us`) — regenerate if needed.
- **Known SB noise:** `SPATZ-SB ... dup_push` assertion prints occur in ALL kernel variants
  (incl. the pre-PR kernel) — timing artifact of the request scoreboard, NOT the failure
  signature. The failure signature is `Visited illegal address` / `RESP DATA MISMATCH` /
  `Illegal Instruction` / `STATUS: FAIL`.

## 7. Ground rules (from repo convention + user preferences)

- `reports/WORKLOG.md`: append an entry on every meaningful change/commit (newest at top;
  include date, commit, files, what+why, verification). Weekly reports are assembled from it.
- Commit messages: terse, no tool attribution; the user reviews before committing.
- Do NOT commit `doc/*.docx|pptx` (Huawei doc is internal-use-only). Markdown notes are fine.
- `/tmp` is volatile — put run artifacts under `reports/` (learned the hard way).
- If RTL verification is needed: full flow in `README.md` §3 (the RTL sim build currently exists
  for `cachepool_fpu_512`; `make vsim config=...` to rebuild).
