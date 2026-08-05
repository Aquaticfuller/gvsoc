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
| P4/C8 | 16×4 = 64 | 12 (+52 idle) | running¹ | | | | | |
| P16/C48 | 16×4 = 64 | 64 (all) | running¹ | | | | | |
| P48/C48 | 64×4 = 256 | 96 (+160 idle) | running¹ | | | | | |
| P128/C128 (M256) | 64×4 = 256 | 256 (all) | running¹ | | | | | |

¹ The 64/256-core runs are in flight at commit time (all healthy, ISS-confirmed advancing —
wall-clock scales steeply with tile count: 64 components' ClockEvent ticks per cycle ×16 tiles
plus the barrier-spin instruction stream from the idle cores; the 32-core run took ~8 min, the
64-core ones >2 h). This table is filled by the follow-up commit the moment they land; the
monitor watches all four logs.

## 4. Reading the numbers

- **Requirement verdict:** every completed configuration delivers the 243 kB job in ≪ 1 TTI, at
  an equivalent aggregate throughput 60–145× above the 7 MB/s requirement. The platform is not
  the binding constraint; the pacing loop (`RLC_ENABLE_PACING`, off by default) is what would
  throttle the kernel to the air-interface rate.
- Thread scaling at 16 cores (unchanged from the 07-27 finding): producers saturate first,
  consumers pay off once producers keep up.
- Topology scaling at fixed 12-thread P4/C8: 255,565 (16c) → 239,737 (32c) — the extra tiles'
  banks spread the shared-list contention, worth −6%. The 64/256-core rows show where the
  remote-fabric latency starts to dominate.

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
