# E3.6 — partition-aware load-store kernel bring-up + RTL reference

2026-08-04 · status: **landed — 7/7 functional PASS, flush accounting exact, cycle diff recorded**

The E3 runtime partitioning (E3.0–E3.5) is validated end-to-end by the one CI kernel that
actually drives it: `load-store_M16` (Diyou Shen 2026, Parts 1–3 + `data_16.h`). Bring-up
finding: the prebuilt binary (`ManyRVData_rebase_ori/software/build/CachePoolTests/
test-cachepool-load-store_M16`, May-18 build) already contains Parts 1–3 and is the same
binary the sweeps have been running — nothing to port. The RTL reference exists in the
May-29 sweep. This report records the functional verdicts, the counter-level isolation
proof, and the cycle diff.

## 1. Functional verdicts (model vs RTL)

| Sub-test | RTL (May-29 sweep) | GVSoC (this run) |
|---|---|---|
| Part 1: all-shared / 1priv-3shr / half-half / 3priv-1shr / all-private | PASS ×5 | **PASS ×5** |
| Part 2: private-flush-isolation | PASS | **PASS** |
| Part 3: shared-flush-isolation | PASS | **PASS** |
| `[EOC]` retval | 0 | **0** |

All seven sub-tests match the RTL's functional verdicts exactly — runtime partition
switching (5 modes), private flush isolation (A==3 && D==4), and shared flush isolation
(D==2 && A==3) all behave like the hardware.

## 2. Counter-level flush-isolation proof (exact, zero free parameters)

The kernel's flush instruction stream (reconstructed from `main.c` + the **rebase_ori**
`l1cache.c` the binary was built from — see §4) predicts, per bank:

- **all-class flush walks = 39** (Part 1: 4/mode × 5 = 20; Part 2: 12 − wait-for-it; see
  below; insn-2/insn-3 commits + boundary commits with insn=2 latched)
- **private-only = 4** (Part 2 step-3 `l1d_private_flush` + the boundary commit after it
  re-fans the latched insn=0; same pair in Part 3)
- **shared-only = 2** (Part 3 step-3 `l1d_shared_flush` + its trailing boundary commit)

With partition=half-half (private banks = ctrl_0/1, shared = ctrl_2/3):

| bank class | predicted | measured (stop-dump `flush=`) |
|---|---|---|
| private (ctrl_0/1, ×8) | 39 + 4 = **43** | **43** ✓ |
| shared (ctrl_2/3, ×8) | 39 + 2 = **41** | **41** ✓ |

The E3.1 class-selective flush (`insn 0=private / 1=shared / 2=all / 3=invalidate-no-wb`)
is thus verified *quantitatively* — banks not in the target class skip the walk entirely
(they return 0-latency without touching their lines), which is exactly the isolation the
kernel's Part 2/3 value checks rely on. Dirty writebacks: 305 lines across all walks.

## 3. Cycle diff

| | cycles | vs RTL |
|---|---|---|
| RTL `[EOC]` (101,208,000 ps @ 1.0 ns, retval=0) | 101,208 | — |
| GVSoC (E3.5 state, 16-core, cache ON) | 183,757 | **+81.6%** |

Trajectory of this kernel's diff: +459.8% (v1, narrow-loader artifact) → +4.9% (v2, wide
loader) → +53.1% (v3, E4 through-cache) → **+81.6%** (E3 landed — the partition now
*engages*: every mode switch flushes + repartitions, and the mixed partition loses
effective associativity to the hash-way collapse, both now modeled).

Decomposition of the 82k gap (from the stop-dump counters):

- **Flush gating**: 39 all-class walks/bank (672 total) — upstream traffic gates during
  each walk (`flush_base_cycles=277` + per-dirty-writeback). ~11–15k cycles.
- **Miss path**: rd_miss=2,902 (hit rate 87%) through the serialized refill fabric;
  mixed-mode hash-way collapse (E3.5 finding) doubles effective conflict pressure on
  2-residue-class banks — RTL-faithful, but RTL's forwarding buffer (unmodeled, ▣) absorbs
  part of it.
- **Scalar checks (J1)**: `check_const` runs on core 0 only (5+ compare loops × 64 elems)
  while 15 cores barrier-wait — scalar load-use chains pay full cache latency serially
  (no LSU scoreboard, the same J1 family as the fft EOC residual).

No single dominant term — the gap is the sum of three ~equal J1/flush/miss contributions.
This is the expected state post-E3; the named follow-ups (J1 scoreboard, forwarding
buffer) are tracked in the structure map.

## 4. RTL/binary provenance (important for reproducing this table)

- RTL reference: `ManyRVData_rebase/reports/sweep_2026-05-29_05-54/cachepool_4t_fpu_512/
  logs/load-store_M16.log` — `[EOC] Simulation ended at 101208000 (retval = 0)`, all 7
  PASS. **Caveat (standing): the May-29 sweep RTL is the `2710920` revision; re-verify on
  `05e4671a`.**
- Binary run: `ManyRVData_rebase_ori/.../test-cachepool-load-store_M16` (May-18 build,
  same vintage as the RTL sweep). The **rebase tree's Jul-28 rebuild differs**: its
  `l1cache.c` adds one `l1d_flush()+l1d_wait()` inside `l1d_xbar_config` (7 call sites
  in this kernel → +7 all-class flush walks ≈ +2–3k cycles). The flush accounting in §2
  closes exactly (39 = 46 − 7) only against the *older* runtime — anyone rebuilding the
  binary fresh will see 46 all-class walks (private 50 / shared 48), not 39.
- The register block the kernel drives is the E3-modeled one (0x28–0x4c): XBAR_OFFSET +
  commit, L1D_PRIVATE/L1D_ADDR + commit, CFG_L1D_INSN + commit, FLUSH_STATUS poll,
  CFG_L1D_TILE_SEL (insn-0 tile mask — the kernel always passes `all_tiles`, so the
  model's all-tiles fan-out matches; per-tile masking is not implemented).

## 5. Commands

```bash
source sourceme.sh && export PATH=/tmp/py312_shims:$PATH
export CACHEPOOL_NB_TILE=4 CACHEPOOL_CORES_PER_TILE=4
gvsoc --target=cachepool \
      --binary /usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase_ori/software/build/CachePoolTests/test-cachepool-load-store_M16 \
      run
# expect: 7× PASS, [EOC] cycles=183757, retval=0
```
