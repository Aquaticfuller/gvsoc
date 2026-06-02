# GVSoC InSitu Cache Model — Status Report

**As of 2026-05-25**

## Overview

We have started building a cycle-approximate **GVSoC performance model of
the CachePool InSitu L1 data cache**. The model lives under
`core/models/cache/insitu/` in the GVSoC repo and is parameterised against
the canonical `cachepool_512` configuration described in the latest RTL
spec (`/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/working_dir/insitu-cache/`).
Target accuracy: under 5% cycle-count error vs. RTL for typical streaming
and random-access workloads.

This report captures what the model can do today.

## What the model is

Four Python/C++ components compose into a tile:

```
TCDM ports (per-core × per-port)
        │
        ▼
   ┌───────────────────────────────────┐
   │ InsituCacheInterco                │   hashed N-to-M crossbar
   │  (insitu_cache_interco.{cpp,py})  │   per-output RR arbitration
   └───┬─────┬─────┬─────┬─────────────┘
       │     │     │     │
    ┌──▼──┬──▼──┬──▼──┬──▼──┐
    │ C0  │ C1  │ C2  │ C3  │   4 InsituCacheControllers
    │ FSM │ FSM │ FSM │ FSM │   tag array, MSHR, hash-or-LRU victim,
    └──┬──┴──┬──┴──┬──┴──┬──┘   eviction, refill, write-through hook
       │     │     │     │
       │ WT  │ WT  │ WT  │
       │  ▼  │  ▼  │  ▼  │  ▼
       │ Coal│ Coal│ Coal│ Coal     4 InsituCacheCoalescers
       │     │     │     │          3-state FSM with watchdog
       │     │     │     │
       └─────┴─┬───┴─────┘
               │
               ▼  fan-in (refill + evict + write-through-flush)
            o_L2 master port → memory / SPM / DRAM
```

`InsituCacheTile` (`insitu_cache_tile.py`) is the composite that wraps all
four pieces and exposes one `i_INPUT(port)` per TCDM port plus a single
`o_L2` master that the caller binds to whatever memory backs the cache.

## Features achieved

### Cache controller
- Set-associative tag array, configurable ways / sets / line size
- Per-line state machine: `INVALID` / `VALID` / `READ_PEND` / `WRITE_PEND`
- MSHR-style pending-request merging (multiple readers to the same in-flight line)
- Hash-or-LRU victim selection (configurable)
- Pure write-back **or** write-through-coalesced mode (`write_through_mode` knob)
- Refill and eviction paths with configurable beat width
- FIFO-occupancy back-pressure (`miss_fifo` / `evic_fifo` / `retr_fifo`)
- Per-set bank-busy cyclestamps for realistic same-set serialisation
- Pre-allocated scratch buffers for refill / evict / write-through so the downstream memory's memcpy is safe

### Interconnect
- N-to-M hashed crossbar (`InsituCacheInterco`)
- Per-output round-robin arbitration with configurable forward latency
- Address-hash routing controlled by `dynamic_offset`

### Coalescer
- 3-state FSM (`IDLE` / `WRITE_COAL` / `FLUSH`)
- Configurable watchdog for tag-change/timeout flushes
- Read-snoop port for cache-side flush triggers
- Scratch flush-buffer so memcpy at downstream is safe

### Latest-RTL tracking (Phase A)
- Architecture doc `prompt/insitu_cache_architecture_v2.md` describing the latest RTL structure (single wide cache + N→1 coalescer + partitionable/flushable wrapper + three coalescer styles)
- 5 new config knobs: `write_through_mode`, `enable_multi_read_pend`, `enable_spm`, `bank_depth_for_spm`, `enable_flush`
- Default flipped to LRU + unfolded + pure write-back to match the latest CachePool ctrl defaults
- Hyper-SPM partitioning modelled by folding the set address into the cacheable region when `enable_spm`
- Multi-read MSHR mode: read-on-`READ_PEND` merges bypass the `retr_fifo` accounting (matches the RTL's linked-list of pending reads)
- Legacy-config factory `make_cachepool_512_legacy_config()` retained for regression against the prior (folded + hash) defaults

### Integration
- Drop-in spatz-cluster integration behind a `use_insitu_cache` flag in `ClusterArch` — default off, no regression
- Standalone testbench target `insitu_cache_tb` (one RV32 host → cache → memory) for running real rv32 binaries
- Synthetic-traffic testbench target `insitu_cache_microbench` (no CPU; driver → v1 Generator → cache → memory) for sub-second cycle-count measurements

## Testing & verification

### Build verification
- `make all TARGETS=insitu_cache_microbench` — clean
- `make all TARGETS=insitu_cache_tb` — clean
- `make all TARGETS="spatz:use_insitu_cache=True"` — clean
- `make all TARGETS=spatz` (default, cache off) — no regression

### Microbench results (sub-second total, no CPU)

Seven canonical access patterns, on `cachepool_512` defaults:

```
[CALIB_REPORT] name='warmup'          packets=16  cycles=45   c/p=2.81
[CALIB_REPORT] name='cold_stream_r4'  packets=64  cycles=171  c/p=2.67
[CALIB_REPORT] name='hit_repeat_r4'   packets=64  cycles=83   c/p=1.30
[CALIB_REPORT] name='cold_stream_r16' packets=256 cycles=675  c/p=2.64
[CALIB_REPORT] name='cold_stream_w4'  packets=64  cycles=171  c/p=2.67
[CALIB_REPORT] name='hit_repeat_w4'   packets=64  cycles=83   c/p=1.30
[CALIB_REPORT] name='stream_w_newrgn' packets=64  cycles=171  c/p=2.67
```

The numbers cross-check against the closed-form expectations in
`core/models/cache/insitu/README.md` §4:
- Hit throughput ≈ 1.3 c/p (steady-state pipelined hits with per-set bank serialisation)
- Cold streaming ≈ 2.7 c/p (4 misses × ~24 c + 60 hits × ~1.3 c)
- Writes ≈ reads on the user critical path (coalescer is asynchronous)
- Linear scaling: `cold_stream_r16` 675 ≈ 4 × `cold_stream_r4` 171 (1.3% under, from miss pipelining)

### Real-binary smoke
- `examples/spatz/test-riscvTests-vfadd` on spatz (no cache): PASS, 54,001 cycles, clean HTIF exit
- CachePool binaries on spatz+cache: model boots correctly and is actively simulating, but full kernels exceed sub-hour wall-clock on the 4-core Spatz accurate ISS — the microbench is the practical validation harness for cycle-level work

## Limitations / what's not yet done

The current GVSoC model implements the **prior** RTL topology (4 controllers
per tile + hashed interco). The **latest** RTL has restructured into a
single wide cache + N→1 coalescer + scalar bypass-xbar. The model still
validates as cycle-approximate for unit-level testing, but the full topology
refactor (Phase B) is documented and pending. Specifically not implemented:

- True single-wide-cache + N→1 par-coalescer topology
- Scalar-port bypass-xbar (asymmetric handling)
- Real flush FSM (the `enable_flush` knob is reserved API — has no runtime effect yet)
- Per-SoC controller variants (CachePool ReqRsp vs. Flamingo AXI4) with distinct refill timing
- Multi-entry forwarding buffer
- RTL↔GVSoC numerical cycle comparison via a matched calibration C corpus

## Documentation

| Topic | File |
|---|---|
| Architecture (latest RTL) | `prompt/insitu_cache_architecture_v2.md` |
| Architecture (legacy RTL, retained for FSM details) | `prompt/insitu_cache_architecture.md` |
| Model user guide (build, config, timing formulas, troubleshooting) | `core/models/cache/insitu/README.md` |
| Implementation plan (modelling philosophy, phases) | `prompt/insitu_cache_gvsoc_plan.md` |
| Procedure for tracking a new RTL revision | `CLAUDE.md` §"Tracking new RTL revisions" |
| Project status (this report) | `prompt/weekly_report_2026-05-25.md` |
