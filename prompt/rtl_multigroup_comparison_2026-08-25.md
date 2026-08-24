# CachePool multi-group RTL vs. the GVSoC v3 model — comparison + calibration round (2026-08-25)

RTL surveyed: `/usr/scratch/fenga1/zexifu/manyRVData/ManyRVData_rebase`, branch `dev/rlc-next`
@ `2f51034`. The multi-group support landed in `044e768` ("Add multi-group support for CachePool
(#27)"); the branch tip adds the RLC multi-user kernel (`fbcafa6`) and an LR/SC atomicity fix
(`81d8139`). RTL is read-only reference — nothing under that tree was modified.

Primary new sources read: `config/floonoc_cachepool_{4,16}g.yml`, `config/cachepool_fpu_16g.mk`,
`config/cachepool_4g.mk`, `config/config.mk`, `hardware/src/cachepool_pkg.sv`,
`hardware/src/cachepool_group_noc_wrapper.sv`, `hardware/tb/cachepool_noc_profiling.sv`,
`hardware/deps/floo_noc/hw/floo_router.sv`, plus the captured run data in
`noc_profiling/session_0/` and `reports/rlc_64core_baseline_2026-08-24/`.

---

## 1. What the RTL actually builds

**Two NoC levels, both `floo_router`, both 5-port, both VC=1 / InFifoDepth=2 / OutFifoDepth=2.**

| | L1 inter-group ("RG") | L2 refill |
|---|---|---|
| routing | `XYRouting` | `SourceRouting` (floogen route table) |
| instances | one router pair **per tile per NoC channel** — `NumTilesPerGroup * NumNoCPortsPerTile` parallel meshes (16 at the 16g config) | **one** req + one rsp router per group |
| mesh | `NumGroupsX × NumGroupsY` | `NumGroupsX × NumGroupsY` |
| group attach | concentration xbar → mesh | `Eject` (local) port |

**Memory channels.** `floonoc_cachepool_16g.yml`: 8 HBM endpoints, on the **West port of the
x=0 column** (hbm0-3 at routers `[0,0..3]`) and the **East port of the x=3 column** (hbm4-7 at
`[3,0..3]`). North of row 0 and South of row 3 are unused. The 4g config is the same shape with
4 channels. Channels hang off an otherwise-unused *mesh direction* of an edge router — they are
not extra mesh nodes and cost no extra router hop.

**Channel address decode** (`cachepool_pkg.sv::getDramCTRLInfo`):

```
dram_ctrl_id = addr[ConstantBits + ScrambleBits - 1 : ConstantBits]
ConstantBits = clog2(L2BankBeWidth * Interleave) = clog2(64 * 16) = 10
ScrambleBits = clog2(NumL2Channel)
```

→ the channel is address bits **[12:10]** for 8 channels: a **1024 B granule** striped
round-robin. `scrambleAddr()` afterwards permutes the bits so each channel sees a contiguous
DRAM block (which is why the floogen SAM lists contiguous 128 MB ranges) — a pure address
rewrite with no timing consequence.

**Remote ports are `n × 5`, and there are two independent `n`s** (`cachepool_pkg.sv`,
`cachepool_group_noc_wrapper.sv`):

```
NrTCDMPortsPerCore      = 5                                   // 4 Spatz VLSU + 1 Snitch/FPU scalar
NumLGPortTile           = NumLGPortCore          * 5          // intra-group  (to other tiles)
NumRemoteGroupPortTile  = NumRemoteGroupPortCore * 5          // inter-group  (via the L1 NoC)
NumNoCPortsGroup        = NumNoCPortsPerTile * NumTilesPerGroup   // 5→x concentration xbar
```

Config defaults: `config.mk` = lg 1 / rg 0 / noc-per-tile 1; `cachepool_4g.mk` = **lg 4, rg 1,
noc 4**; `cachepool_fpu_16g.mk` = **lg 2, rg 1, noc 4**. This confirms the `n × 5` rule exactly
as specified, and adds a third knob the model does not have: the per-tile 5→`NumNoCPortsPerTile`
concentration xbar in front of the inter-group mesh.

---

## 2. Per-hop latency — measured from RTL, not assumed

`noc_profiling/session_0/l2_router_g*_req.log` (4-group RLC session; format decoded from
`cachepool_noc_profiling.sv`: `P <dir> <in|out> <cycle> <write> <addr> <src_id>`, dir N=0 E=1
S=2 W=3).

Matching packets by `(addr, write, src_id)`:

| measurement | result |
|---|---|
| router **output** at group A → router **input** at neighbour B | **0 cycles** (links are combinational) |
| router **input → output** (transit), g1 W→E | min **2**, p50 **2**, p90 145, max 437 |
| same, g3 W→E | min **2**, p50 **2**, p90 134 |
| same, g2 S→W | min **2**, p50 **2**, p90 133 |

**Per-hop cost is 2 cycles** — the in-FIFO and out-FIFO of `floo_router` (both non-fall-through,
Depth=2). The long tail is congestion, which a queueing model must produce on its own rather
than bake into a constant. **The GVSoC model's 2 cyc/hop assumption is confirmed correct**, as is
`router_input_queue_size=2` (= `InFifoDepth`).

---

## 3. Structural diff and what was fixed

| aspect | RTL | model before | action |
|---|---|---|---|
| L2 mesh shape | `nb_x × nb_y`, group at each node's Eject | `(nb_x+2) × (nb_y+2)`, groups on the interior | **FIXED** |
| L2 channels | `2 × nb_y` on West(x=0)/East(x=max) edges — 8 at 4×4 | `2 × (nb_x+nb_y)` around the whole perimeter — 16 at 4×4 | **FIXED** |
| L2 channel granule | 1024 B (`addr[12:10]`) | 256 B | **FIXED** |
| DRAM window | `dram_addr 0x8000_0000`, `dram_len 0x2000_0000` | `l2_size = 0x0100_0000` (16 MiB) | **FIXED** |
| per-hop latency | 2 cyc | 2 cyc | confirmed |
| router in-queue | `InFifoDepth = 2` | 2 | confirmed |
| L1 per-controller geometry | 4-way × 256 entry/way × 64 B = 64 KiB, `BankFactor=2`, 4 ctrl/tile = 256 KiB/tile | identical | confirmed |
| L2 routing | SourceRouting | XY | equivalent paths; left as-is |
| L1 NoC instances | `NumTilesPerGroup × NumNoCPortsPerTile` meshes | 5 (one per port class) | **open** |
| 5→`NumNoCPortsPerTile` concentration xbar | present | absent | **open** |
| `NumLGPortCore` / `NumRemoteGroupPortCore` split | two independent `n`s | one `num_remote_port_core` | **open** |
| SRAM forwarding buffer (`l1d_use_fwd_buf=1`) | on | structural core only, incomplete | **open** |

The corrected L2 mesh was verified by dumping the generated `gvsoc_config.json` at the 4×4
config: `dim 6 × 4`, **16 routers** (group nodes only), 24 NIs (16 groups + 8 channels),
8 mappings — `chan0..3` at x=0 y=0..3, `chan4..7` at x=5 — `base = c*0x400`, `size = 0x400`,
`period = 0x2000`. That is exactly `addr[12:10]`, i.e. RTL's `getDramCTRLInfo`.

A channel is modelled as a network interface with **no router of its own**. `floonoc.cpp`'s
`get_router_neighbour()` returns the NI directly when the neighbouring node has no router, and
the NI-attach scan binds it to the adjacent group router — so it costs zero extra hops, exactly
like RTL's `floo_tcdm_chimney` on an edge router's unused West/East port. (Same pattern as
`pulp/pulp/chips/magia/soc.py`.) The two extra columns in `dim_x` are addressing space for those
chimneys, not a ring of extra routers.

---

## 4. Calibration against the RTL RLC baseline

`reports/rlc_64core_baseline_2026-08-24/` runs the RLC linked-list kernel on the **64-core**
(`cachepool_4g`: 2×2 groups × 4 tiles × 4 cores) build. `M1_N1350_K100` activates 4 cores, and
both engines print the same per-core `total cycles`, so this is a direct comparison of the
**same binary on the same machine size**.

| core | RTL | GVSoC (mesh on) | GVSoC (mesh off) |
|---|---|---|---|
| 0 | 150,215 | 214,306 | 213,267 |
| 1 | 150,183 | 213,587 | 213,613 |
| 2 | 150,175 | 267,201 | 263,799 |
| 3 | 150,175 | 271,136 | 268,009 |
| **mean** | **150,187** | **241,558** (+60.8 %) | 239,672 (+59.6 %) |
| **spread** | **40** | 57,549 | 54,742 |

Caveat on the metric: the GVSoC run does not reach end-of-simulation inside the harness window,
so only the per-core kernel region is compared — which is exactly the number both engines print,
and which was **bit-identical across seven independent runs**. The RTL log likewise continues
well past these prints.

Two facts, both robust:

1. **The L2 mesh accounts for ~0.8 % of the kernel** (mesh on vs off) — the working set is
   L1-resident after warm-up, so the new topology is not where the error lives.
2. **The RTL's four cores are symmetric to within 40 cycles; the model's differ by 57 k.** The
   split is a clean 2-2 (cores 0,1 ≈ 214 k; cores 2,3 ≈ 267-271 k). This asymmetry is the
   strongest single clue: the model is serialising something that the RTL shares fairly.

Ruled out:

- **AMO lane occupancy** — `INSITU_AMO_WINDOW` = 0 / 4 / 8 / 18 gives **bit-identical** results
  (213,587 / 214,306 / 267,201 / 271,136 in every case). The AMO lane is not on this kernel's
  critical path, so neither the occupancy window nor the park queue explains the gap.
- **The L2 refill mesh** — see above, 0.8 %.

### The dominant lever: `resp_latency_cycles`

Sweeping `INSITU_RESP_LAT` (default 8) on the same kernel:

| `resp_lat` | fast pair | slow pair | mean | vs RTL |
|---|---|---|---|---|
| 0 | 149,248 / 149,678 | 195,098 / 195,370 | 172,349 | +14.8 % |
| 4 | 181,868 / 182,397 | 230,064 / 231,845 | 206,544 | +37.5 % |
| 6 | 197,263 / 197,995 | 249,470 / 252,263 | 224,248 | +49.3 % |
| **8 (default)** | 213,587 / 214,306 | 267,201 / 271,136 | 241,558 | +60.8 % |
| **RTL** | 150,175 / 150,183 | 150,175 / 150,215 | **150,187** | — |

The kernel is almost purely latency-bound (a dependent pointer-chasing chain): each +1 cycle of
`resp_latency_cycles` costs ≈ 8,100 cycles of runtime. At `resp_lat = 0` the **fast pair matches
the RTL to within 0.6 %** (149,248 / 149,678 vs 150,175 / 150,215).

This exposes a real tension rather than a knob to retune. `resp_latency_cycles = 8` exists
because it makes the **isolated** hit latency come out at 10 cycles, which is the RTL-measured
value; setting it to 0 would trade that anchor away. The two facts together say the 8 cycles are
being applied somewhere they are additive with time the closed-loop path already spends —
plausibly once per cache core traversed, so a remote access (local xbar → another tile's bank)
pays it more than once. **The fix is structural — the RTL's 10-cycle hit should be a floor on
the total served latency, not an addend at the pipeline tail** (`insitu_cache_core.cpp:888`,
`resp_done_cyc_.push_back(now + resp_latency_cycles_)`) — not a change of the constant. Left
unchanged in this round: changing the default without the structural fix would break the
isolated calibration that is itself RTL-anchored.

### The second, independent defect: a 2-2 core asymmetry

At **every** `resp_lat` value the four cores split cleanly into a fast pair (0, 1) and a slow
pair (2, 3), separated by ~46-54 k cycles. RTL's four cores agree to within 40 cycles. This
offset is largely independent of `resp_lat`, so it is a second bug, not a symptom of the first.

Checked and excluded as the cause: the tile crossbar (`insitu_cache_xbar.cpp`) is a pure
combinational router with no arbitration, and the cache core's stage-0 arbiter
(`insitu_cache_core.cpp::stage0_arbitrate`) is a plain arrival-order FIFO. The remaining suspect
is the bounded accept queue (`in_q_cap_`, default 32) together with `admission_stall_q_`
re-admission, which can systematically favour whichever requester refills the queue first.

---

## 5. RTL-side changes worth tracking (not yet modelled)

`reports/amo_lrsc_fix_2026-08-24/FINDINGS.md` fixes three pre-existing LR/SC defects in
`spatz_cache_amo.sv`: reservation stealing (now with `ResvTimeoutCycles = 1024` aging),
`core_id` not being a hart id (reservations now key on `{tile_id, core_id}`), and single-entry
SC tracking (SC outcome now stamped into `tcdm_user_t.is_sc` / `.sc_fail` at issue). The model's
AMO shim implements none of these semantics — it has no reservation table at all. Not currently
load-bearing for the RLC comparison (see the sweep above), but it is the reference behaviour if
LR/SC is ever modelled properly.

New RTL knobs the model does not mirror: `l1d_use_folded`, `l1d_fold_way_group`,
`l1d_use_hash_way`, `l1d_use_fwd_buf` (all on by default in the multi-group configs),
`l1d_tag_data_width = 92`, `dram_type = HBM2` → `refill_data_width = 512`.

---

## 6. Open items, in priority order

1. **Make `resp_latency_cycles` a floor on total served latency instead of a tail addend.** This
   is the single highest-value calibration fix: it is worth up to +46 % on the RLC kernel and it
   is what reconciles the isolated hit = 10 anchor with the closed-loop result.
2. **The 2-2 core asymmetry** (~46 k cycles, independent of `resp_lat`). Prime suspect: the
   bounded accept queue / admission-stall re-admission order in `insitu_cache_core.cpp`.
3. **L1 NoC instance count** — RTL runs `NumTilesPerGroup × NumNoCPortsPerTile` parallel meshes
   with a 5→x concentration xbar per tile; the model runs 5 meshes, one per port class.
4. **`NumLGPortCore` vs `NumRemoteGroupPortCore`** — the model collapses both into one
   `num_remote_port_core`. RTL 4g uses lg=4 / rg=1; 16g uses lg=2 / rg=1.
5. **`fdotp_M32768` fails its internal check at 256 cores** — and fails identically on the
   pre-change build (`Calc 613.09` before, `635.41` after, `Exp 628.15`), so this is **not** a
   regression from this round. The CachePoolTests binaries in the RTL tree were rebuilt
   2026-08-24, so previously recorded passing numbers were measured against different binaries
   and should not be trusted as a baseline until re-established.
6. Per-channel DRAM storage / DRAMSys timing — still one shared backing store.
