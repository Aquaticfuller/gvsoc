# Multi-user linked-list (RLC) — large-config sweep + throughput/TTI report

**Date:** 2026-08-05 · **Model:** `--target=cachepool`, post-J1 build (scalar LSU nb_outstanding=16
+ sync-OK AMO stall-on-use; core `e0ed63d5`, pulp `a1e0294`) · **supersedes** the 16-core table of
`multiuser_llist_sweep_2026-07-27.md` (numbers shift by ≲2% from the J1 LSU change).
**Kernel:** `multi_producer_single_consumer_double_linked_list` — 810 B PDUs (800 B payload + 10 B
PDCP header), 300 pkgs total = **243,000 B on the wire**, pacing off (the HW runs free; the
requirement check below is what the pacing loop would enforce in SW).

**Requirement reference (from the kernel itself, `kernel/rlc.c`):** `INPUT_DATARATE =
OUTPUT_DATARATE = 7 MB/s` aggregate at a 1 GHz core clock. **5G TTI = 1 ms = 1,000,000 cycles.**
At the required rate the 243,000 B job occupies 243,000 / 7,000,000 = **34.7 ms = 34.7 TTIs**.

## 1. New software configs (added for this sweep)

Registered in the RTL repo (`ManyRVData_rebase/software/tests/CMakeLists.txt`, macro
`add_spatz_test_rlc`) + one new generated data header:

| Variant | Active cores | Purpose |
|---|---|---|
| `M48_N800_K300_P16_C48` | 64 | all-cores-work at 16×4 = 64 (16 producers × 3 UEs, 48 × 1) |
| `M48_N800_K300_P48_C48` | 96 | the M=48 ceiling (48 producers × 1 UE, 48 × 1) |
| `M256_N800_K300_P128_C128` | 256 | all-cores-work at 64×4 = 256 (new `data_256_800_300.h`, same 300 pkgs) |

Build (RTL repo): edit registered → `cd software/build && cmake . && make <target>` — committed
to the RTL repo as working-tree edits (CMakeLists + `script/pdcp_pkg_256_800_300.json` +
`data/data_256_800_300.h`).

## 2. Results — 16-core reference (re-run at current model state, all retval=0, 0 errors)

| Config | Topology | Active | EOC cyc | Work phase | Work time | Equiv. throughput | vs 7 MB/s | TTI used |
|---|---|---|---|---|---|---|---|---|
| P2/C2 (default) | 4×4 = 16 | 4 | 954,001 | 550,721 | 551 µs | 441 MB/s | **63×** | 0.55 |
| P2/C8 | 4×4 = 16 | 10 | 919,001 | 514,686 | 515 µs | 472 MB/s | **67×** | 0.51 |
| P4/C4 | 4×4 = 16 | 8 | 710,001 | 306,523 | 307 µs | 793 MB/s | **113×** | 0.31 |
| P4/C8 | 4×4 = 16 | 12 | 659,001 | 255,565 | 256 µs | 951 MB/s | **136×** | 0.26 |

Work phase = `max(end cycle) − min(start cycle)` across all cores' prints. Equiv. throughput =
243,000 B / (work × 1 ns). TTI used = work × 1 ns / 1 ms.

## 3. Results — 32-core (8×4), 64-core (16×4), 256-core (64×4)

| Config | Topology | Active | EOC cyc | Work phase | Work time | Equiv. throughput | vs 7 MB/s | TTI used |
|---|---|---|---|---|---|---|---|---|
| P4/C8 | 8×4 = 32 | 12 (+20 idle) | 690,001 | 239,737 | 240 µs | 1,013 MB/s | **145×** | 0.24 |
| P4/C8 | 16×4 = 64 | 12 (+52 idle) | 868,001 | 236,394 | 236 µs | 1,028 MB/s | **147×** | 0.24 |
| P4/C8 | 64×4 = 256 | 12 (+244 idle) | 4,551,830 | 2,201,761 | 2.20 ms | 110 MB/s | **16×** | 2.20 |
| P16/C48 | 16×4 = 64 | 64 (all) | — storm² | | | | **FAIL** | ≫ 34.7 |
| P48/C48 | 64×4 = 256 | 96 (+160 idle) | — storm² | | | | **FAIL** | ≫ 34.7 |
| P128/C128 (M256) | 64×4 = 256 | 256 (all) | not attempted³ | | | | | |

² **All-active configs ≥64 cores livelock on the kernel's retry storm** (§7): killed after ~27 h
each with `rd_hit` = 22.9 G (P16/C48) / 34.2 G (P48/C48) on a single flag line and producers
starved — the 300-pkg job cannot drain in any practical window (≫ the 34.7-TTI budget at the
required rate, and ≫ any TTI at all). This is a kernel property (the consumer retry loop is in
the source), faithfully reproduced — no RTL reference exists for all-64-work either.

³ P128/C128 (M256, 256 active) was not run: same storm structure as P48/C48 at 2.7× the
contenders. The binary + data header are built and registered for anyone who wants to try.

## 4. Reading the numbers

- **Requirement verdict:** every configuration with ≤16 active cores delivers the 243 kB job
  16–147× above the 7 MB/s requirement and in ≤ 2.2 TTIs. The platform is not the binding
  constraint; the pacing loop (`RLC_ENABLE_PACING`, off by default) is what would throttle the
  kernel to the air-interface rate.
- **Thread scaling at 16 cores** (unchanged from the 07-27 finding): producers saturate first,
  consumers pay off once producers keep up.
- **Topology scaling at fixed 12-thread P4/C8:** 255,565 (16c) → 239,737 (32c) → 236,394 (64c)
  → **2,201,761 (256c)**. Extra banks help up to 16 tiles; at 64 tiles the single-group remote
  fabric inverts hard (+832%) — cross-tile hop latency × contention on every shared-list line.
  The RTL's 256-core is 16 GROUPS of 4 tiles (hierarchical), not one 64-tile group — our
  single-group 256-core is the pessimistic bound.
- **Active-core scaling inverts at ~12–16:** P4/C8-class (12) completes everywhere; P16/C48
  (64) and beyond livelock on the retry storm (§7). The kernel's practical ceiling is ~16
  active cores.

## 5. Commands

```bash
source sourceme.sh && export PATH=/tmp/py312_shims:$PATH
B=<ManyRVData>/software/build/CachePoolTests
K=test-cachepool-multi_producer_single_consumer_double_linked_list
# 16-core: CACHEPOOL_NB_TILE=4  | 64-core: 16 | 256-core: 64 — CORES_PER_TILE=4 always
CACHEPOOL_NB_TILE=64 CACHEPOOL_CORES_PER_TILE=4 \
  gvsoc --target=cachepool --binary $B/${K}_M256_N800_K300_P128_C128 run > run.log 2>&1
# work phase = max(end cycle) − min(start cycle) over the per-core prints; EOC = last cycles=
```

## 6. Sidebar: the >32-core barrier deadlock (found by this sweep, fixed)

The first 64/256-core runs sat at 100% CPU for 6+ hours with **zero output** — deadlocked, not
slow. Diagnosis: the SIGINT dump showed ~zero data traffic on every cache bank (only the boot
stack writes, ~1/bank) and one bank with **rd_hit = 19.5 billion** (256 cores spinning one
cached line = the bootrom park flag, never released). Root cause in `cluster_registers.cpp`:
the counting barrier's state was a **`vp::reg_32` bitmask** — `1 << core_access` is UB at ≥32
and the completion mask `(1ULL << nb_cores) - 1` is 0 at nb_cores=64/256 (`1ULL << 64` is UB) —
the barrier never completed, every core parked `IO_REQ_PENDING` forever. The boundary is exact:
8×4 = 32 works, 16×4 = 64 hangs. Fix: 64-bit state (`b0ef656`), then the **counting barrier**
(`92f699f`) after 256 cores SIGSEGV'd on the still-overflowing 64-bit mask (aliased arrivals →
early completion + NULL `waiting_reqs` deref). Verification: 64-core fdotp 6+ h stuck → **3.2 s**;
16-core P2/C2 byte-identical (954,001). Latent follow-up: clint IPI registers are 32-bit —
harts ≥32 have no clint bits (unused by this suite; noted in the code).

## 7. Sidebar: the all-active retry storm (why P16/C48 and P48/C48 don't complete)

Not a deadlock and not a model artifact alone — a three-way amplifier, faithfully simulated:

1. **The kernel's retry loop** (`kernel/rlc.c`): a consumer whose `rlc_send_pkt` finds an empty
   list re-issues the pop on the very next paced iteration ("always issues the pop attempt to
   keep the idle lock traffic of the baseline"). With 48+ consumers and producers still ramping,
   ~every iteration per consumer is a failed-pop lock round-trip.
2. **The model's deeper LSU** (J1, `nb_outstanding=16`): each core keeps up to 16 poll/pops in
   flight on the same lines — ~1,000 concurrent contenders at 64 cores (the RTL LSU is also 16
   deep, so the RTL should storm the same way; there is no all-64-work RTL reference yet).
3. **The per-cell serialization** (B1 accept token + B3 RMW occupancy ~35 cy): the flag/lock
   lines' banks saturate, and every op (including producers' real pushes) pays the full queue.

Measured after ~27 h each (SIGINT dumps): P16/C48 `tile_7/ctrl_2` **rd_hit = 22.9 G** with
`tile_9/ctrl_0` a 117 M-hot RMW line; P48/C48 same line **rd_hit = 34.2 G**; producer writes on
the descriptor bank ≈ tens. Estimated completion: days of simulator time at best — the job
cannot fit any TTI budget. **The kernel's scaling ceiling is ~12–16 active cores**; beyond
that the shared-list retry storm starves real work. Recommendations: (a) for the kernel —
gate the failed-pop retry behind a list-nonempty hint (one extra register read beats a lock
round-trip), or stripe the descriptor stream; (b) for the model — none: this is faithful; an
RTL QuestaSim spot-check of P16/C48 at 16×4 would confirm the storm is real silicon behavior.


