# E3.5 — calib-TB partition gate (+ a real int32-truncation bug it caught)

2026-08-04 · core `pending` · pulp `pending` · status: **landed, all gates exact**

E3.0–E3.4 made runtime L1 partitioning live in the structural path and verified it at kernel
level (all-shared/all-private only — the cachepool CI kernels never exercise a *mixed*
partition at >1 tile with a private range). E3.5 adds the missing **mixed-partition gate** on
the calib TB, where the partition is frozen at elaboration (the TB has no peripheral). It
immediately caught a real bug.

## 1. The bug the gate caught: `private_start_addr` int32 truncation

**Symptom (first sweep):** m=2/m=3 configs got **zero** sweep-2 hits; per-bank counters showed
the private banks (ctrl_0/1) receiving **no requests at all** — everything routed to the shared
banks (ctrl_2=512, ctrl_3=3584 of 4096 accesses). That exact distribution pins the route as
"mixed mode, `is_private`=false for every address".

**Root cause:** `vp::js::ConfigObject::get_child_int()` returns **`int`** (32-bit) —
`engine/engine/src/json.cpp:319`. The xbar read `private_start_addr` (0x80000000 in the gate,
0xA0000000 in the SoC target) through it: the value wraps negative and sign-extends to
`0xFFFFFFFF80000000` when widened to `uint64_t`, so `addr >= private_start` is false for every
address and the whole private range routes shared.

**Why nothing caught it earlier:** in every deployed config the route takes the all-private
(num_tiles==1) or all-shared (num_private==0) branch, neither of which *reads* `private_start`
(tcdm_cache_interco.sv:234 short-circuit, faithfully transcribed in route.hpp:97). The mixed
branch is only reachable with num_tiles>1 AND 0<num_private<num_cache — exactly what E3.5
exercises for the first time. The runtime CSR path (E3.2 broadcast → `config_handler`) was
never affected (it writes `geom_.private_start` from the 32-bit request data directly).

**Fix** (`insitu_cache_xbar.cpp`): read via the 64-bit path
`cfg->get("private_start_addr")->get_int()` (the `memory.cpp` pattern). Scanned all insitu
models for other address-typed `get_child_int` reads — this was the only one (the remote xbar
hardcodes `priv_start=0`, correct: it only ever sees shared-range traffic by construction).

## 2. What the gate validates

Env knobs (calib TB, elaboration-frozen partition):
`INSITU_CALIB_NUM_TILES` (>1 required — the RTL short-circuits partitioning at NumTiles==1),
`INSITU_CALIB_NUM_PRIVATE` (m), `INSITU_CALIB_PRIVATE_START` (0x80000000 → whole trace is
private-range). New traces (`gen_traces.py` #13): `partition_priv_2sweep_{2048,4096}` — two
sweeps of N sequential private-range lines, single port, delay 200.

Per-bank counters confirm the **modulo fold** exactly (RTL tcdm_cache_interco.sv:257
`addr_bank % num_private_cache_q`): m=3's bank 0 receives **half** the footprint (2048 of 4096
accesses — residue classes 0 and 3 both fold to 0) while banks 1,2 receive a quarter each —
the non-pow2 comparator path, not a bit mask.

The measured table (INLINE_SYNC=1, BANKS=4, XBAR_LAT=0, ML=50; identical hit counts on the
async path):

| sweep-2 hits | m=1 | m=2 | m=3 | m=4 |
|---|---|---|---|---|
| 2×2048 lines | **0** | **0** | **1024** | **2048** |
| 2×4096 lines | **0** | **0** | **2048** | **4096** |

Every value is mechanism-explained — and the mechanism is the RTL's **hash-way-only**
lookup/victim (decoder.sv:163 `proc_hash_way_req` checks only `_hash_way`; the miss allocates
there too — each set behaves direct-mapped-by-hash):

- **m=4** (all-private): bank sees one residue class; the 4 lines per set hash to 4 distinct
  ways → all resident → full sweep-2 hits. Matches the pre-existing capacity gate.
- **m=2**: bank sees two residue classes (L≡0,2 mod 4); per set the 4 lines hash to only
  **2 distinct ways** (`hash = j[10:9]^j[2:1]` collapses in pairs) → mutual eviction → 0 hits.
- **m=3**: bank 0 (two classes) collapses as m=2 → 0; banks 1,2 (one class, 2 lines/set, 2
  distinct hashes) survive → 512+512 at 2048 lines, 1024+1024 at 4096 lines.
- **m=1**: one bank, 8 lines/set over 2 hash ways → 0.

So mixed partitions in the RTL genuinely lose effective associativity on sequential streams —
the model now reproduces that faithfully rather than reporting the naive 4-way capacity.
`data_err=0` everywhere (rotation/unrotation round-trip is data-exact in mixed mode:
private banks rotate bank_bits, shared banks rotate bank_bits+tile_bits).

## 3. Regression gates (all byte-exact, INLINE_SYNC=1)

- capacity_2sweep_2048 (num_tiles=1, no partition knobs): **2048/2048** sweep-2 hits.
- warm_hit_isolated **67,10** · cold_miss_isolated **67** · cold_stream_1p throughput
  **0.0143** · pend_follower **67,73,9,73,10** · coal_merge **67×4 / 10×4 / 8×4 / 10×4**,
  data_err=0 across the board.
- Kernel smoke (16-core fdotp_M32768): see §5 — unchanged (the tile.py change passes
  `num_private_cache` explicitly to the xbar = the same value the xbar's own default computed;
  the xbar.cpp fix is inert in all-shared mode).

**Methodology note (worth remembering):** the structural-path battery gates run with
`INSITU_CALIB_INLINE_SYNC=1` (the calibrated sync-slave path). Without it the open-loop async
FSM reports *emergent* timing (miss 55, hit 2-3) — valid for hit/miss counting, wrong for
absolute-latency gates. The standing docs' "67/10" values are the sync-slave ones.

## 4. Files

- `core/models/cache/insitu/insitu_cache_xbar.cpp` — the int32-truncation fix.
- `core/models/cache/insitu/insitu_cache_tile.py` — `config.num_private_cache` /
  `config.private_start_addr` elaboration overrides; the xbar now receives `num_private_cache`
  explicitly (was: xbar.py's own default rule — same value for all existing targets).
- `pulp/insitu_cache_calib/__init__.py` — `INSITU_CALIB_NUM_TILES` / `_NUM_PRIVATE` /
  `_PRIVATE_START` knobs (structural-tile branch only).
- `pulp/insitu_cache_calib/gen_traces.py` + `traces/partition_priv_2sweep_{2048,4096}.trace`.

## 5. Verification commands

```bash
source sourceme.sh && export PATH=/tmp/py312_shims:$PATH
# partition fold sweep (m = 1..4 × {2048,4096}-line traces)
INSITU_CALIB_STRUCTURAL_TILE=1 INSITU_CALIB_STRUCT_BANKS=4 INSITU_CALIB_XBAR_LAT=0 \
INSITU_CALIB_INLINE_SYNC=1 INSITU_CALIB_NUM_TILES=4 INSITU_CALIB_NUM_PRIVATE=$m \
INSITU_CALIB_PRIVATE_START=0x80000000 \
INSITU_CALIB_TRACE=partition_priv_2sweep_2048 INSITU_CALIB_OUTDIR=/tmp/e35/m$m \
gvsoc --target=insitu_cache_calib run
# sweep-2 hits = rows idx>=2048 with latency<50 in /tmp/e35/m$m/partition_priv_2sweep_2048_trace_out.gvsoc.csv
```

Kernel smoke: 16-core fdotp_M32768 unchanged at **56,484** (the E3.3 value), zero FAIL.
