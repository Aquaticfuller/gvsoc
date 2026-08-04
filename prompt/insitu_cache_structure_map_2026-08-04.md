# InSitu Cache — Structure Map (2026-08-04) — structural path DEPLOYED + calibrated; E3 partition live

Supersedes `insitu_cache_structure_map_2026-06-22b.md`. Legend: **✓** modeled + calibrated ·
**◐** modeled, data-correct, partially calibrated · **≈** approximated · **▣** transcribed, not
wired · **✗** not modeled · **N/A**.

> **Change since 2026-06-22b:** the structural path is no longer an opt-in experiment — it IS the
> `cachepool` target's runtime L1 (4 tiles × 4 cells, all 9 CI kernels pass, data-correct), with
> the calibration ladder landed on top: **E1** MSB rotation (+unrotation at all 6 egress points),
> **D1** PEND-line ready-cycle clamp, **D2** winfo write-ack, **B1** per-cell accept token,
> **C1** 16 B-part coalescer merge, **B3** AMO RMW occupancy (spin-lock +1.5% vs RTL),
> **F1** flush FSM (class-selective since E3.1), **A1** VLSU delayed commit + RTL issue geometry
> (ISS side), **E4** full DRAM PMA through the cache (bypass retired). **E3** runtime
> partitioning (l1d_part/l1d_addr/xbar_offset) is live end-to-end (peripheral CSRs → broadcast →
> xbar/core setters), and **E3.5** added the mixed-partition calib gate — which caught and fixed
> a real int32-truncation bug in the xbar's `private_start_addr` read.

---

## Unified hierarchy (badge = GVSoC model status)

```
CLUSTER (cachepool target: 1 group × 4 tiles × 4 cores = 16 cores)
│
├─ GROUP composite (insitu_cache_group.py)                [✓ deployed — 4 tiles + remote xbars]
│  ├─ per-port-class REMOTE xbars ×5                       [◐ routing ✓; B2 arbitration = simple]
│  ├─ partition-config broadcast (cfg_bcast, E3.2)         [✓ 1-slave→N-master fan-out]
│  └─ L2 fan-in → wide_axi → mem (latency=50, width=64B)   [≈ fixed-latency; DRAMSys channelized
│                                                          L2 exists (CACHEPOOL_DRAMSYS=1), uncalibrated]
│
├─ Peripheral (spatz cluster_registers.cpp)                [✓]
│  ├─ cp_l1d[30] CSR file (E3.0: was [16] — overflow fix)  [✓]
│  ├─ flush insn routing + COMMIT fan-out + FLUSH_STATUS   [✓ F1/E3.1]
│  └─ partition CSRs L1D_PRIVATE/ADDR/XBAR_OFFSET + commit [✓ E3.2/E3.3 latch-before-issue]
│
└─ TILE ×4 (insitu_cache_tile.py structural_tile)          [✓ deployed]
   ├─ ★ 5 per-port-class xbars (InsituCacheXbar/route.hpp) [✓ shared-L1 any-core→any-bank by addr]
   │     • MSB rotation E1 (per-mode N: shared bank_bits+tile_bits,
   │       private bank_bits) + core-side unrotation        [✓ capacity gate 2048/2048]
   │     • runtime partition setters (config port, E3.1)    [✓ num_private/private_start/dyn_offset]
   │     • private_start read 64-bit (E3.5 int32 fix)       [✓ mixed gate]
   │     • remote slots (cross-tile)                        [◐ routing ✓]
   │     • per-cycle arbitration fidelity (B2)              [≈ simple priority]
   │
   └─ cache CELL ×4 (per core):
      ├─ par_coalescer 4 VLSU lanes (cell_coalescer)        [✓ C1 16B-part merge, slip-corrected,
      │                                                      duplicate-port-class fix (c05b9450)]
      │     watchdog (C2)                                    [✗]
      ├─ AMO/LR-SC shim (lane 4)                            [✓ B3 RMW chained occupancy:
      │                                                      spin-lock 69,409 = RTL +1.5%]
      ├─ SPM remap / flush-by-range FSM                     [▣ headers; flush is whole-class only]
      └─ cache CORE (insitu_cache_core)                     [✓ sync-slave closed-loop deployed]
         ├─ decode/encode (RTL XOR hash, hash-way-only)     [✓ — E3.5 gate: multi-residue banks
         │                                                    collapse to ≤2 effective ways/set,
         │                                                    matching RTL decoder semantics]
         ├─ D1 PEND ready-cycle clamp + serve-w/o-install    [✓ gate 67,73,9,73,10]
         ├─ D2 winfo write-ack window (depth 4, ~2cy drain)  [✓ gate 8×4]
         ├─ B1 per-cell accept token                         [✓]
         ├─ refill-occupancy serialization (1 outstanding)   [✓ cold_stream 0.0143]
         ├─ MSHR                                             [≈ no cap (D3)]
         ├─ pseudo-dual bank + WR-conflict                   [≈]
         ├─ flush F1: class-selective (private/shared/all/   [✓ E3.1 — insn 0/1/2/3]
         │   invalidate-no-writeback), dirty writebacks real │
         └─ forwarding buffer                                [▣ header only]

ISS side (Spatz, not cache): A1 VLSU delayed-commit + 4B/lane × 32 outstanding (RTL geometry) [✓]
J1 scalar-LSU scoreboard (stall-on-use)                                                   [✗ — explains
   fft EOC residual + load-store locality gap + linked-list drain]
```

## Validation status (all INLINE_SYNC=1 calib gates byte-exact 2026-08-04)

| Gate | Value |
|---|---|
| warm_hit / cold_miss isolated | 67/10, 67 (RTL refs 10/67 @ ctrl boundary) |
| cold_stream throughput | 0.0143 (miss serialization ✓) |
| pend_follower (D1/D2) | 67,73,9,73,10 |
| coal_merge (C1) | 67×4, 10×4, 8×4, data_err=0 |
| capacity_2sweep_2048 (rotation) | 2048/2048 sweep-2 hits |
| **partition fold m=1..4 (E3.5)** | **2048-line: 0/0/1024/2048 · 4096-line: 0/0/2048/4096** (hash-way collapse, RTL-faithful) |
| 16-core CI kernels | 9/9 retval=0; fdotp_M32768 56,484 (offset=12 honored) |

## Remaining gaps (priority order)

1. **J1** scalar LSU scoreboard — fft EOC residual, load-store locality gap (+81%),
   linked-list drain storm.
2. **E3.6** — new rebase-tree load-store kernel bring-up (the one that actually calls
   l1d_part/l1d_addr) + RTL reference; runtime-CSR partition path validated only at the
   elaboration level so far (E3.5) + default-CSR kernel level.
3. **E2-follow-on (staged)** — wire the newer-layout block (0x98/0xa0/0x88/0x90) so
   l1d_xbar_config on that block takes effect (deliberately moves in-target cycles; needs
   flush modeling on that block first).
4. **B2/B4/C2/D3** — xbar arbitration fidelity, resp/retr FIFO bounds, coalescer watchdog,
   MSHR cap (all ≈/✗ above; second-order).
5. **P3** — DRAMSys L2 timing ground truth (channelized build exists, uncalibrated) +
   RTL re-verification of the QuestaSim references on `05e4671a` (current refs are `2710920`).
6. **S2** — icache geometry (config-only).
