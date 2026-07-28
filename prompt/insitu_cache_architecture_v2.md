# CachePool InSitu Cache -- RTL Microarchitecture & Architecture Reference (2026-06-15)

> Authoritative microarchitecture + architecture reference for the CachePool InSitu L1 data cache RTL, written for the team building the cycle-approximate GVSoC model. Every claim is sourced to the research maps; file:line citations are preserved inline in backticks. Where the maps disagree or could not pin something down, this is flagged explicitly (search for **UNCERTAIN** / **DISAGREEMENT**). The RTL reference tree is read-only at `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase/`; the GVSoC model lives at `core/models/cache/insitu/`.
>
> **Reading order for the model author:** §0 (delta table) → §1 (hierarchy) → §3 (per-core ctrl, the integration point) → §4–§5 (the cache datapath) → §8 (coalescers) → §10 (consolidated numbers).

---

## 0. At-a-glance delta vs the GVSoC model's assumptions

This table is the single most important section to keep current (per the CLAUDE.md update procedure). It contrasts the RTL reality against what the current GVSoC model (`core/models/cache/insitu/`, the `gvsoc-model-side` map) assumes. "Model assumes" reflects `insitu_cache_config.py` factory defaults + `make_cachepool_512_config()`.

| RTL feature | Reality (RTL) | What the GVSoC model assumes |
|---|---|---|
| **Per-core controller topology** | ONE wide cache (`insitu_cache_top`/`_core`) per core, fronted by an N→1 `par_coalescer` + a 2:1 scalar bypass xbar + a ReqRsp burst refill FSM (`cachepool_cache_ctrl`) | OLD v1 topology: N independent narrow controllers + hashed N→M crossbar + N write-through coalescers + L2 fan-in. `make_cachepool_512_config` builds `num_controllers=4` (`insitu_cache_config.py:426`). **Phase-B refactor pending.** |
| **L1 sharing** | FULLY SHARED across the tile (and across tiles): one controller per core but every core's lane-j port reaches all 4 tile banks via per-lane `tcdm_cache_interco` xbars + remote ports + inter-tile group xbar | NO sharing topology at all — models per-tile-LOCAL hashed N→M only. No remote ports, no inter-tile xbar, no shared-bank routing. **ABSENT.** |
| **Cache geometry (per ctrl)** | 4-way, 512b line, `NumCacheEntry` per-ctrl varies by config (see §1 discrepancy), `BankFactor=2` | 64B line (NOTE: model uses 64B, RTL uses 512b=64B line — consistent), 4 ways, 128 sets production / 256 calib (`insitu_cache_config.py`) |
| **Way selection** | Hash-way XOR-fold `tag_low ^ set_low` (forced on when fwd-buffer or fold enabled), OR full-assoc LRU (`first-way-LRU0` default, `min-LRU` under `USE_ORIGINAL_LRU`) | Knuth-style hash `(tag*2654435761 ^ set*0x9E3779B1)%ways` — NOT the RTL polynomial (documented approximation), or full LRU |
| **MSHR** | In-situ: the pending line's data payload IS the MSHR (subarray list). No separate array/CAM. Matching by re-decode of (set,way) | Per-set side-deque `MshrEntry` (save/restore), drain-on-refill. Approximates merge but not the line-resident packing |
| **Coalescer** | `par_coalescer_equal_window` (ExtFactor=1 default): CSHR FSM, per-port depth-4 FIFOs, hitmap/ofsts, wide 512b last-writer-wins merge, `rsp_spliter` fan-out, watchdog | Latency-window approximation only (`enable_input_coalesce`, calib-only). No CSHR/FIFO/hitmap/wide-merge structure; misses not coalesced |
| **Scalar bypass** | Structural 2:1 `reqrsp_xbar` (PipeReg=0) merging Snitch scalar (word pad/extract) with coalesced Spatz traffic | Latency knob only (`scalar_bypass_port`/`scalar_hit_latency_cycles`); no structural xbar. Production leaves it `-1` (scalar treated as VLSU) |
| **Refill** | 4-beat (`BurstLength=512/128=4`) LSB/MSB burst assembly FSM (Idle→Partial→Refill), single-outstanding-read gate | `set_duration(beats)` for downstream bandwidth only; no beat iteration. Single-outstanding via `defer_refills`+`refill_drain_cycles` |
| **Eviction/writeback** | 4 SEPARATE single (non-burst) writes, serialized (Read→Write FSM); `write_strb_is_zero` drop | Fire-and-forget single-slot evic FIFO, optional install-pipe slot under `defer_refills` |
| **Forwarding buffer** | Real 1-entry write-back register cache FSM (read-suppress, write-absorb, lazy WB, part-bitmap, RAW fwd, inflight-merge); multi-entry variant exists but unused | Single `fwd_buffer_line_` tracker (latency + skip set-busy). No FSM, no dirty/WB, no part-validity. Flag largely informational |
| **Pseudo-dual banking** | `pseudo_dual_port_tcdm_wrapper`: 1R+1W over N single-port SRAMs; WR_CONFLICT = 1-cycle read-retry penalty | Collapsed into per-set `set_busy_until_` cyclestamp + `bank_accept_cycles` |
| **Flush / cache_sync** | 7-state set-walk FSM, 4-mode `cache_sync_insn`, dirty writeback, `CheckPendDrainCycles=20` interlock, upstream gating | Drop-all `flush_all()` invalidate only. `enable_flush` field read but NEVER referenced in logic. No bank-walk, no opcodes, no interlock |
| **SPM partition** | `partitionable_flushable` wrapper: arithmetic tag/set divide/modulo remap, runtime `bank_depth_for_SPM` (but cachepool uses NON-partitionable wrapper + `cache_part_base=0`) | Capacity-shrink set-fold approximation (`enable_spm`/`bank_depth_for_spm`); not the division-remap |
| **AMO/LR-SC** | `spatz_cache_amo` shim on scalar lane only: 4-state RMW FSM + reservation table | ABSENT on both sides (consistency note, not a gap) — no AMO datapath in model |
| **7-state stall FSM** | Explicit `cache_fsm_status_t` (REQ_PROC + 6 stall states) | No explicit states; backpressure via `IO_REQ_DENIED` on FIFO-level/commit-busy checks |
| **Write-through merger** | Exists (`write_through_merger`) but DEAD in default config (`WriteThroughMode=0`) | Coalescer FSM modeled but DORMANT (`write_through_mode=False`); read_snoop port unbound |
| **`seq_coalescer` / `non_coalescer`** | Self-contained alternate styles, NOT instantiated in active CachePool path | Not represented |

**Calibration targets the model must hit** (config 512, BurstLength=4): warm read-hit **10 cyc isolated / 7 cyc streaming**; cold read-miss **MemLatency + 17 cyc**; miss throughput **serialized ≈ 1/(MemLatency+17)**; single-port hit ceiling **≈ 0.86–0.88 acc/cyc**.

---

## 0.1 Verified resolutions (post-synthesis adversarial fact-check, 2026-06-15)

The deep-read maps left several items flagged **UNCERTAIN / DISAGREEMENT** (§1.5, §2.5, §6, §11). A subsequent adversarial re-read of the RTL **resolved** them as below — these supersede the hedged inline text wherever they conflict:

1. **`WordWidth = 32`** for the active config (= `DataWidth` = `SpatzDataWidth` = `DATA_WIDTH`, `config.mk:39`). The `64` at `cachepool_cache_ctrl.sv:28` is a **dead module default**, overridden at instantiation to `DataWidth` (`cachepool_tile.sv:944`). ⇒ **16 words/line** (512/32), coalescer `UpstreamDataWidth=32`, and the §6 bank counts computed assuming 32 are the correct ones (≈128 data banks + 8 meta banks/ctrl in config-512). Treat every "WordWidth=64" / §1.5 disagreement below as resolved to **32**.
2. **`L1BankFactor = 2` is hardcoded** (`cachepool_pkg.sv:114`, a `localparam`), independent of the `l1d_bank_factor` make knob (which all flavors set to 1). `BankFactor=2` is correct regardless of make config.
3. **Config-512 geometry (resolved):** `L1NumEntryPerCtrl = 1024` (= 256 KiB tile × 8192 / 512-bit line / 4 ctrls), **256 entries/way**, **128 sets** (after ÷`BankFactor`=2) = **64 KiB/controller**. (The "512 vs 1024 `NumCacheEntry`" split in §1.5 is config-dependent; 1024 is the active config-512 value.)
4. **Refill burst is a *line-width* effect at a fixed 128-bit refill, and is committed-vs-working-tree sensitive** — the single most consequential nuance:
   - `Burst_Enable = (L1LineWidth > RefillDataWidth)` (`cachepool_pkg.sv:146`); `refill_data_width` defaults to **128** in `config.mk`.
   - **Committed** config-512 (`config/cachepool_512.mk` at HEAD) has NO `refill_data_width` override ⇒ 512 > 128 ⇒ **BurstLength=4**. The 4-beat refill FSM (`cachepool_cache_ctrl.sv:645-893`) + single-outstanding-read gate is the **ACTIVE/shipping** config the model calibrates to.
   - The working tree has a **local, uncommitted** edit adding `refill_data_width ?= 512` to `cachepool_512.mk` ⇒ 512 = 512 ⇒ Burst=1. Treat Burst=1 as an **experiment, not** the shipping config.
   - config-128: line=128, refill=128 ⇒ Burst=0 (no burst). So the burst difference between flavors is the **line width** (512 vs 128) at a fixed 128-bit refill, not a refill-width difference.
5. **`dynamic_offset` effective reset = 14, but via the FF not the CSR.** The `XBAR_OFFSET` CSR *field* `resval = 0` (`cachepool_peripheral_reg_pkg`/`reg.hjson:259`, 5-bit, 0–31); the peripheral FF `xbar_offset_q` resets to **`5'd14`** (`cachepool_peripheral.sv:87`) and drives `dynamic_offset_o` until a software *commit* copies the CSR field into it.
6. **`tcdm_id_remapper` is UNUSED in the CachePool path** — instantiated only in the unrelated `spatz_mempool_cc.sv` dep, not in `cachepool_{tile,group,cluster,cc}`. The §2.5 "likely refill/icache" speculation is withdrawn.
7. **Citation fix:** `pseudo_dual_port_tcdm_wrapper` (6-state WR_CONFLICT FSM, module at `insitu_cache_tcdm_wrapper.sv:1983`, states `:2051-2055`) and `insitu_cache_bank_access_controller` (FSM at `:2275`) are **modules inside `insitu_cache_tcdm_wrapper.sv`**, not separate files; `utilities/pseudo_dual_port_bank.sv` is a standalone reference variant.
8. **`cache_sync_insn` has 4 modes, not 3.** The port comment (`insitu_cache_tcdm_wrapper.sv:150-152`) documents only modes 0/1/2, but the FSM implements a 4th (`2'b11` = all-tag-init, `:799/906`).

**Verification verdict:** the note was rated **high accuracy** — every major architectural claim (line states, the 7-state core FSM, one-cache-per-core `NumL1CacheCtrl=NumCores`, the per-lane fully-shared `tcdm_cache_interco`, the `par_coalescer_equal_window` CSHR + hitmap + last-writer-wins merge, the 7-state flush FSM + `CheckPendDrainCycles=20`, the *non*-partitionable wrapper actually used by cachepool, the pseudo-dual WR_CONFLICT penalty, the bypass `reqrsp_xbar` PipeReg=0) was confirmed against source. The eight items above are the only corrections.

---

## 1. System hierarchy

**Group → Tile → CC (core complex), with a fully-shared L1.** (Maps `tile-cc`, `group-cluster-interco-amo-periph`.)

### 1.1 Counts (active config `cachepool_128.mk` + `config.mk` defaults)

- `NumCores = 16`, `NumTiles = 4`, `NumCoresTile = 4` (`cachepool_pkg.sv:29-30,55`).
- `NrTCDMPortsPerCore = 5` = `N_FU` (4 Spatz VLSU lanes; `spatz_pkg::N_FU = max(N_IPU=4, N_FPU=4) = 4`) + 1 Snitch/scalar port (`cachepool_pkg.sv:64`; `cachepool_cc.sv:117-118` `TCDMPorts = NumMemPortsPerSpatz+1`).
- `NumL1CacheCtrl = NumCores = 16` — **one cache controller per core** (`cachepool_pkg.sv:121`); `NumL1CtrlTile = NumL1CacheCtrl/NumTiles = 4` per tile (`cachepool_pkg.sv:122`).
- `NumRemotePortCore = 1` (`config.mk:32`), `NumRemotePortTile = NumRemotePortCore*NrTCDMPortsPerCore = 5` (`cachepool_pkg.sv:58,67`).
- `NumL2Channel = 4`, `ClusterWideOutAxiPorts = 4` (`cachepool_pkg.sv:33,229`); `NumClusterMst = 1 + NumL1CtrlTile = 5` masters/tile (`cachepool_pkg.sv:170`).

### 1.2 The CC (`cachepool_cc.sv`)

One Spatz compute complex: a scalar Snitch integer core + a Spatz vector unit sharing an accelerator issue bus (`cachepool_cc.sv:178-239,301-338`). It exports the 5 TCDM ports:

- **Ports 0..3 (Spatz VLSU lanes):** driven directly as raw `spatz_mem_req` channels, each backed by a FALL_THROUGH response FIFO of depth `NumSpatzOutstandingLoads = 32` (`cachepool_cc.sv:347-363`). The FIFO absorbs out-of-order responses (banks/MSHRs return out of program order).
- **Port 4 (scalar):** built from Snitch's reqrsp data port + Spatz's FP-LSU port merged through a 2→4 `reqrsp_xbar` (`i_scalar_xbar`, `cachepool_cc.sv:709-737`, PipeReg=0) that address-decodes into 4 slaves: MainMem(→cache), TotStack(→cache, with per-core stack offset rewrite `cc:751-756`), SpmStack(→dedicated per-core SPM SRAM, NOT cache, `cc:790-872`), Periph(→AXI bypass). MainMem+TotStack are `reqrsp_mux`-merged (`cc:770-788`) and `reqrsp_to_tcdm`-converted (`cc:884-900`, BufDepth=4) onto CC port 4.

So **all 5 ports reach the cache** via the tile; the scalar's SPM-stack and peripheral traffic is split off *inside* the CC before the TCDM boundary.

### 1.3 The Tile (`cachepool_tile.sv`) — the fully-shared L1 substrate

- The 4×5 = 20 core TCDM ports are **de-interleaved by lane index j**: `cache_req[j][cb] = unmerge_req[cb*5+j]` (`cachepool_tile.sv:541-551`). There are 5 independent cache crossbars, **one per lane index j** (`gen_cache_xbar`, `tile:604-652`).
- Each xbar-j is a `tcdm_cache_interco` with `NumCores=4` (the 4 cores' lane-j port) + `NumRemotePort=1` remote-in as inputs, and `NumCache=NumL1CtrlTile=4` local banks + 1 remote-out as outputs. **This is the heart of the sharing**: all 4 cores' lane-j ports contend for all 4 local controllers through a `reqrsp_xbar` (`tcdm_cache_interco.sv:166-194`). There is **no private 1:1 core→bank binding**.
- An `spatz_cache_amo` shim is placed on lane **j==4 only** (the scalar port, `tile:658-659`); lanes 0..3 (Spatz) bypass AMO.
- Per-(cb,j) request spill registers (Bypass=0, +1 cycle) + fall-through response registers (Bypass=1, 0 cycle) decouple xbar↔controller (`tile:682-776`).
- 4× `cachepool_cache_ctrl` (`gen_l1_cache_ctrl`, `tile:938-1012`), each 4-way.

### 1.4 Per-core cache mapping

Each lane-j port of each core can land on **any** of the 4 controllers (bank index from address bits, §2). Combined with the inter-tile remote routing, the L1 is fully shared and software-repartitionable (private/shared) — see §2.

### 1.5 Geometry **DISAGREEMENT** between maps — flagged

The maps give **different per-controller geometries** and the model author must resolve which config to target:

- **`tile-cc` / `group-cluster-interco-amo-periph` maps (config `cachepool_128.mk`, the "128" silicon config):** `L1LineWidth = 128b`, `NumWordPerLine = 4` (32b words), `L1NumSet = 2048` sets/way, `L1AssoPerCtrl = 4`, `L1NumEntryPerCtrl = 16384`, `NumDataBankPerCtrl = 32`, `NumTagBankPerCtrl = 8`, `L1TagDataWidth = 52`, `RefillDataWidth = 128` ⇒ `Burst_Enable = 0` (line==refill width, no burst) (`cachepool_pkg.sv:106-146`, `cachepool_tile.sv:1113-1134`). Per-ctrl ≈ 128 KiB; tile ≈ 512 KiB; 16-core ≈ 2 MiB.
- **`datapath-core` / `percore-ctrl-axi` / `calib-tb-refs` maps (config `cachepool_512`, the calibration config):** `CacheLineWidth = 512b`, `WordWidth = 64b` (some maps; calib TB says **32b**), `SetAssociativity = 4`, `NumCacheEntry = 512` (cachepool_cache_ctrl default) or `1024` (calib, = 64 KiB/ctrl), `BankFactor=2`, `RefillDataWidth = 128` ⇒ `BurstLength = 512/128 = 4`.

**This is a real, load-bearing discrepancy.** The two configs differ in line width (128b vs 512b) and therefore in `Burst_Enable` (the 128 config does no refill burst; the 512 config bursts 4 beats and has the single-outstanding-refill serialization gate). **The GVSoC model is calibrated against the 512 config (BurstLength=4)** — that is the shipping/calibration target per the calib maps and CLAUDE.md. The `cachepool_128.mk` numbers describe the silicon-oriented "128" build. Do not silently merge them. (See §11.)

Also note **`WordWidth` itself disagrees:** `datapath-core`/`percore-ctrl-axi` say `WordWidth=64`; the `tcdm-wrapper` map's `cache_top` default and the calib TB say `32`. The cachepool integration point (`cachepool_cache_ctrl.sv:28`) is cited as **`WordWidth=64`**, and the calib TB is cited as **`WordWidth=32` (NOT 64)** (`calib-tb-refs`, `tb:59`). **UNCERTAIN** — resolve by re-reading `cachepool_cache_ctrl.sv` and `cachepool_pkg.sv` for the active target before encoding a final value. (See §11.)

---

## 2. The shared-L1 substrate

(Map `group-cluster-interco-amo-periph`, `tcdm-wrapper-banking-spm-flush`, `tile-cc`.)

### 2.1 `tcdm_cache_interco` — address mapping / interleaving

Per lane-j, a `(NumCores+NumRemotePort=5) × (NumCache+NumRemotePort=5)` crossbar wrapping a `reqrsp_xbar` (PipeReg=0, combinational) (`tcdm_cache_interco.sv:166-194`).

Address layout above the cacheline offset: **`[Tag | TileID | BankSel | Index | CLoffset]`**.
- **Bank index** = `addr[dynamic_offset_q +: log2(NumCache=4)]` (`interco:229`), i.e. 2 BankSel bits.
- **TileID** = `addr[(dynamic_offset+CacheBankBits) +: TileIDWidth=2]` (`interco:230-231`).
- `dynamic_offset_q` is a **runtime-programmable CSR** (`xbar_offset`, peripheral reset = 14; the tile FF resets to 0 then loads from CSR) registered with +1 cycle (`tile:555-557`, `peripheral:71-87`). Changing it re-stripes cacheline→bank granularity at runtime.

### 2.2 Register-programmable partitioning (private vs shared)

`num_private_cache_i` (CSR `l1d_private[2:0]`, registered `interco:139-152` with +1 cycle) repartitions the 4 controllers into private vs shared sets. Modes (`interco:12-23,233-265`): `0`=all-shared, `1`=1priv/3shr, `N/2`=half-half, `N-1`=3priv/1shr, `N`=all-private. Non-power-of-2 partitions use **modulo folding** (uneven utilization): `private_bank = addr_bank % num_private`; `shared_bank = num_private + (addr_bank % num_shared)` (`interco:250-265`).

A separate `private_start_addr_q` (CSR `l1d_addr`, reset `0xA000_0000`) classifies each request as private/shared **by address**: `is_private = addr >= private_start_addr` (`interco:158-160`).

### 2.3 Inter-tile remote crossbar

For a **shared** bank, if `addr_tile != tile_id_i` the request routes to the remote-out output port `NumCache + (addr_tile % NumRemotePort)` (`interco:239-263`) — so **all traffic to a given remote tile funnels through ONE pipeline** (preserves write-before-read ordering across barriers). Remote bandwidth to one tile is thus capped at 1 req/cycle/port-class.

At the GROUP level (`cachepool_group.sv:399-432`): `NrTCDMPortsPerCore=5` separate `reqrsp_xbar` instances, one per port-class p, each `(NumTiles*NumRemotePortCore = 4) × (4)` with **PipeReg=1 & RspReg=1** (one extra request + one extra response pipeline cycle per remote hop). Request select: `remote_out_sel = dst_tile*NumRemotePortCore + (src_tile % NumRemotePortCore)`; response select mirrors via `user.tile_id*NumRemotePortCore + (t % NumRemotePortCore)` so request and response use the SAME xbar master port — a correctness invariant when `S%N != T%N` (`group:275-295`). The group only exists when `NumTiles>1`; single-tile ties remote ports off.

### 2.4 Output-side address rotation (+ inverse on refill)

After arbitration the xbar **rotates the routing bits (BankSel, +TileID for shared) up to the address MSB** so each controller sees a dense tag/index space (saves tag SRAM) (`interco:358-405`). `bits_to_rotate = CacheBankBits(=2)` for private banks, `CacheBankBits+TileBits(=4)` for shared. On a miss, the tile applies the **exact inverse rotation** per controller before issuing the refill to the NoC (`tile:1014-1110`, keyed off the same `num_private_cache` + `dynamic_offset_q`; `refill_rot_sel`).

### 2.5 ID remap (`tcdm_id_remapper`)

A NumIn→1 merge with a reorder buffer of depth `RobDepth`. `rr_arb_tree` (LockIn) picks one input, allocates a free ROB id via `lzc` over `~valid`, rewrites `mst_req.user.req_id`, records (orig req_id, source port). On response it `stream_demux`es by `id_q[resp.req_id]` back to the originator and restores the original id (`tcdm_id_remapper.sv:74-194`). Stalls (`no_free_id`) when the ROB is full; `NumIn==1` is pure pass-through. **UNCERTAIN:** the maps did not see where this is instantiated in the active config nor the active `NumIn`/`RobDepth` (likely the refill-merge or icache path). (See §11.)

### 2.6 AMO ordering

`spatz_cache_amo` (the LR/SC + RMW shim) is on the **scalar lane (j==4) only**; Spatz vector lanes never carry AMO (`tile:658-723`). Details in §3.5/§9. The shared-pipeline routing (§2.3) is what preserves write-before-read ordering across tiles around barriers.

### 2.7 `reqrsp_xbar` primitive

Two independent `stream_xbar` instances (request NumInp→NumOut, response NumOut→NumInp), full crossbar, per-output `rr_arb_tree` round-robin (LockIn when not external-prio). `PipeReg=1` adds a spill register on each input request + a 1-deep rr shift_reg; `RspReg` selects spill vs fall_through on the response (`reqrsp_xbar.sv:96-246`). Used three ways: the per-port cache xbar inside `tcdm_cache_interco` (PipeReg=0), the group remote xbar (PipeReg=1/RspReg=1), and the cluster L2 fan-in xbar (PipeReg=1, `ExtRspPrio=Burst_Enable` for burst response affinity, `cachepool_cluster.sv:664-692`).

---

## 3. Per-core cache controller (`cachepool_cache_ctrl`)

The integration point. **One instance per core** (`NumL1CacheCtrl = NumCores`). (Map `percore-ctrl-axi`.)

### 3.1 Assembly (in order)

1. **Parallel coalescer** (`par_coalescer_top`) merging the Spatz VLSU lanes into one wide cache-line request (`cachepool_cache_ctrl.sv:345-386`). Inputs = ports `[NumPorts-2:0]` = the 4 Spatz lanes; `NumPorts-1` (port 4) is the Snitch scalar bypass.
2. **2:1 bypass crossbar** (`reqrsp_xbar` NumInp=2/NumOut=1, **PipeReg=0** = combinational, no added cycle) merging coalesced Spatz traffic + Snitch scalar bypass (`cachepool_cache_ctrl.sv:454-482`).
3. **In-situ cache wrapper** (`insitu_cache_tcdm_wrapper`, the **plain** non-partitionable variant, `cachepool_cache_ctrl.sv:496-565`) — tag+data banks, hit/miss, LRU/hash, MSHR, dirty, flush/sync.
4. **Refill/eviction conversion layer** to a generic ReqRsp burst port (`refill_req_o`/`refill_rsp_i` + `refill_burst_o{is_burst,burst_len}`). **The AXI conversion is done OUTSIDE this controller**, at the group/tile level (cachepool variant); the older `flamingo` variant converts to AXI directly via `cache_to_axi`.

### 3.2 Parameter defaults instantiated here (override the wrapper defaults)

`WriteThroughMode=0` (write-BACK) (`ctrl:507`); `UseForwardingBuffer=1` (`ctrl:505`); `DataPartSplit=1` (unfolded) (`ctrl:44`); `BankFactor=2` (`ctrl:50`); `SetAssociativity=4` (`ctrl:42`); `NumCacheEntry=512` (`ctrl:38`); `CacheLineWidth=512` (`ctrl:40`); `WordWidth=64` (`ctrl:28`, **but see §1.5 disagreement**); `AddrHashLength=0` (`ctrl:512`); `cache_part_base_i=0` (`ctrl:520`); `RefillDataWidth=128` ⇒ `BurstLength=4` (`ctrl:56,70`); `LogDebug=1`, `LogLifeCycle=0` (`ctrl:510-511`).

> **NOTE on the param defaults vs the active build:** the `param default` for `UseHashWaySelect` here is `1'b0` (`ctrl:46`), but CachePool drives it **true** for the canonical hash-way config (the cluster default `cachepool_cluster.sv:114` is 1). The wrapper has `$fatal` guards requiring `UseHashWaySelect=1` whenever the forwarding buffer or fold (`PartSplit>1`) is enabled (`tcdm_wrapper.sv:272-276`). So in the production build hash-way IS active. **The local param defaults in this file are NOT the active values — read the tile/cluster instantiation for the real overrides** (this is exactly why CLAUDE.md says "parameter defaults here matter more than the cache_top defaults").

> **DISAGREEMENT on `DataPartSplit`:** `percore-ctrl-axi` says `DataPartSplit=1` (unfolded) is the cachepool ctrl default. But `tile-cc` and `calib-tb-refs` say the active tile/calib build sets `UseFoldedDataBanks=1` & `UseHashWaySelect=1` ⇒ `UseSkewedFolded=1`, `PartSplit=4` (folded, `tile:792-804`, `tb:74-79`). So the **controller param default is 1 (unfolded), but the active tile/calib instantiation drives PartSplit=4 (folded)**. The model's `make_cachepool_512_config` treats the production cache as folded (DataPartSplit=4) and the conventional cache as unfolded. (See §11.)

### 3.3 Refill-to-ReqRsp (burst) — the downstream FSMs

The cachepool variant does NOT emit AXI; it emits a ReqRsp pair + burst descriptor and runs two local FSMs (the `BurstLength != 1` path):

- **`refill_req_fsm {Read, Write}`** (`ctrl:601-606,673-786`): **Read** — if `cache_req_valid && !refill_read_outstanding_q`: on a write, emit beat0, latch the remainder, go **Write** (`write_cnt=1`); on a read, issue a burst read (`burst_len = BurstLength-1 = 3`), set `refill_read_outstanding_q`, stay Read. **Write** — emit one beat per accept; when `write_cnt==BurstLength-1` and accepted, raise `cache_req_ready`, clear, back to Read; else shift data/strb/addr and `write_cnt++`.
- **`refill_rsp_fsm {Idle, Partial, Refill}`** (`ctrl:592-599,800-893`): **Idle** — on first read beat, store top 128b, `cnt=1`, ack, → Partial. **Partial** — each beat shifts the line + inserts the new top 128b, `cnt++`; at `cnt==BurstLength-1` → Refill. **Refill** — drive full-line `cache_resp_valid`; on `cache_resp_ready` clear `refill_read_outstanding_q`; if the next read beat is already valid, skip Idle → Partial (**fast path, saves 1 cycle**), else → Idle.

`BurstLength==1` is a pure combinational passthrough path (`ctrl:618-644`), with **NO** single-outstanding gate (misses pipeline) — this is the experimental `refill_data_width=512` regime (§11).

### 3.4 Eviction / writeback

Writes (dirty-line writebacks + write-through beats) **do NOT burst**. The Read→Write FSM serializes them into `BurstLength=4` single-beat writes; `cache_req_ready` is raised only on the LAST accepted beat, so the cache stalls until the whole line drains (`ctrl:695-786`). `write_strb_is_zero` drops all-zero-strobe beats without issuing them (counter still advances) (`ctrl:705-706,752-754`).

### 3.5 AMO

**No dedicated AMO datapath in `cachepool_cache_ctrl` itself.** AMOs ride as ordinary write (RMW) requests via the standard `core_req_write_i` + wstrb path; there is no AMO opcode field handled in the controller shell. Atomicity is resolved upstream by the tile's `spatz_cache_amo` shim (§9) on the scalar lane, not here (`percore-ctrl-axi`: no amo tokens; `tile-cc`/`group...` confirm the shim location). **UNCERTAIN** whether any AMO semantics are resolved inside the wrapper. (See §11.)

### 3.6 `cache_sync` delivery

`cache_sync_valid/ready/insn[1:0]` are passed straight from the controller ports into the wrapper (`ctrl:100-107,517-519`). The 2-bit insn selects `{00 flush+invalidate, 01 flush-only, 10 invalidate-only, 11 all-tag-init}` (`wrapper:150-153`). It is a blocking handshake independent of the request stream.

### 3.7 Single-outstanding-read miss throttle

`refill_read_outstanding_q` is set when a read-miss req is accepted and cleared only when the assembled line is accepted by the cache (Refill state, `cache_resp_ready`) (`ctrl:579,684,728-729,867-869`). While set, the Read state will not issue a new read. **This serializes miss handling to one in-flight line refill** — miss throughput is `~1/(MemLatency + fixed overhead)`, NOT divided by an accept depth. This is the #1 behaviour the model must replicate for BurstLength>1.

### 3.8 The `flamingo` variant (alternate, older)

`flamingo_spatz_cache_ctrl`: ALL `NumPorts` go through the coalescer (no Snitch bypass, no 2:1 xbar). It uses `insitu_cache_tcdm_wrapper_partitionable_flushable` (SPM+flush capable, `bank_depth_for_SPM_i` passed through), and converts the cache's downstream port DIRECTLY to AXI via `cache_to_axi`, fronted by a `pseudo_dual_port_fifo` DEPTH=512 carrying `cache_info_t` (way/depth/for_write_pend) so AXI responses can be re-associated (`flamingo_spatz_cache_ctrl.sv:256-419`). Not the active CachePool path.

### 3.9 `cache_to_axi` shim (shared)

Reads→AR, Writes→AW+W via three DEPTH=2 (FALL_THROUGH=0) `fifo_v3` FIFOs; R and B responses arbitrated back via a 2-input `stream_arbiter` (`cache_to_axi.sv:85-182`). `cache_req_ready = write ? (~aw_full & ~w_full) : ~ar_full` (a write needs BOTH AW and W slots). Assumes AXI data width == `CacheLineWidth` (512b), i.e. one beat per line, no AXI bursting at this layer (the cachepool variant bursts in its own FSM to a 128b refill port instead). DEPTH=2 FALL_THROUGH=0 ⇒ +1 cycle latency; ≤2 outstanding AR or AW/W buffered.

---

## 4. The cache datapath (`insitu_cache_core` / `insitu_cache_top`)

(Map `datapath-core`. `insitu_cache_core.sv` is ~3006 lines.) The "core" is the single shared cache datapath behind the coalescer/bypass inside one controller. It is **non-blocking, set-associative**, built around a 2-stage read-then-process pipeline + a single-task FSM, with an in-line MSHR stored inside the cache line itself.

### 4.1 Pipeline stages (cycle-by-cycle)

Fundamentally **2 stages of latency** from request/refill to a bank-meta write or response push, gated by SRAM read latency:

- **STAGE A — Pre-Reader (comb + 1 reg):** a 2:1 arbiter (`i_pre_reader_arbiter`, priority **refill > request** via `stream_arbiter` ordering) selects a buffered upstream request (`req_buf_q`) or a downstream refill response. The selected task's set-index (depth) + way-mask drive the bank READ port combinationally. On the bank handshake the task is latched into `preread_task_q` (`core:560`). **→ 1 cycle for a request to reach the SRAM read port.**
- **STAGE B — Decode + FSM (comb):** one cycle later `preread_task_q.valid` is high and the SRAM read data (`bank_read_cache_status/tag/data/mask/miss_meta/LRU`, all `SetAssociativity`-wide) is valid combinationally the SAME cycle. `insitu_cache_decoder` produces `dec_is_hit/_hit_pend/_hit_conflit/_all_pend/_way` and the selected way's fields. The big `always_comb` `Cache_FSM` (`core:1382`) consumes these the SAME cycle and either (hit) pushes the response into `resp_fifo` + writes back meta/data via the encoder (`bank_write_req_o`), or (miss) generates a pending line + pushes miss/evic FIFOs.

So a **READ HIT**: cycle0 accept upstream req into `req_buf`; cycle1 issue SRAM read; cycle2 decode + push `resp_fifo`; then `resp_fifo → arbiter → upstream_resp`. End-to-end warm read-hit (incl. coalescer + wrapper + SPM-read around the core) is calibrated to **10 cyc isolated / 7 cyc streaming**.

### 4.2 Line states (`insitu_cache_pkg.sv:19`)

2-bit enum: `INVALID=0 (00)`, `VALID=1 (01)`, `READ_PEND=2 (10)`, `WRITE_PEND=3 (11)`. The exact encoding is **load-bearing**: the decoder treats bit[1] as "is-pending" and bit[0] as "read-vs-write within pending", and asserts the encoding (`decoder:136`). A line's payload union holds EITHER cache data (status 0/1/3) OR an MSHR list of pending sub-requests (status `READ_PEND`).

### 4.3 Lookup / hit-miss decision

See §5 for the decoder detail. Summary: full-assoc LRU (`UseHashWaySelect=0`) reads all ways; hash-way (`UseHashWaySelect=1`, the production config) reads one XOR-folded way.

### 4.4 In-situ MSHR / pending tracking

**There is NO separate MSHR array.** When a READ misses, the victim line becomes `READ_PEND` and its data payload is reinterpreted as `mshr_subarrays` (`MaxNumSubarray` slots of `InfoStoreWidth` each). The line's low mask bits act as a subarray counter. Subsequent READs hitting that `READ_PEND` line (`hit_pend`, read) **MERGE**: append their info into `subarrays[cnt]`, bump count (`core:1726-1761`). When count hits `NumSubarray` the line is full → `MSHR_FULL_STALL`. On refill, the stored list is drained — one response beat per entry, via the Retrieve FIFO (`core:2320-2355`). WRITE misses set `WRITE_PEND` and merge subsequent writes by OR-ing wmask + masked data into the line (no separate write buffer). A full-masked write miss skips the fetch and installs the line VALID directly (`miss_is_full_masked_write`, `core:1850-1852`).

`NumSubarray = min(MaxNumSubarray, 2^SubarrayCounterWidth - 2)`; `SubarrayCntWidth = clog2(NumSubarray+2)`; `MaxNumSubarray = CacheLineWidth/InfoStoreWidth` (−1 when it divides evenly). **UNCERTAIN concrete value** — `InfoStoreWidth` is byte-rounded from the cluster's actual `info_t` width, not resolvable from the core files alone (README estimates ≈8 sub-entries per PEND line). (See §11.)

### 4.5 Outstanding / non-blocking limits

Because the MSHR is the line itself, distinct outstanding misses are bounded by the number of distinct (set,way) lines simultaneously in `READ_PEND`/`WRITE_PEND` — up to `NumCacheEntry` in principle, but practically limited by:
- the **Miss FIFO** (`MissFifoDepth`, default 4 at cache_top) of in-flight refill *requests*;
- the **downstream single-outstanding-read serialization** (one line refill at a time, §3.7).

Multiple reads to the SAME line coalesce into that line's subarray list (the headline non-blocking feature). The default build (no `ENABLE_MULTI_READ_PEND`) allows ONE pending line per (set,way); `ENABLE_MULTI_READ_PEND` adds linking of multiple `READ_PEND` ways for the same line + a pseudo-refill FIFO (`PesudoRefillFifoDepth=8`). **UNCERTAIN** whether `ENABLE_MULTI_READ_PEND` is defined in the cachepool build (default off). (See §11.)

### 4.6 The FSM (`cache_fsm_status_t`, 7 states, `core:422`)

| State | Meaning / entry | Resolution |
|---|---|---|
| **REQ_PROC** | Steady state, 1 task/cycle | — |
| **RESP_STALL** | `resp_fifo` full (holds one resp in `fsm_resp_stall_q`) | drain to freed FIFO → REQ_PROC |
| **MISS_STALL** | `miss_fifo` full (holds miss+optional evic) | drain → REQ_PROC (may chain to EVIC_STALL) |
| **EVIC_STALL** | `evic_fifo` full, OR PartSplit>1 read-modify eviction needing a full-line bank read | drain / complete read → REQ_PROC |
| **ALL_PEND_STALL** | every way pending (no victim) | any refill to the set frees a way → REQ_PROC |
| **MSHR_FULL_STALL** | read hit a `READ_PEND` line whose subarray list is full | matching refill arrives, append one `extra_subarray`, drain → REQ_PROC |
| **WR_CONFLICT_STALL** | opposite-type access to a pending line (WRITE on READ_PEND or READ on WRITE_PEND) | matching refill → RAW (push read resp) / WAR (merge write) → REQ_PROC |

`preread_allowed=0` in every stall state (stops accepting new tasks). **Refill processing runs in PARALLEL** with the request FSM in the same `always_comb` (`proc_refill`, `core:2320`), because a refill task and a request task never co-occupy `preread_task_q` (the pre-reader arbiter serializes them). The refill path re-decodes the line (depth/way from miss-FIFO info echoed in `downstream_resp_refill_info_i`), drains subarrays into the Retrieve FIFO, merges dirty bytes, sets the line VALID, and resolves the matching stall state back to REQ_PROC.

### 4.7 Refill issue & response

On miss the FSM pushes `{addr, info={for_write_pend, way, depth}}` into the Miss FIFO. `insitu_cache_top` arbitrates miss/evic/write-through onto ONE downstream req port (**3:1 `stream_arbiter`, miss highest priority**, `top:591`). The downstream response (refill) carries back the same `downstream_info_t` so the core re-finds the pending (depth,way) without a CAM (`core:939-941,970-973`). Refill data passes through a `spill_register` (1-cycle elastic, `core:821`) into the pre-reader. The drained per-subarray responses (Retrieve FIFO) and the direct read-hit responses (Resp FIFO) merge via a **2:1 `stream_arbiter`, resp_fifo prioritized** (`core:1147`).

### 4.8 Eviction (datapath side)

A dirty VALID victim's data + dirty-mask go into the Evic FIFO (single-cycle for `PartSplit==1`). For `PartSplit>1` (folded), the dirty line isn't available from the partial read, so EVIC_STALL does an **extra full-line bank read** (`evict_full_read_req`, +1 handshake + +1 capture cycle ≈ +2 cycles) before pushing the writeback; the new line install is deferred via `deferred_bank_write_q` until the eviction read completes (`core:2224-2268,1892-1936`).

### 4.9 Key RAW hazard hold

Meta/data banks have read latency, so a request to a line being written THIS cycle must not issue (RAW between `bank_write` and the next `bank_read`). `upstream_req_issue_hazard_now`/`req_buf_issue_hazard_now` compare the in-flight write's (depth,tag,way) against the incoming/buffered request and **HOLD the request one cycle** in `req_buf_q` (`req_buf_hold_q`) unless the forwarding buffer fully covers the line (`bank_write_buf_safe_bypass = buf_hit & buf_full_cov`). `PrereadReqHazardCycles=0` in this build (the forwarding buffer handles it, `core:564`).

### 4.10 `insitu_cache_top` wrapper

Address hashing on upstream addr (`AddrHashLength=0` ⇒ no-op in production), write-through vs write-back front end, instantiates the core + `SetAssociativity` pseudo-dual-port banks, arbitrates the 3 downstream request sources, merges the 2 response sources. Top defaults: `SetAssociativity=16` (cachepool overrides to 4), `NumPseudoDualBanks=8` (`UsePseudoDualBanks=1`), all `*FifoDepth=4`, `WriteThroughMode=0`. **NOTE:** `bank_write_data_buf_hit_i`/`bank_write_data_buf_full_cov_i` are tied to 0 in `insitu_cache_top` (`top:516-517`); the real forwarding buffer is wired by the cachepool ctrl / wrapper (§5, §6), not in `insitu_cache_top`.

---

## 5. Hit/miss decode + LRU/hash victim + forwarding buffer

(Map `decoder-encoder-fwdbuf`.) These are the combinational "brain" of one way-array plus the optional 1-cycle forwarding fast path.

### 5.1 Decoder (`insitu_cache_decoder.sv`) — pure combinational, no flops

Receives the full read-out of all `SetAssociativity` ways and produces hit classification + chosen way. Address split `{tag, depth(=set index), byte-offset}` (`decoder:110`).

Two way-select modes:
- **(a) Full-associative LRU (`UseHashWaySelect=0`):** a for-loop over all ways tag+status compares (`decoder:195-239`); on a clean miss picks the victim by either `USE_ORIGINAL_LRU` min-LRU scan over VALID/INVALID ways (`decoder:267-275`) OR the default **"first way whose LRU credit == 0"** (`decoder:277-282`).
- **(b) Hash-way (`UseHashWaySelect=1`, the production config when fwd-buffer/fold on):** a single way chosen by XOR-fold `hash_way = addr[ofst+depth +: log2(Assoc)] XOR addr[ofst +: log2(Assoc)]` (`decoder:112-118`); tag-compared in one shot; hit/hit_pend/hit_conflict/all_pend formed as flat SOPs over `_tag_hit`, `_status_s1` (is-pending), `_status_s0` (`decoder:173-176`) — **deliberately flattened from a priority cascade to shorten the meta-SRAM-read→hit critical path**. Behaviourally identical to the full-assoc semantics. The victim is always the hashed way (1 way read/lookup, no LRU, more conflict misses). The LRU-victim loop is **explicitly skipped** in hash mode (the `!UseHashWaySelect` guard at `decoder:258/262`) — a documented bug-fix (without it the LRU loop overwrote the hash way and dropped dirty writebacks).

**Hit classification semantics:**
- READ to VALID+tag = **hit**;
- READ to READ_PEND+tag = **hit_pend** (hit-under-miss); WRITE to WRITE_PEND+tag = **hit_pend**;
- READ to WRITE_PEND+tag = **hit_conflict**; WRITE to READ_PEND+tag = **hit_conflict** (opposite-type);
- every way pending = **all_pend** (structural stall, no VALID/INVALID line to allocate).

On a refill task the way is taken verbatim from the refill payload (`decoder:296`). An optional `ENABLE_MULTI_READ_PEND` mode adds hit-under-miss MSHR-append bookkeeping via per-line `miss_meta {is_full, is_prime, link_enable, link_ptr}` linking multiple read-pend requests to one in-flight line (`decoder:73-77,178-192`).

### 5.2 Encoder (`insitu_cache_encoder.sv`) — combinational + 1 flop

Passes through all ways' read values and overwrites exactly one selected way (`enc_way_i`) with new status/dirty/miss_meta/mask/tag/data, applying an optional byte-granular masked-merge of write data into the existing line (`encoder:187-211`).

It maintains `pendline_cnt` (the only flop, `encoder:106`) tracking how many lines are currently in a PEND state; `has_pend_line_o = (count != 0)` **gates the cache from accepting flush/sync while refills are outstanding**. `clear_pend_cnt_i` (from flush/invalidate) resets it in one shot (`encoder:225-228`).

`LRU_array_update` transition table (`encoder:112-158`):
- VALID/INVALID → PEND: promote touched way to MRU (`LRU = Assoc-1`), decrement all younger VALID/INVALID ways, `pendline_cnt++`;
- PEND → VALID/INVALID: set the way's credit (0 if invalidated, else `max_lru_credit`), `pendline_cnt--`;
- PEND → PEND: no-op;
- other transitions promote to `max_lru_credit-1`.
- `max_lru_credit` = live count of non-pending ways (`encoder:160-167`).

### 5.3 Forwarding buffer (`sram_forwarding_buffer.sv`, single-entry, the active CachePool variant)

A **1-row write-back register cache** in front of one single-port SRAM, enabled by `UseForwardingBuffer` (default 1 in cachepool). It holds one SRAM row (`buf_addr/data/valid/dirty` + a `PartSplit`-wide parts bitmap).

- **Read hit:** asserts `rd_hit_comb_o` combinationally so the access controller **suppresses the downstream SRAM read this cycle** (frees the SRAM port), then returns data 1 cycle later via a registered `buf_rd_data_q` **to MATCH SRAM read timing**. So a buffer read-hit is the same 1-cycle latency as an SRAM read — **the win is SRAM-port THROUGHPUT, not per-access latency** (`buffer:104,229-265,660-711`).
- **Write hit:** asserts `wr_hit_comb_o` and **absorbs** the write into the register, suppressing the SRAM write and marking dirty; the dirty row is written back lazily on eviction (`buffer:267-395`). Three write-hit paths: IDLE, PEND_DISJOINT, FULL_LINE.
- **`rd_inflight_hit` fast path** (`buffer:259-265`): if a read targets the SAME address as the SRAM read issued LAST cycle (data on `sram_rdata_i` THIS cycle), serve from `sram_rdata_i` and suppress a redundant SRAM read. Single-entry only.
- **RAW forwarding** (`EnableRawForwarding`, default **1** for both data and meta buffers in cachepool `tcdm_wrapper:86-87`): a read + absorbing-write to the same line same-cycle returns the **POST-write merged value** (`buffer:422-433,671`). Adds a byte-mask-wide comb mux before the response register (mild critical-path cost, no extra cycle).
- **`EnableInflightWriteMerge`** (default **1** for the data buffer, `tcdm_wrapper:1680`): lets `rd_inflight_hit` fire even with a concurrent same-addr write, overlaying `wr_data` into the response (`buffer:689-697`).
- **Part-awareness** (`PartSplit>1`): tracks which line-parts are cached as a bitmap; reports a read hit only when ALL requested parts are present; SRAM populates are ADDITIVE (OR new parts in, preserving cached/dirty parts). Populate paths A (ACCUMULATE), B (ACCUMULATE-PEND-DISJOINT), D (ACCUMULATE-CONCURRENT-MERGE, gated by `wr_target_valid_i`), C (REPLACE) (`buffer:487-599`). `wr_full_coverage_o` tells the cache core whether absorption leaves the WHOLE line buffered (safe to bypass the bank-write/same-line-read hazard).
- Inline SVAs (C1/C3/C5) enforce the buffer↔core contract.

### 5.4 Forwarding buffer multi (`sram_forwarding_buffer_multi.sv`) — NOT instantiated by default

N-entry generalization (`NumEntries` default 2), but `FwdBufEntries=1` in cachepool (`tcdm_wrapper:2295`) so the single-entry variant is active. Adds `buf_has_free_clean_o` / `buf_near_full_o` SpecWb-gating outputs, allocation priority (same-addr / invalid / LRU-clean / LRU), and pseudo-LRU (true PLRU only for N=2). **Does NOT implement RAW forwarding nor the `rd_inflight_hit` fast path** — both are single-entry-only.

---

## 6. SRAM banking, folded SRAM, skew/way-grouping, bank conflicts/arbitration

(Map `tcdm-wrapper-banking-spm-flush`, `tile-cc`.)

### 6.1 Data/meta organization

`SetAssociativity` ways (cachepool 4). Each way is held in `CacheBankDepth = NumCacheEntry/SetAssociativity` rows (512/4 = 128 at the controller defaults). A line is `CacheLineWidth=512b` split into `WordWidth` words. Banking:
- `NumDataBankPerWay = NumPseudoDualBanks * (CacheLineWidth/WordWidth)`;
- `NumMetaBankPerWay = NumPseudoDualBanks`.
- `NumPseudoDualBanks` is driven by `BankFactor` (cachepool `BankFactor=2`).

**Per-config bank counts (DISAGREEMENT, §1.5):** the `tcdm-wrapper` map (using `WordWidth=32`, the cache_top default) computes 4 ways × (2*16=32) data banks/way = 128 data banks + 8 meta banks. The `tile-cc` map (config 128) cites `NumDataBankPerCtrl=32`, `NumTagBankPerCtrl=8`. The calib TB (config 512) cites `NumDataBankPerCtrl=128`, `NumTagBankPerCtrl=8`. These differ because of the `WordWidth`/line-width config split. **Resolve per active target.**

`tcdm_bank_addr_t = log2(CacheBankDepth) - log2(NumPseudoDualBanks)` bits = the per-pseudo-bank row address; the low `log2(NumPseudoDualBanks)` bits of the set index select which pseudo-dual bank.

### 6.2 Per-way access path

For each way the wrapper instantiates: a `insitu_cache_bank_access_controller` for data (`NumWordsPerLine=16`) + one for meta (`NumWordsPerLine=1`), and a `pseudo_dual_port_tcdm_wrapper` for each. **SRAM read latency = 1 cycle** (`tc_sram` Latency=1). The access controller is a 2-state FSM (`ACCESS_THROUGH`/`ACCESS_STALL`) + a `wb_active` overlay; a dirty-buffer eviction inserts a 1-cycle writeback (`wb_active`) and, for write-needs-SRAM, an `ACCESS_STALL` replay cycle. As-instantiated perf knobs for DATA: `AllowReadDuringWrite=1`, `UseForwardingBuffer=1`, `FwdBufEntries=1`, `UseSpecWbIdle=1`, `UseSpecWbAddrTrans=1`, `EnableRawForwarding=1`, `EnableInflightWriteMerge=1` (`tcdm_wrapper:1667-1680`).

### 6.3 Pseudo-dual-port bank

`pseudo_dual_port_tcdm_wrapper` presents a 1R+1W interface over `NumPseudoDualBanks` single-port SRAMs by bank-interleaving on the low set bits. FSM `{IDLE, W_ONLY, R_ONLY, WR_DIFF_BANK, WR_SAME_ADDR, WR_CONFLICT}`:
- **WR_DIFF_BANK** (different pseudo-bank): R and W both proceed, free (hidden 1-cycle);
- **WR_SAME_ADDR** (same addr): write proceeds, read served from a per-word `write_line_buffer` forward, free;
- **WR_CONFLICT** (same pseudo-bank, different addr): **WRITE WINS**, `read_ready_o` deasserted ⇒ read retries next cycle = **1-cycle bank conflict penalty** (`tcdm_wrapper:2259-2264`).

Bank-select bits = low `log2(NumPseudoDualBanks)` bits. With `BankFactor=2` there are 2 pseudo-banks/way; the set-address LSB selects the bank; addresses differing in that bit never conflict.

Word-level part gating (`read_part_idx`/`read_all_parts`) lets only the addressed `PartSplit` slice of words drive the SRAM (`tcdm_wrapper:2125-2152`).

### 6.4 Folded/skewed data banks

`folded_data_bank` (alternative storage for `PartSplit>1`, requires `UseHashWaySelect=1`): all `NumWays` packed into one deeper SRAM per way-port, addressed as `folded = {way*DepthPerWay + addr}`, one `tc_sram` per way-port, Latency=1. **NOT a true multiport macro.** Elaboration `$fatal` if `UseHashWaySelect=0` (only one way active per lookup, so the fold arbiter can disambiguate).

At the **tile level** (the cross-way arbitration the wrapper map could NOT see — it's in `cachepool_tile.sv`): when `UseFoldedDataBanks=1` & `L1AssoPerCtrl>1` (the active default), `(way,part)` is skewed onto a column. A per-(column, bank_sel) arbiter gives **writes priority over reads**; a read is granted (`l1_data_bank_gnt`) only if no OTHER way writes the same column that cycle (`any_other_write_in_col`). A dropped read returns no valid data → the controller must replay/stall. Unfolded mode grants everything (`gnt=1`) (`cachepool_tile.sv:790-807,1136-1340`). This intra-controller cross-way bank conflict is what caps BurstLength=1 miss throughput at ~0.25/cyc (§10).

The data banks expose a per-bank grant (`tcdm_data_bank_gnt_i`) for bank-conflict back-pressure to the cache (`cachepool_cache_ctrl.sv:159`).

### 6.5 `dirty_rf` / `lru_rf` register files (wrapper module scope)

- `dirty_rf` is a `CacheBankDepth × SetAssociativity` flop array (true 1R/1W; read port registered to match SRAM 1-cycle latency). Write updates only the target way on proc writes (hash mode) or all ways on flush.
- `lru_rf` (only in `!UseHashWaySelect` mode) is a `CacheBankDepth × SetAssociativity` way-ptr array so LRU updates on read hits avoid a meta-SRAM write.

Separating dirty/LRU from the meta SRAM lets write-hits-on-VALID skip the meta SRAM write entirely (`meta_skip`) (`tcdm_wrapper:1558-1612`).

### 6.6 Reference / non-production bank primitives

- `pseudo_dual_port_bank.sv`: standalone 1R+1W over BANKS single-port SRAMs, same 6-state FSM, `WR_CONFLICT` read-retry. Not on the production path (the wrapper uses `pseudo_dual_port_tcdm_wrapper`).
- `dual_port_bank.sv`: behavioural golden-model true dual-port write-first SRAM (simulation reference only, not synthesizable as written).

---

## 7. SPM partition + flush/sync FSM

(Map `tcdm-wrapper-banking-spm-flush`.)

### 7.1 SPM partition (`insitu_cache_tcdm_wrapper_partitionable_flushable`)

A thin SPM shell around `insitu_cache_tcdm_wrapper`. `bank_depth_for_SPM_i` (a `tcdm_bank_addr_t` = per-pseudo-bank depth) carves the bottom of every way's row space into a software scratchpad:
- `cache_partition_set_for_SPM = NumPseudoDualBanks * bank_depth_for_SPM_i` sets reserved at the LOW end (`cache_base_for_SPM`);
- cacheable region shrinks to `cache_partition_set_for_cache = CacheBankDepth - SPM_sets`;
- SPM size = `SPM_sets * SetAssociativity * CacheLineWidth` bits, carved per-way uniformly.

**Address translation is ARITHMETIC (NOT bit-slicing)** (`partitionable_flushable.sv:200-218`):
- `upstream_tag = (addr >> byteoff) / cache_partition_set_for_cache`;
- `upstream_set = (addr >> byteoff) % cache_partition_set_for_cache + SPM_sets`;
- downstream restores `addr = tag*cache_partition_set_for_cache + (set - SPM_sets)`.

Because it's an integer divide/modulo, the effective set mapping changes whenever the partition size changes — affecting WHICH set (hence which pseudo-bank/conflict group) an address lands in.

**CRITICAL for the model:** the cachepool variant uses the **plain (NON-partitionable)** wrapper (`cachepool_cache_ctrl.sv:496`) and ties `cache_part_base_i=0`. So **per-controller SPM carve is NOT used in the active CachePool config** — CachePool does bank repartitioning via the inter-tile xbar register config (`num_private_cache`, §2) instead. The `flamingo` variant uses the partitionable wrapper. **UNCERTAIN** whether `bank_depth_for_SPM` is exercised in the GVSoC-targeted config. (See §11.)

### 7.2 Flush/sync FSM (WriteBack mode only — the generate `else`-branch)

7-state `cache_sync_ctrl` FSM (`tcdm_wrapper:281-289,750-1098`): `SYNC_CTRL_IDLE → READ_BANK → CHECK_PEND → {FLUSH | INIT} → FINISH` (`INVALID` state declared but empty). It set-walks the bank doing dirty writeback via the `write_through_merger` path and clears meta.

- **IDLE:** on `cache_sync_valid_i` latch insn, set `ptr = cache_part_base_i` (SPM base) — but `insn==11` (init-all) sets `ptr=0` — go READ_BANK.
- **READ_BANK:** issue `flush_read` at ptr; on ready → CHECK_PEND (always, both flush and init).
- **CHECK_PEND:** wait until `drain_now` = (`outstanding_refill_cnt==0` AND `core_miss/evic/write_through` idle AND `core_preread_task` empty AND `core_retr_fifo` empty AND no `proc_write`), **STABLE for `CheckPendDrainCycles = 20` consecutive cycles** (`tcdm_wrapper:563`), then assert `clear_pend_cnt` and go INIT (`insn==11`) or FLUSH.
- **FLUSH:** read `dirty_rf[ptr]`; if dirty, (PartSplit>1: read tag/mask + full line into `flush_full_*` regs over a few cycles, push writeback via `write_through_req`, on ready clear meta INVALID; PartSplit==1: single-cycle writeback + clear); else clear whole set meta=0 and `ptr++`; at `ptr==CacheBankDepth-1` → FINISH; background-reads next ptr.
- **INIT:** clear meta to 0 at ptr, `ptr++`, at `CacheBankDepth-1` → FINISH.
- **FINISH:** assert `cache_sync_ready_o`, → IDLE.

**insn encoding:** `00 = flush+invalidate`, `01 = flush only`, `10 = invalidate only`, `11 = all tag init` (walks the WHOLE bank from 0).

### 7.3 Interlocks (the timing the model must respect if it ever models flush)

- **Source of dirty truth** is `dirty_rf` (per-set, per-way flops, indexed directly by sync ptr so always fresh).
- New upstream requests are **fully blocked** (`sync_block_upstream`, `upstream_req_to_cache_valid=0`) for the entire duration the FSM is not IDLE/FINISH (`tcdm_wrapper:722-728`) — flush stalls the whole cache port.
- Refill installs are **deferred** (`sync_block_install`) during INIT/FLUSH/INVALID.
- Bank-read priority is given to flush during the writing phases: `bank_read_sel_flush = sync_block_install | ~proc_read_cache_valid`. During CHECK_PEND, proc reads are NOT blocked (would deadlock the drain) (`tcdm_wrapper:1440-1504`).
- Total clean-flush time ≈ `(CacheBankDepth - SPM_sets)` cycles + per-dirty-line writeback latency; plus the fixed 20-cycle CHECK_PEND bubble whenever any sync op is issued.

### 7.4 Tile-level + peripheral flush plumbing

See §9 — the tile flush controller decodes a `cache_insn_t` to per-controller `cache_sync_valid/insn`, and the peripheral CSR block delivers software flush/partition config. `outstanding_refill_cnt` is tracked as issued (`core_miss` handshake) minus consumed (refill resp handshake); its counter width is effectively unbounded for normal use — it is a drain gate, not a refill cap.

---

## 8. Coalescers

(Maps `par-coalescer`, `seq-coalescer-wtmerger`.) **Selection in the active CachePool path:** `cachepool_cache_ctrl` instantiates **`par_coalescer_top`** for the Spatz-VLSU read/write path (`ctrl:345`, `i_par_coalescer_for_spatz`, NumPorts-1 lanes, `ExtFactor=CoalExtFactor`). `seq_coalescer_top` is **NOT instantiated** anywhere in the active path. `write_through_merger` IS instantiated but only inside `if(WriteThroughMode)` (=0 default) so it is **dead**. `non_coalescer` is an A/B baseline, not in `par_coalescer_top`.

### 8.1 `par_coalescer_top` — policy selection

Pure parameter-driven generate: `ExtFactor>1` → `par_coalescer_extend_window`; `ExtFactor==1` (the default) → `par_coalescer_equal_window` with `SpliterSpillReg=1` (`par_coalescer_top.sv:139`). Default params: `NumPorts=4`, `UpstreamDataWidth=32`, `DownstreamDataWidth=512`, `NumWord=Down/Up=16`. `downstream_info_t = {id; hitmap[ExtPorts]; ofsts[ExtPorts]; infos[ExtPorts]; bypass_coalescer}` — carried end-to-end so the response can be split back per-port.

> **NOTE on the active `DownstreamDataWidth`:** `tile-cc`/`calib-tb-refs` say that in the folded config `EffectiveCoalFactor=1` and the coalescer's downstream width = `CoalescerDataWidth` = `CacheLineWidth` when PartSplit==1, else `CacheLineWidth/PartSplit` (`percore-ctrl-axi`). The maps did NOT all converge on the exact active `UpstreamDataWidth` (32 vs the WordWidth=64) — see §1.5/§11.

### 8.2 `par_coalescer_equal_window` (the common case) — equal window

A single Coalescing-Status-Hold-Register (CSHR) FSM (`req_coalescer_v2`) opens **one coalescing window per cycle** around ONE wide-line tag. All same-cycle valid ports whose tag == CSHR_addr are "current hits" and merge into the current downstream beat (their `upstream_ready` asserted same cycle). Ports that miss arbitrate to pick the NEXT window tag; ports matching that next tag are "next hits", also accepted (ready asserted) but folded into the NEXT beat. So the coalescer can accept current-window hits AND latch the next window's hit set in the same cycle it fires (`update_CSHR` path).

- **Coalescing key = `{write, line-tag}`** (`write_mixed_addr = {upstream_req_write, addr}`, `eq:162`, `AddrWidth = ReqAddrWidth+1`) — because the write bit is the tag MSB, **reads and writes to the same line NEVER coalesce** into one beat.
- `tag_addr = addr[AddrW-1:DownstreamDataAlign]`; per-port `addr_ofst = addr[DownstreamDataAlign-1:UpstreamDataAlign]` (narrow word 0..15 within the 512b line). `DownstreamDataAlign=6` (512b), `UpstreamDataAlign=2` (32b) ⇒ ofst = `addr[5:2]`, 4 bits.
- Per-port info/wdata/wstrb buffered in depth-4 `fifo_v3` (FALL_THROUGH=0 ⇒ 1-cycle push-to-pop). `req_fifo_full` back-pressures upstream.
- The coalesced address+hitmap+ofsts go through a **NON-bypass `spill_register`** (`eq:196-208`) → downstream_req: **+1 cycle on the request path**.
- `gen_down_req_data` builds the wide wdata/wmask: each hit port's narrow word placed at `word_index = ofsts[i]`; on writes, per-byte wstrb into wmask, and **"higher-index ports override earlier bytes on overlap" (last-writer-wins)** (`eq:269-304`).

**`req_coalescer_v2` CSHR FSM** (2-state `{IDLE, VALID}`, `v2:367-431`): `current_hit[i] = valid & tag==CSHR_addr & ~occupy_map[i] & status==VALID`. `next_CSHR_addr` chosen among miss ports by **round-robin** (`USE_ORDER_PRIOR=0` as equal_window overrides it; the v2 default is first-order priority) via `rr_arb_tree` (LockIn). `update_CSHR` fires when `(any valid) & coal_ready & ~strb_full & ofst_fifos_have_space` AND `(IDLE OR miss ports exist)`.

**Watchdog window-release:** prevents a partially-filled window from waiting forever. `watchdog_credit = number of UNoccupied ports`; when `watchdog_cnt == credit` (and downstream ready, FIFOs have space, no input), `watchdog_flag` fires the partial beat → IDLE. **Fuller window ⇒ smaller credit ⇒ flushes sooner** (`v2:184-206`).

### 8.3 Response split (`rsp_spliter_v2`)

The wide 512b response is unpacked into narrow words: `rsp_data_o[i] = unpacked[ofsts[i]]`. It can deliver to multiple ports across multiple cycles under per-port backpressure: `handshack_mask_q` records served ports; the beat holds (`downstream_ready_o=0`) until `handshack_mask_record == coal_strb_active` (all hit ports served), then asserts `downstream_ready_o` + `split_done` in one pulse. A snapshot (`split_active_q`) latches metadata if a beat starts but can't complete same cycle. Metadata travels **in-band** in `downstream_info_t` (the `coal_strb_full/empty` ports are tied off — no separate metadata FIFO at this layer). In equal_window, splitter outputs feed per-port depth-4 `fifo_v3` spill FIFOs; downstream_resp passes a `spill_register` NOT bypassed when `SpliterSpillReg=1` ⇒ **+1 cycle** before splitting (`eq:320-332`).

### 8.4 `par_coalescer_extend_window` (`ExtFactor>1`)

Widens the effective window across TIME: each physical port gets `ExtFactor` virtual sub-ports (`ExtPorts=NumPorts*ExtFactor`) into an inner `par_coalescer_equal_window`. A per-port round-robin pointer `req_port_select_q` steers each port's successive accepted requests onto rotating virtual ports so requests arriving in different cycles can co-merge. The response side round-robins (`rr_arb_tree NumIn=ExtFactor, LockIn=1, AxiVldRdy=1`) the virtual responses back to the physical port (serializes per-port responses). **Note: the active folded config forces `EffectiveCoalFactor=1`**, so equal_window is used.

### 8.5 `non_coalescer` (baseline, A/B only)

A single `rr_arb_tree` (LockIn=1) picks ONE valid port/cycle; one narrow request per downstream beat. Throughput ceiling = 1 port/cycle. No coalescing.

### 8.6 `seq_coalescer` family (alternate, NOT in active path)

Single-entry, run-of-consecutive-cycles coalescer. `seq_coalescer_top` → `seq_coalescer_req_merger` (one open line) or `seq_coalescer_multi_req_merger` (`NumMerger>1`, default 2 concurrently-open lines, demuxed by line-index-mod-NumMerger). FSM `{IDLE, READ_COAL, WRITE_COAL}`: merges consecutive same-line, **same-direction** narrow accesses into one wide request; **direction switch (read↔write) forces a flush** (reads/writes never share a burst). Watchdog `WatchDogMax=4` (recharged on every valid req, decremented on idle). A K-sub coalesced read replays as **K serialized upstream-response cycles** (the resp FSM in `seq_coalescer_top` walks subs[0..num_sub], one/cycle). Accepts at most ONE upstream req/cycle. **Not exercised by the active CachePool path** (the model does not need a seq style unless a standalone TB uses it — §11).

### 8.7 `write_through_merger` (legacy, dead in default config)

A single-entry write-coalescing FSM `{IDLE, WRITE_COAL, FLUSH}` with **byte-granular** RMW merge (vs seq's whole-word lane fill) and a **read-monitor forced flush** (`flush_push = mon_read_handshaked_i & (coal tag == read tag)`) so a read to the line being coalesced drains the pending write first (write-through ordering hazard). Only built when `WriteThroughMode=1` (=0 in the default CachePool config), so inactive. Watchdog `WatchDogMax=4`. The flush-write goes through a `WriteThroughFifoDepth=4` FIFO + spill register.

### 8.8 Scalar bypass xbar (where it lives)

The Snitch scalar bypass is NOT in the coalescer — it's the 2:1 `reqrsp_xbar` in `cachepool_cache_ctrl` (§3.1, `ctrl:419-493`). The `bypass_coalescer` field in `downstream_info_t` is always driven 0 by equal_window (`eq:277`); where it is ever set 1 (the scalar path) is outside the coalescer files (it's the ctrl-level bypass). The scalar reads back exactly one 64b word selected by `addr_offset` from the 512b line; bypass writes pad a single word into the line at `bypass_word_index` with shifted wstrb (`ctrl:292-306,446-452`).

---

## 9. The L1D / cache_sync peripheral

(Map `group-cluster-interco-amo-periph`.) `cachepool_peripheral` + `_reg_pkg` — the memory-mapped CSR block (`BlockAw=7`) that delivers software cache_sync/flush/partition config to ALL controllers.

### 9.1 Key registers (offsets from `_reg_pkg`)

| Reg | Offset | Effect |
|---|---|---|
| `CFG_L1D_SPM` / `L1D_SPM_COMMIT` | 0x28 / 0x34 | SPM size config |
| `CFG_L1D_INSN` | 0x2c (2b) | 00 flush-private, 01 flush-shared, 10 flush-all, 11 invalidate-all |
| `CFG_L1D_TILE_SEL` | 0x30 (32b) | per-tile one-hot, used only for private flush |
| `L1D_INSN_COMMIT` | 0x38 | commit the flush insn |
| `L1D_FLUSH_STATUS` | 0x3c (RO) | reads `(l1d_lock_q != 0)` (busy) |
| `L1D_PRIVATE` | 0x40 (4b) | → `num_private_cache` (reset 0 = all-shared) |
| `L1D_ADDR` | 0x44 (32b) | → `private_start_addr` (reset `0xA000_0000`) |
| `XBAR_OFFSET` / `XBAR_OFFSET_COMMIT` | 0x48 (5b) / 0x4c | → `dynamic_offset` (reset 14) |
| `CL_CLINT_SET/CLEAR`, `HW_BARRIER`, `ICACHE_PREFETCH_ENABLE`, `SPATZ_STATUS`, `CLUSTER_EOC_EXIT` | 0x8/0xc, 0x10, 0x14, 0x18, 0x24 | IPI wakeup, barrier, icache prefetch, cluster probe, EOC |

### 9.2 Delivery path

On `l1d_insn_commit`, if no tile is currently locked (`|l1d_lock_q==0`), the peripheral packs `cache_insn_t = {insn, tile_sel}` and pulses `l1d_insn_valid_o`; `tile_sel` is forced to all-ones for non-private modes (`peripheral:144-163`). It then **LOCKS** the targeted tiles (`l1d_lock_q = tile_sel`) and reports busy per-tile; each tile clears its lock on a one-cycle `l1d_insn_ready_i` pulse (`peripheral:165-178`). `FLUSH_STATUS = (l1d_lock_q != 0)`.

### 9.3 Tile-level flush controller (`cachepool_tile.sv:837-936`)

Accepts the `cache_insn_t`, decodes the insn into per-controller `ctrl_sync_valid`/`ctrl_sync_insn` (`00→flush`, `11→init`), gating private vs shared CCs by `cb` vs `num_private_cache`. Tracks completion via `cache_flush_q` bits (set on `ctrl_sync_valid`, cleared on the CC's `cache_sync_ready_o`), and pulses `l1d_insn_ready_o` when all targeted CCs finish. A second instruction is blocked while `flush_pending_q`. **During `l1d_busy` the tile gates all core req valid / rsp-qready and fully stalls remote ports** (`cachepool_tile.sv:524-597`) — no overlap of normal traffic with flush.

### 9.4 AMO peripheral path (`spatz_cache_amo`)

The AMO/atomic shim on the scalar lane (j==4) of each cache controller. 4-state FSM `Idle → DoAMO → WriteBackAMO → Wait → Idle` (`spatz_cache_amo.sv:67-70,228-279`):
- Normal / LR / SC pass straight through (1 pass).
- RMW AMO: `Idle→DoAMO` (read, wait for matching response by `core_id`+`req_id`) → `WriteBackAMO` (write `amo_result` at `addr_q`, `user.is_amo=1`) → `Wait` (until the `is_amo` write response) → Idle. **Multi-cycle serialized per AMO; holds the scalar port (`core_ready=0`) for the duration.** `is_amo` responses are filtered (not forwarded to the core).
- LR/SC reservation table (single entry `reservation_q`): LR sets `{valid,addr,core}`; SC succeeds only same-core/same-addr with reservation still valid; any foreign write/AMO to the reserved addr clears it. SC response data = `~sc_successful` (0 = success). `amo_alu` supports swap/add/and/or/xor/max/min/maxu/minu.
- **UNCERTAIN:** the reservation has commented-out liveness guards (`:166`); current behaviour lets a new LR always overwrite a prior reservation regardless of core (affects SC success rate). (See §11.)

---

## 10. Concrete latencies, outstanding caps, FIFO depths, arbitration rules

Consolidated. **All cycle numbers are config-512 / BurstLength=4 unless stated.** Where docs disagree, both values are shown with the authoritative one marked.

### 10.1 Latencies (end-to-end and internal)

| Quantity | Value | Source |
|---|---|---|
| **Warm read-hit (isolated)** | **10 cyc** (authoritative; TRACE_SPEC headline says 9 — stale) | `calib-tb-refs`; `datapath-core` |
| **Warm read-hit (streaming steady-state)** | **7 cyc** | calib |
| Read-hit core-internal | 2 cyc (cycle1 issue SRAM read, cycle2 decode+push resp_fifo) + resp_fifo→arb→upstream | `datapath-core` |
| **Cold read-miss to first word** | **MemLatency + 17 cyc** (BurstLength=4); = MemLatency+13 with BurstLength=1; TRACE_SPEC headline says +16 (use +17) | `calib-tb-refs` |
| Warm write hit | 8 cyc (incl interco; ack faster than read 10) | calib |
| Read-after-write same word (fwd buffer) | 7 cyc, MemLatency-independent, no memory access | calib |
| Coalescer warm (same-line) | 7 cyc | calib |
| SRAM read latency | 1 cycle | `tcdm-wrapper` |
| Pseudo-dual same-bank R/W conflict (WR_CONFLICT) | +1 cycle (read replays) | `tcdm-wrapper` |
| Dirty fwd-buffer eviction | +1 wb_active cycle + 1 ACCESS_STALL replay | `tcdm-wrapper` |
| PartSplit>1 read-modify eviction | +2 cycles (full-line read handshake + capture) | `datapath-core` |
| Refill data path elastic | +1 cycle (`spill_register`) | `datapath-core` |
| Coalescer request path | +1 cycle (non-bypass spill) | `par-coalescer` |
| Coalescer response path | +1 cycle (`SpliterSpillReg=1`) + 1 cycle per-port resp FIFO | `par-coalescer` |
| Per-(cb,j) tile spill: req | +1 cycle (Bypass=0); resp 0 cycle (Bypass=1) | `tile-cc` |
| `tcdm_cache_interco` | input req spill +1 (when not bypassed); comb xbar; output resp fall-through 0 | `group...` |
| Group remote xbar (per hop) | +1 req + 1 resp cycle (PipeReg=1/RspReg=1) | `group...` |
| Cluster L2 fan-in xbar | +1 req cycle (RspReg=0 ⇒ fall-through resp) | `group...` |
| `cache_to_axi` FIFOs (DEPTH=2, FALL_THROUGH=0) | +1 cycle | `percore-ctrl-axi` |
| Bypass 2:1 reqrsp_xbar (PipeReg=0) | 0 added cycles (combinational) | `percore-ctrl-axi` |
| Scalar `scalar_xbar` (PipeReg=0); `reqrsp_mux` RespDepth=4; `reqrsp_to_tcdm` BufDepth=4; SPM stack Latency=1 | as listed | `tile-cc` |
| **CheckPendDrainCycles (flush pre-bubble)** | **20** | `tcdm-wrapper` |

### 10.2 Throughput

| Quantity | Value | Source |
|---|---|---|
| Single-port hit ceiling | 0.865 acc/cyc (TRACE_SPEC headline ~0.88) | `calib-tb-refs` |
| Port-scaling 1→4 ports (hit) | 0.62 / 0.76 / 0.83 / 0.86 (SUB-linear, one shared ctrl) | calib |
| Injection-gap sweep (1-port hit, gap 0/1/3/7) | 0.865 / 0.467 / 0.243 / 0.124 acc/cyc | calib |
| **Miss throughput (BurstLength=4)** | **serialized ≈ 1/(MemLatency+17)** ≈ 0.018 acc/cyc @ L=50; NOT divided by MSHR count; halves as MemLatency doubles | `calib-tb-refs` |
| Miss throughput (BurstLength=1 experiment) | ~0.243–0.247 @ L≤50 (7–14× faster); bank-contention-bound at ~0.25 = 1 miss/4 cyc; crossover to budget-bound at L≈115; ceiling ~32/(MemLatency+13) | `calib-tb-refs` |
| Core-side accept depth | ≈ 8 outstanding requests (hides HIT latency, not MISS) | calib |
| Write throughput (1-port resident) | 0.489 acc/cyc (~56% of read), MemLatency-independent | calib |
| Coalescer warm (4 ports same line) | 3.28 acc/cyc (~4× single-port hit rate); cold 128 accesses→32 lines→32 mem reads | calib |
| Dirty-victim eviction | +~10% latency over clean cold miss; throughput unchanged (memory-bound) | calib |

### 10.3 Outstanding caps

| Cap | Value | Source |
|---|---|---|
| Single-outstanding line refill (per controller) | 1 (`refill_read_outstanding_q`), the dominant miss-throughput limiter | §3.7 |
| Per-port requester budget (Spatz) | 32 (`NumSpatzOutstandingLoads = SPATZ_MAX_TRANS`) | `tile-cc`, `calib-tb-refs` |
| Snitch scalar outstanding loads/mem | 16 (`snitch_max_trans`) | `tile-cc` |
| In-situ MSHR per pending line | ≈8 sub-entries (`MaxNumSubarray = CacheLineWidth/InfoStoreWidth`); exact value UNCERTAIN | §4.4 |
| Distinct outstanding misses | bounded by # (set,way) lines in PEND; same-line reads coalesce into one line's subarray list | §4.5 |
| Memory model (calib) MaxOutstanding | TB passes 64 (module default 8) — set high so memory isn't the limiter | `calib-tb-refs` |
| `cache_to_axi` AR/AW/W outstanding | ≤2 each | `percore-ctrl-axi` |
| flamingo info side-FIFO | 512 outstanding reads | `percore-ctrl-axi` |
| `tcdm_id_remapper` | `RobDepth` (stalls on `no_free_id`) | `group...` |

### 10.4 FIFO depths

| FIFO | Depth | Notes |
|---|---|---|
| Miss / Evic / Resp / Retrieve (cache_top) | 4 each | core defaults are 16; cachepool uses cache_top's 4 |
| WriteThrough / WResp | 4 | only when WriteThroughMode |
| Retrieve throttle | refills back-throttled when `retr_fifo_usage >= RetrFifoDepth-2` | `core:838` |
| PesudoRefillFifo | 8 | only `ENABLE_MULTI_READ_PEND` |
| Coalescer per-port req (info/wdata/wstrb) | 4 (FALL_THROUGH=0) | up to 4 outstanding/port |
| Coalescer per-port resp spill | 4 | |
| Spatz per-lane response FIFO (CC) | 32 (= NumSpatzOutstandingLoads) | |
| `cache_to_axi` AR/AW/W | 2 each | |
| Calib flow FIFOs (miss/resp/retr/evic/winfo + coalescer) | 4 default | depth-4 knee bounds sustained throughput |

### 10.5 Arbitration rules

- **Pre-reader (core):** 2:1 `stream_arbiter`, **refill > request** (`core:768`).
- **Downstream req (top):** 3:1 `stream_arbiter` {miss, evic, write_through}, **miss highest priority** (`top:591`).
- **Upstream resp (core):** 2:1 `stream_arbiter` {resp_fifo, retrieve_fifo}, **resp_fifo prioritized** (`core:1147`).
- **Pseudo-dual bank:** **write wins** over read on same-bank conflict (read retries +1 cycle).
- **Folded data bank (tile):** **write priority over read** per column; conflicting read of another way same column is degranted (`l1_data_bank_gnt`).
- **Coalescer next-window tag:** round-robin among miss ports (equal_window `USE_ORDER_PRIOR=0`).
- **`reqrsp_xbar` outputs:** per-output `rr_arb_tree` round-robin (LockIn) for request; external-prio for response when `ExtRspPrio` (burst affinity in cluster L2 xbar).
- **Remote routing:** all traffic to a given remote tile collapses onto 1 pipeline/port-class ⇒ 1 req/cycle/port-class cap.
- **Flush bank-read:** flush gets the bank-read port unconditionally during INIT/FLUSH/INVALID.
- **RAW bank hazard:** same-line request held exactly 1 cycle unless the forwarding buffer fully covers the line.

### 10.6 Geometry / refill

- `BurstLength = CacheLineWidth/RefillDataWidth = 512/128 = 4` (config 512); read miss = 1 burst req (`burst_len=3`) → 4 beats (LSB-first reassembly). Writeback = 4 separate single (non-burst) writes (`addr + 16*i`, each 1 ack).
- Config 128: `L1LineWidth = RefillDataWidth = 128` ⇒ `Burst_Enable = 0` (no refill burst).

---

## 11. Open questions / uncertainties

The following could NOT be pinned down from the maps, or the maps disagree. The model author should resolve these before encoding final values.

1. **Config split: `cachepool_128.mk` vs `cachepool_512` (line width 128b vs 512b, `Burst_Enable` 0 vs 4-beat burst).** §1.5. The two configs differ in line width, refill burst behaviour, and bank counts. The GVSoC model is calibrated against config-512 (BurstLength=4, the shipping/calibration target). Do not merge the 128-config silicon numbers into the model without deciding which target you are reproducing. (Maps `tile-cc`/`group...` describe 128; `datapath-core`/`percore-ctrl-axi`/`calib-tb-refs` describe 512.)

2. **`WordWidth` = 32 or 64?** `cachepool_cache_ctrl.sv:28` and the `percore-ctrl-axi`/`datapath-core` maps say **64**; `cache_top` default and the calib TB (`tb:59`) say **32 (NOT 64)**; the `tcdm-wrapper` map computes bank counts assuming 32. Re-read `cachepool_pkg.sv` + `cachepool_cache_ctrl.sv` for the active target. This changes words-per-line (8 vs 16), bank counts, and the coalescer `UpstreamDataWidth`.

3. **`DataPartSplit` = 1 (unfolded) or 4 (folded)?** The ctrl *param default* is 1 (`percore-ctrl-axi`), but the active tile/calib build drives `UseFoldedDataBanks=1` & `UseHashWaySelect=1` ⇒ `PartSplit=4` (`tile-cc`/`calib-tb-refs`). Confirm whether the GVSoC-targeted production cache is folded (it appears so — the model's `make_cachepool_512_config` treats production as folded with DataPartSplit=4).

4. **`NumCacheEntry` per controller:** 512 (ctrl default), 1024 (calib = 64 KiB/ctrl), or 16384 (config-128 `L1NumEntryPerCtrl`). Resolve per target (§1.5).

5. **`NumSubarray` / `MaxNumSubarray` concrete value** (in-situ MSHR merge depth): depends on `InfoStoreWidth`, which is byte-rounded from the cluster's real `info_t` width — not resolvable from the core files. Need `cachepool_cache_ctrl`/`cachepool_pkg`. README estimates ≈8.

6. **`ENABLE_MULTI_READ_PEND` / `INSITU_CACHE_CORE_USE_MSHR_PADING` compile defines:** whether they are set in the cachepool build. Default off in the source files. If on, multiple `READ_PEND` ways link per line (changes hit-under-miss capacity + miss-throughput). The maps could not see the cachepool compile defines.

7. **`UseHashWaySelect` active value:** the ctrl param default is `1'b0` but cachepool drives it true (cluster default 1, `$fatal` guards require it with fwd-buffer/fold). The model uses a Knuth hash, NOT the RTL `tag_low ^ set_low` XOR-fold — per-address way placement and exact conflict-miss pattern diverge.

8. **AMO resolution location:** no AMO datapath in `cachepool_cache_ctrl`. The shim is `spatz_cache_amo` on the tile scalar lane. Confirm whether any atomicity is resolved inside the wrapper vs entirely upstream. Also the `spatz_cache_amo` reservation has commented-out liveness guards (`:166`) — a new LR can overwrite a prior reservation regardless of core; confirm intended for SC-success-rate modelling.

9. **`tcdm_id_remapper` instantiation:** defined but the maps did not find where it's instantiated in the active config nor the active `NumIn`/`RobDepth` (likely the refill-merge or icache path).

10. **`cache_addr_hashing()` function** (set/tag hashing for non-partitioned wrapper with `AddrHashLength`): not in the read files; lives in another include. In the active cachepool path `AddrHashLength=0` (no-op), so this only matters if a non-partitioned hashed mapping is ever used.

11. **SPM in the active config:** cachepool uses the NON-partitionable wrapper (`cache_part_base=0`) yet still receives `bank_depth_for_SPM_i` as a port. The maps believe CachePool SPM repartition is done entirely via the inter-tile xbar register config (`num_private_cache`), not per-controller — verify against the xbar config registers. The model's SPM is a capacity-shrink approximation, not the RTL division-remap.

12. **`burst_req_t` struct width and `burst_len` semantics:** only `{is_burst, burst_len}` fields are referenced; the typedef is external. The code uses `burst_len = BurstLength-1`, i.e. beats-1 — confirm against the parent typedef.

13. **`refill_data_width=512` / BurstLength=1 regime** is an UNCOMMITTED experiment branch (`fix/cache-refill-throughput`), NOT the shipping config. The shipping cachepool_512 is BurstLength=4 with the single-outstanding-refill serialization. Stance B says calibrate the shipping BurstLength=4 first.

14. **`par_coalescer` active `UpstreamDataWidth`/`DownstreamDataWidth` and `ExtFactor`:** confirm at the cachepool instantiation (the coalescer module defaults are 32/512/1; the v2 primitives default to 64). `EffectiveCoalFactor=1` in folded mode per `tile-cc`.

15. **Canonical hit/miss latency doc disagreement:** TRACE_SPEC says warm-hit "9 cyc" and cold-miss "MemLatency+16"; the measured CSV runs (CHARACTERIZATION/REPORT) say **10/7** and **MemLatency+17**. Treat the measured 10/7 and +17 as authoritative; the +13 figure is the BurstLength=1 variant.

16. **Single-port `WordWidth=32` coalescer behaviour vs `WordWidth=64` controller:** the coalescer merges 64b words (controller) but the calib TB reports 32b — tied to item 2.

17. **Folded-bank cross-way arbiter exact per-cycle rule:** the tile-level `any_other_write_in_col` / `l1_data_bank_gnt` write-priority grant (the thing that caps BurstLength=1 miss throughput at ~0.25/cyc) is in `cachepool_tile.sv`; the precise per-cycle bank arbiter rule needs the data-bank arbiter source to model exactly.

18. **Reset semantics:** RTL leaves SRAM undefined and REQUIRES a software sync INIT op (insn=11) before use; the model starts all lines INVALID (clean cold cache) and models no INIT op. Functionally fine for the model, but a divergence to note.
