# InSitu Cache — Structure Map (2026-09-08) — multi-scalar core complex (shared Spatz)

Supersedes `insitu_cache_structure_map_2026-08-25.md`. Legend:
**✓** modeled + calibrated · **◐** modeled, data-correct, partially calibrated · **≈** approximated ·
**▣** transcribed, not wired · **✗** not modeled · **N/A**.

> **Change since 2026-08-25:** the model now supports the RTL's **multi-scalar core complex**
> (`origin/dev/multi-scalar`, `cachepool_cc_dual.sv`): `NumScalarPerCC` Snitch harts SHARE one Spatz
> and one L1 cache controller. This is a *hierarchy* change, not just a parameter — the unit that
> owns a Spatz and a cache controller ("core complex", RTL's renamed `NumCC`) is no longer the same
> thing as a hart. Everything the peripheral and the barrier count is per hart; everything the cache
> and the vector unit provide is per CC.
>
> Enabled with `CACHEPOOL_V3_SCALAR_PER_CC=2`; **default 1 = the previous topology, verified
> bit-identical** (RLC `M1_N1350_K100` at 64 cores: 149,248 / 149,678 / 195,098 / 195,370).

---

## What splits per hart vs per core complex

```
CORE COMPLEX (RTL cachepool_cc_dual) — the unit that owns a Spatz             [◐ NEW]
│
├─ hart 0 (primary, even cid) ─┐
├─ hart 1 (secondary, odd cid)─┤ share:
│                              │
│   ├─ ONE Spatz vector unit   │                                              [≈ see below]
│   ├─ ONE L1 cache controller │  NumL1CacheCtrl = NumCC, not NumCores        [✓]
│   └─ 4 VLSU TCDM port classes│  tcdm_req_o[0..NrMemPortsPerSpatz-1]         [✓ shared: both
│                              │                                                  harts' vlsu
│                              │                                                  routers land on
│                              │                                                  the same class]
├─ per hart, NOT shared:
│   ├─ scalar TCDM port class  │  tcdm_req_o[NrMemPortsPerSpatz + h]          [✓ 1 class per hart
│   │                          │                                                  => n_ppc = 4 + N]
│   ├─ its own AMO unit        │  "only the last NumScalarPerCC planes of
│   │                          │   cache_amo_req are driven" (tile.sv)        [✓ n_ctrl x N units]
│   ├─ private stack SPM       │                                              [✓]
│   ├─ peripheral port         │  the counting barrier needs hart identity    [✓]
│   ├─ barrier req/ack, MSIP,  │                                              [✓]
│   │  external IRQ            │
│   └─ L1 I$ port              │  icache nb_cores = harts, not CCs            [✓]
│
└─ cachepool_spatz_lock + acc_mux → CachepoolV3SpatzLock                      [◐ NEW, see below]
```

**Hart numbering.** `k = cc * NumScalarPerCC + h`, cluster-global and contiguous. That is exactly what
the runtime assumes: `snrt_cluster_is_primary()` is `(_snrt_core_idx % 2) == 0` and
`snrt_cluster_vpu_idx()` is `_snrt_core_idx / 2`. Verified in the elaborated config: tile 0 gets
harts 0..7, tile 1 gets 8..15, … tile 7 gets 56..63.

---

## The shared-Spatz arbiter — `CachepoolV3SpatzLock`

Models `cachepool_spatz_lock.sv` (ownership FSM) **and** `acc_mux.sv` (issue gating) as one component,
because they are one decision. Sits on each hart's peripheral path.

| RTL mechanism | model | status |
|---|---|---|
| ACQUIRE/RELEASE intercepted at periph+0x4 / +0x8, before the peripheral | same, per CC | ✓ |
| outcome word `[1:0]` outcome, `[4:2]` reason, `[5]` owner, `[6]` locked | same encoding | ✓ |
| `Free → AcqWait → Locked`, `Locked → RelWait → Free`; hits during a wait get FAIL(PENDING) | same | ✓ |
| Free's implicit owner is host 0; its release is a no-op grant | same | ✓ |
| drain = `outstanding == 0 && lsu_outstanding == 0 && st_rsp_done` | every hart's Ara idle (`nb_pending_insn == 0`) | ≈ |
| Locked: only the owner's acc requests pass, **fully pipelined**, no gate | grant to owner only; the non-owner stalls on its next vector insn | ✓ |
| Free: round-robin, **one request outstanding at a time** | one hart granted at a time, handed over on drain, round-robin preference | ≈ per-op, not per-handshake |
| Free: `lsu_busy_q` — a vector load/store blocks the NEXT grant from either host until it fully drains (`spatz_mem_finished` is per drained op) | grant withheld from everyone while any hart has `nb_pending_vaccess != 0` | ✓ confirmed against RTL by the RTL-side session |
| Free: `route_fifo` — a WRITEBACK op blocks the next grant until its response is taken | **not modelled** (no per-instruction writeback flag) | ✗ optimistic for writeback-heavy Free-mode streams |

**How the gate reaches the core.** The ISS publishes a 3-bit status from `Ara`
(bit0 in flight, bit1 stalled wanting to issue, bit2 vector load/store in flight) and receives a
grant; `IssWrapper::vector_insn_stub_handler` returns `pc` while ungranted, which is the model of
`acc_mux` withholding `acc_qready`. **Unbound ports ⇒ always granted**, so every single-scalar target
is untouched.

### Known fidelity gaps of the shared-Spatz model

1. **Two VRFs, not one.** Each hart keeps a full Spatz model, mutually excluded in time rather than
   physically shared. A program that (incorrectly) relies on retaining vector registers across a lock
   handoff would pass here and fail on RTL. The RTL contract forbids that, so no correct program is
   affected — but the model cannot *detect* the violation.
2. **Scalar FP is not gated.** With `spatz_fpu_en=1` the RTL routes scalar FP through the same acc
   interface, so it is subject to the lock. Our ISS executes scalar FP natively. Irrelevant for the
   dual config as shipped (`spatz_fpu_en ?= 0`, `spatz_num_fpu ?= 0`), but wrong if FP is enabled.
3. **`route_fifo` writeback gate** — see the table above.
4. **Drain granularity.** RTL counts acc handshakes and LSU ops separately and requires
   `spatz_st_rsp_done`; we use one "Ara idle" predicate. Equivalent at instruction granularity,
   coarser within an instruction.

---

## Everything else — unchanged from 2026-08-25

The L2 refill mesh, the L1 NoC, the group/tile hierarchy, the DRAM window, the cache cell internals
and their calibration status are as documented in `insitu_cache_structure_map_2026-08-25.md`. The
open items listed there are still open, in particular:

- **cross-core shared-data visibility** (2026-08-25 03:30 worklog entry) — still open, still bounds
  what any full-core shared-data result is worth;
- **cross-line truncation** — still unfixed, now loud (`[XLINE]` milestones);
- **refill path** — MLP=1 per controller and one shared backing store behind 4 channels.

The multi-scalar work does not touch any of them.
