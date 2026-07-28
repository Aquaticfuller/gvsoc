# GVSoC CachePool SoC — Peripheral + Boot Scope (2026-06-22)

**Question:** what does GVSoC need so the **unmodified** `snrt` CachePool benchmark binaries
(`software/build/CachePoolTests/test-cachepool-*`) boot, print, and exit — instead of hanging at boot on
`--target=spatz`?

**Headline:** the gap is **not the cache** (the structural InSitu cache + 4-tile group are built and run
closed-loop, vfadd 15/15). It is the **SoC address map + the bootrom/bootdata boot handshake + a tiny
UART**. GVSoC *already* has the load-bearing mechanisms — HTIF print+exit (`htif.cpp`), a blocking HW
barrier and EOC (`spatz/cluster_registers.cpp`), CLINT→IRQ, the ISS cores, and the structural group — but
they sit at the **wrong base/offsets** (spatz cluster@`0x00100000`, peripheral@`0x00120000`) while the
snrt binaries hardwire **TCDM@`0xBFFFF800`, peripheral@`0xC0000000`, UART@`0xC0010000`**. The very first
crt0 MMIO — the cluster-barrier load at **`0xC0000010`** — lands unmapped, so all cores stall forever.

Source of truth (verified, file:line): `software/snRuntime/src/{start.S, platforms/*/start_snitch.S,
team.c, start.c, l1cache.c, printf.c}`, `hardware/{src/cachepool_cluster.sv, cachepool_peripheral/*,
tb/tb_cachepool.sv, bootrom/*}`, `cachepool_pkg.sv`; GVSoC `pulp/{spatz.py, chips/snitch/snitch.py,
snitch/snitch_cluster/snitch_cluster.py}`, `core/models/cpu/iss/src/htif.cpp`,
`pulp/.../spatz/cluster_registers.cpp`.

---

## 1. Boot trace (reset → main), and every HW dependency before `main`

All cores reset to **`BootAddr = 0x1000`** (a per-tile **bootrom**, NOT the ELF entry). The RTL bootrom:
`csrr a0, mhartid`; `la a1, BOOTDATA`; `csrw mie, 0xF`; **`wfi`** (park); on wakeup reads the entry from
**`CLUSTER_BOOT_CONTROL = 0xC0000020`** (which the host wrote) and `jr` → the ELF `_start` with
**`a0=mhartid`, `a1=&BOOTDATA`**.

`_start` (`start.S`) then derives *everything* from `a1`→BOOTDATA (no extra HW probing): GP/SP/TLS,
`_snrt_init_core_info`/`_snrt_init_team` (reads `core_count`, `hartid_base`, `tcdm_start=0xBFFFF800`,
`tcdm_size=0x800`, `tile_count`), bss clear (core 0), FP-reg clear (gated on `misa` D/F), `csrw mtvec`,
then the **pre-main `_snrt_cluster_barrier`** — a **blocking load of `0xC0000010`** that returns only when
all `core_count` cores have arrived — then `main`, a second barrier, `_snrt_exit`.

**The only CSRs read are `mhartid` (id) and `misa` (FP gate); `mtvec`/`mie` are written.** Everything else
is memory/MMIO. The complete set that **must exist or the boot hangs**:

| Need | Address / CSR | Why |
|---|---|---|
| Bootrom + BOOTDATA | `0x1000` (+ embedded blob) | sets `a0/a1`, parks on `wfi`, jumps to entry — **ElfLoader cannot seed `a0/a1`** |
| Code/data (DRAM) | `0x80000000..0xA0000000` | ELF `.text/.init/.data/.dram`; `.htif` (`tohost`) ~`0x80002f80`; global barrier ~`0x90000000` |
| SPM/TCDM RAM | `0xBFFFF800..0xC0000000` (2 KiB) | stack, root-team struct, TLS — must be RW and **adjacent** to the peripheral |
| **HW barrier** | **`0xC0000010`** | blocking load, releases when all `core_count` cores arrive — **first crt0 MMIO; today's hang** |
| Boot-control | `0xC0000020` | host writes ELF entry; bootrom reads it |
| HTIF | `tohost`/`fromhost` in `.htif` | host polls `tohost` (already done by `htif.cpp`) |

*(Reviewer correction: `putc_buffer`/`_edram` is in DRAM (`0x80003560`), not the SPM; the SPM holds
stack/team/TLS only.)*

## 2. Print + exit path (both already supported by GVSoC mechanisms)

- **Print = UART, not HTIF.** snrt `_putchar` (`printf.c:8-13`) does a single-byte store to the
  linker-absolute `fake_uart = 0xC0010000` (`common.ld:16` = RTL `UartAddr`). Need a ~30-line **write-only
  byte sink @`0xC0010000`** that buffers and flushes a line to stdout on `\n` (mirrors `axi_uart.sv`).
- **Exit = HTIF `tohost` (primary).** `_snrt_exit` writes `(code<<1)|1` to `tohost` **first**, *then*
  `l1d_flush` + EOC. GVSoC's `htif.cpp` poller quits on `tohost & 1` with `retval = cmd>>1 = code`, so the
  **HTIF write terminates with the correct retval before EOC is even reached** — exit works with the
  existing HTIF, no EOC required for termination. (EOC@`0xC0000024` is a secondary/RTL path; if modeled,
  decode `retval=bits[3:1]` — the existing spatz `0x68` hook hardcodes `quit(0)`, so the decode must be
  *added*, not just rebased.) `_snrt_exit`'s `l1d_flush` does **not** poll `FLUSH_STATUS` (no hang there);
  the `+0x3c`-reads-0 stub only matters for kernels that call `l1d_init`/`l1d_spm_config` in `main`.

## 3. What GVSoC already has (reused unchanged behind the new target)

HTIF `sys_write`+`tohost`-quit (`htif.cpp`), cores `htif=True` with `tohost/fromhost` auto-resolved from
the ELF, the **blocking N-core barrier** (`cluster_registers.cpp:225-264`), CLINT set/clear→IRQ, the ISS
(rv32imfdcav), and the **structural InSitu cache + 4-tile group** (`use_cachepool_group`, vfadd 15/15).
These move under the new SoC unchanged; the barrier/EOC just need **CachePool offsets**.

## 4. Build scope

### MINIMAL — boot+print+exit ONE benchmark, **4-core / 1-tile** (matches BOOTDATA `core_count=4,
tile_count=1`; use the single structural tile, *not* the group — the group asserts nb_core=16). **~2-4 days.**

1. **`pulp/cachepool.py`** — new Target + Board/Soc (clone of the snitch Soc; do NOT edit `spatz.py`).
   Re-bases the cluster: DRAM@`0x80000000`, **SPM RAM@`0xBFFFF800` (2 KiB)**, **peripheral@`0xC0000000`**,
   **UART@`0xC0010000`**, **bootrom@`0x1000`**. Reuses `SnitchCluster` (use_structural_insitu_cache) with
   `nb_core=4`. *(~1 day; needs a CachePool `ClusterArch` or address overrides — the spatz `ClusterArch`
   hardwires TCDM@cluster.base and peripheral@cluster.base+0x20000.)*
2. **`cachepool_uart.{cpp,py}`** — write-only byte sink @`0xC0010000` → stdout. *(~0.5 day.)*
3. **CachePool peripheral model @`0xC0000000`** — the CachePool regmap (NOT just a rebase; the spatz
   regmap layout differs). Load-bearing: **`+0x10` HW_BARRIER** (blocking N-core, reuse the barrier FSM),
   **`+0x20` BOOT_CONTROL** (entry latch), **`+0x24` EOC** (quit, add `retval=bits[3:1]`), **`+0x3c`
   FLUSH_STATUS reads 0**, `+0x38` INSN_COMMIT ack; the rest (`+0x08/0c` CLINT, `+0x14/18/1c` status,
   `+0x28..4c` L1D-config) benign RW / RO-0 scratch. *(~1-1.5 days — rebuild the regmap, reuse the barrier
   + quit logic.)*
4. **Bootrom + BOOTDATA** — preload the RTL `hardware/bootrom/bootrom.bin` (136 B) at `0x1000` with a
   BOOTDATA blob (`core_count=4, hartid_base=0, tcdm_start=0xBFFFF800, tcdm_size=0x800, global_mem
   0x80000000..0xA0000000, tile_count=1`). **Critical: GVSoC `ElfLoader` cannot seed `a0/a1`** — the
   bootrom-replay (or a tiny boot-shim that sets `regs[10]=mhartid`, `regs[11]=&BOOTDATA` at reset) is
   *mandatory*. *(~0.5-1 day.)*
5. **Boot wiring** — `ElfLoader` loads the ELF into DRAM, writes the ELF entry to `0xC0000020`, then wakes
   the `wfi`-parked cores. *(~0.5 day.)*

Verify: `gvsoc --target=cachepool --binary test-cachepool-cache-line-rw-smoke run` → printf line(s) on
stdout + clean HTIF exit `retval=0`.

### FULL — all 8 kernels + cycle-accurate, **16-core / 4-tile group**. **~1-2 weeks on top of MINIMAL.**

All 8 share the *same* crt0/boot — once one boots, all boot. The deltas:
- **16-core BOOTDATA** (`core_count=16, tile_count=4`) — make it a generator param. If `core_count`≠actual
  cores, the SW barrier never gathers all cores → silent hang. Use `use_cachepool_group=True`.
- **CL_CLINT inter-core IRQ** (`+0x08/0c`→per-hart MSI) — required by the lock/list kernels (spin-lock,
  mcs-lock, multi_producer…); the pure-compute kernels (fdotp/gemv/fmatmul/fft) need only MINIMAL.
- **L1D-config regs wired into the group** (`+0x28..0x4c`: flush/SPM/xbar-offset) — today stubs; needed by
  cache-coverage tests and for flush/partition fidelity.
- **Tile-granular barrier** + **DDR4/L2 channel** + **per-kernel cycle calibration** (+ the open
  refill-latency calibration gap) for cycle-exact `[EOC]` matching vs QuestaSim.

## 5. Recommendation + open questions

**New target (`pulp/cachepool.py`), not extending `spatz.py`** — the address map, the bootdata/`a0/a1`
contract, entry-indirection through `0xC0000020`, and the EOC offset all differ; branching `spatz.py`
risks regressing the validated path (vfadd 15/15). Reuse `SnitchCluster` + the cache/group + HTIF +
barrier behind it.

**Open questions to resolve at build start (cheap, but boot-gating):**
1. **`wfi` wake:** does an `i_MEIP`/`external_irq` pulse release an iss core parked in `wfi` with
   `mie=0xF`? The spatz loader pulses `i_MEIP`; CLINT feeds `i_IRQ` (barrier_irq=19). Confirm the wake
   reaches the parked bootrom — else sequence fetch-enable *after* writing the entry.
2. **`a0/a1` seeding:** confirm the RTL `bootrom.bin` works as-is at `0x1000` in gvsoc, or add a reset
   boot-shim that writes `a0/a1` (analogous to GPR pokes in `syscalls.cpp`).
3. **MINIMAL core count:** bring up **4-core/1-tile** first (BOOTDATA `core_count=4`, single structural
   tile) before the 16-core group — avoids the `use_cachepool_group` nb_core=16 assert and a bootdata
   mismatch hang.
4. Confirm `bootrom.bin`'s embedded BOOTDATA values (disassemble) match `bootdata.cc`.

**Bottom line:** a ~2-4 day MINIMAL effort gets the unmodified CachePool binaries booting/printing/exiting
on gvsoc (cache reused); ~1-2 weeks more gets all 8 + the 16-core group + cycle calibration. The hard,
novel piece is the **bootrom/`a0/a1`/wfi-wake handshake**; the rest is address re-mapping + a small UART +
an offset-rebased peripheral over machinery GVSoC already has.
