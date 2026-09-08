# Suite topologies

The QEMU shape behind every suite, as launched by `../topos/t*.sh`.

Conventions shared by (nearly) all of them:

- Root: a `pxb-cxl` host bridge (`cxl.1`, `bus_nr=12`) on `pcie.0` with a
  single `cxl-rp` — a passthrough host bridge unless a suite says
  otherwise. Multi-HB suites add `cxl.2`/`cxl.3` at other bus numbers.
- Every port and device carries `x-256b-flit=on` (BI requires the link in
  256B Flit mode, §9.14.1) except where a suite turns it off on purpose.
- Endpoints are `cxl-type3` with a 1G volatile memdev and `hdm-db=on`
  (HDM-DB capable) unless noted; `hdm-db` off models a plain HDM-H device.
- Windows: one 4G CFMWS (`cxl-fmw.0`) with `interleave-granularity=4k`
  and `back-invalidate=on` — "the BI window". Suites that need an HDM-H
  window add a second CFMWS without the restriction.
- Role legend, in the spec's own vocabulary. Table 8-157 defines BI
  **Enable** as "indicates a BI-capable device is connected directly to
  this Downstream Port", so the role follows adjacency, not port type -
  a Root Port takes Enable too when the device hangs off it. Table 7-97
  names the two DSP positions: **Above SLD** (the device is directly
  connected) does "Received BI-ID is ignored, BI-ID[7:0]<-BusNum(vPPB)",
  i.e. it stamps; **Above HBR USP** (a switch sits below) does
  "Propagate BI-ID", i.e. it relays what was stamped deeper. Exactly one
  dport per path stamps; every dport above it relays, and programs
  **Forward**. Table 7-97 is a switch table and has no Root Port column,
  so a Root Port carries no positional label below - its role comes from
  Table 8-157 ("connected directly") and Table 9-13, which is also the
  only place the root-port case is described at all. Switch USPs carry
  the BI Route Table and, when a region is committed, the HDM decoder BI
  bit an Enabled DSP verifies before accepting a BISnp (Table 9-13).
- **nr_bi** is the kernel's per-dport count of BI-enabled endpoints below
  that dport (adopted firmware paths count too). The registers are
  programmed on the 0→1 edge, cleared and dealloc-committed on the 1→0
  edge, and left alone in between — so a shared level holds its role
  until the last endpoint below it goes away. BI setup runs at endpoint
  probe, independent of windows or regions, so nr_bi is nonzero wherever
  the device and path are BI-capable, even in HDM-H-only suites. The
  counts below are steady state after boot; transitions are shown where
  they are the point of the suite.
- The qemu BI oracle (`-d guest_errors`) watches every BI Decoder write
  against the real topology in all of these.

## t25 — multi-level switch invariants (three boots)

### t25/shared: two endpoints through one Above-HBR-USP DSP

```
pxb-cxl (cxl.1)
└─ cxl-rp rp0                       switch below   → Forward  nr_bi=2
   └─ cxl-upstream us0              outer USP (BI RT, shared)
      └─ cxl-downstream dsp0        Above HBR USP  → Forward  nr_bi=2
         └─ cxl-upstream us1        inner USP (BI RT, shared)
            ├─ cxl-downstream dsp1  Above SLD      → Enable   nr_bi=1
            │  └─ cxl-type3 mem0    (hdm-db)
            └─ cxl-downstream dsp2  Above SLD      → Enable   nr_bi=1
               └─ cxl-type3 mem1    (hdm-db)
```

Both paths converge at `dsp0`, the one dport that is Above HBR USP for
two devices at once, and each enable owes its own commit edge there
(Table 8-152/8-156). The teardown walks the counts back down:

```
                 rp0  dsp0  dsp1  dsp2
boot              2     2     1     1
unbind mem0       1     1     0*    1     * cleared + dealloc commit
unbind mem1       0*    0*    0     0*    dsp0/rp0 hold Forward until here
```

### t25/rollback: commit fault at an Above-HBR-USP DSP

```
rp0 ─ us0 ─ dsp0 (x-bi-commit-fault=error)   Above HBR USP, commit FAILS
            └─ us1 ─ dsp1                    Above SLD, enabled first
                     └─ cxl-type3 mem0
```

The bottom-up walk enables and commits the Above-SLD level (`dsp1`
nr_bi 0→1), then hits the forced commit error at `dsp0` — which never
increments (the failure path returns before nr_bi++). The rollback
unwinds `dsp1` back to 0; every count ends 0 and both registers read
cleared.

### t25/deep: three switch levels

```
rp0 ─ us0 ─ dsp0        Above HBR USP → Forward   nr_bi=1
       └─ us1 ─ dsp1    Above HBR USP → Forward   nr_bi=1
             └─ us2 ─ dsp2  Above SLD  → Enable   nr_bi=1
                      └─ cxl-type3 mem0 (hdm-db)
```

Five BI decoders (endpoint, three DSPs, RP), three route tables, six
commits, and a single endpoint refcounted once at every level — the
counts and roles that prove the walk is depth-agnostic (Table 7-97
"Above HBR USP": Propagate, exercised at two levels).

## t1 — direct attach

```
rp0 ─ cxl-type3 mem0 (hdm-db)        RP → Enable   nr_bi=1
```

The minimal BI path: the device is connected directly to the RP, so the
RP takes the Enable itself; no switch, and no commit anywhere (Table
8-156 reserves the commit at RPs and devices).

## t2 — single switch

```
rp0 ─ us0 ─ dsp0 ─ cxl-type3 mem0 (hdm-db)
RP → Forward nr_bi=1   DSP → Enable nr_bi=1   USP: BI RT
```

The canonical one-switch walk: DSP Enable + decoder/RT commits, RP
Forward. Phase 2 (unbind/rebind: both counts 1→0→1) and phase 3
(lifecycle reader race) reuse this boot.

## t3 — BI-capable device, HDM-H window

t2's shape, but the only window has no `back-invalidate` restriction:
no BI root decoder exists and only HDM-H regions commit — yet BI setup
is window-independent, so the path still enables (`dsp0`/`rp0`
nr_bi=1).

## t4 — non-BI device under the BI window

t2's shape with `hdm-db` off on the endpoint: not BI-capable, no BI
setup, nr_bi=0 everywhere; region attach must reject ("BI not enabled
on device").

## t5 — two endpoints, one switch, one RP

```
rp0 ─ us0 ─ dsp0 ─ mem0 (hdm-db)     rp0 → Forward  nr_bi=2
         └─ dsp1 ─ mem1 (hdm-db)     dsp0/dsp1 → Enable  nr_bi=1 each
```

A 2-way HDM-DB region across both; the shared levels are the USP/RP.
Phase 2 unbinds one endpoint's driver: `rp0` 2→1 and it must hold Forward
for the survivor. (The shared Above-HBR-USP variant is t25/shared.)

## t6 — switch USP without a BI RT

t2's shape and counts (`dsp0`/`rp0` nr_bi=1); `USP_EXTRA` suppresses
the BI Route Table when QEMU grows a knob for it (the RT is "optional
for switches that do not require an explicit BI RT Commit", §8.2.4.26).

## t7 / t8 — non-256B-flit hop

t2's shape with `x-256b-flit=off` on the RP uplink (t7) or the DSP
(t8): the capability walk must refuse the path at that hop (§9.14.1,
§9.14.3), leaving nr_bi=0 everywhere. SKIP today: the flit knob is
cosmetic in QEMU, so the path actually enables (counts as t2) and the
negative cannot be staged.

## t9 — two-level cascade (single endpoint)

```
rp0 ─ us0 ─ dsp0 ─ us1 ─ dsp1 ─ cxl-type3 mem0 (hdm-db)
RP → Fwd     Above HBR USP → Fwd     Above SLD → Enable
nr_bi=1      nr_bi=1                 nr_bi=1
```

Windows: BI (`fmw.0`) plus a plain HDM-H window (`fmw.1`). An HDM-DB
region commits two hops down, then register truth is read back while
it is committed — roles by position plus the HDM decoder BI bit at
both USPs (Table 9-13) — and an HDM-H region commits across the same
cascade. Phase 2 unbinds the outer switch port with a region live
(every count 1→0 through the devres cascade) and rebuilds the cascade
on rebind (back to 1).

## t10 — two RPs on one host bridge

```
cxl.1 ─ rp0 ─ mem0 (hdm-db)      each RP → Enable, nr_bi=1
      └─ rp1 ─ mem1 (hdm-db)     (independent counts)
```

Independent per-RP BI setups under a single (non-passthrough) HB.

## t11 — persistent memdev

t2's shape and counts with a `persistent-memdev` + LSA endpoint
(`sn=0xbeef`): an HDM-DB PMEM region commits.

## t12 — BI + non-BI siblings under one switch

t5's shape with `hdm-db` off on `mem1`: only the BI device enables
(`dsp0` nr_bi=1, `dsp1` 0, `rp0` 1); a 2-way attach across both must
reject the non-BI target.

## t13 — host-only + back-invalidate window (negative launch)

No guest, barely a topology: one `pxb-cxl` (no RP, no endpoint) and a
4G CFMWS with no granularity set, declaring both `host-only=on` and
`back-invalidate=on`, launched raw (`-nodefaults`, not through
`launch_qemu`, so no BI oracle either). QEMU must refuse to launch
(§9.18.1.3 Window Restrictions make the combination undefined).

## t14 — two host bridges, split windows

```
cxl.1 ─ rp0 ─ mem0 (hdm-db)      fmw.0: BI  → targets cxl.1
cxl.2 ─ rp1 ─ mem1 (hdm-db)      fmw.1: HDM-H → targets cxl.2
```

Both devices are BI-capable, so both RPs enable (nr_bi=1 each — BI
setup does not consult windows); the window split is what the region
paths must respect: endpoints bind to the right root decoder and
cross-assignment rejects.

## t15 — one endpoint, two windows

t1's direct-attach shape (`rp0` nr_bi=1) with both a BI and an HDM-H
window targeting the same HB: a decoder cycled out of an HDM-DB region
reverts and then commits into an HDM-H region.

## t16 — firmware-committed decoders (multi-boot, host-driven)

Four shapes across its scenarios, all passthrough single-RP (the only
staging QEMU supports):

```
(a) cxl.1 ─ rp0 ─ vmem0 (x-committed=hdm-db | hdm-h)      per scenario
(b) cxl.1/cxl.2/cxl.3 ─ rp1/rp2/rp3 ─ vmem0/1/2           combined boot
(c) cxl.1 ─ rp1 ─ vmem0 ┐  x-committed-ways=2: a staged 2-way
    cxl.2 ─ rp2 ─ vmem1 ┘  committed interleave set
(d) cxl.1 ─ rp1 ─ accel0 (cxl-accel, x-coherency-unknown=on, x-committed=hdm-d) ┐ x-committed-ways=2,
    cxl.2 ─ rp2 ─ vmem1  (hdm-db=on, x-committed=hdm-h)                          ┘ window without back-invalidate
```

`x-committed` stages the endpoint HDM decoder committed (BI bit per
mode) and, for `hdm-db`, the endpoint BI Enable — the firmware
adoption entry state. nr_bi=1 at each RP above an `hdm-db` device
(adoption takes the refcount exactly like a fresh enable; (d)'s `vmem1`
is `hdm-db` too and enables fresh despite its `hdm-h` commit), 0 above
the `hdm-h` ones that lack `hdm-db` (not BI-capable). Window variants
(BI present/absent) drive the adopt vs reject legs. (d) is the mixed
range-type set: an HDM-D-committed accelerator and an HDM-H-committed
Type 3 under a bare (non-BI) window, which must not assemble
("coherency model mismatch"). Deviations from the shared conventions:
memdevs are 256M `share=on`, the RPs never carry an explicit
`x-256b-flit=on` (only the `hdm-db` endpoints do), and (d)'s first
endpoint is a `cxl-accel`.

## t17 — QMP hotplug

```
rp0 ─ us0 ─ dsp0 ─ ep0 (sn=0x171, cold-plugged; hot-remove target)
         └─ dsp1   (empty: hot-add target, sn=0x172; survivor)
         └─ dsp2   (empty: re-add target, sn=0x173)
```

BI setup driven by real pciehp events, with `rp0` aggregating:

```
                    rp0  dsp0  dsp1  dsp2
boot                 1     1     -     -
hot-add 0x172        2     1     1     -
hot-remove 0x171     1     0     1     -     survivor path (dsp1) stays enabled
hot-add 0x173        2     0     1     1
```

## t18 — storm (t5's shape)

Same topology and steady-state counts as t5 (`rp0` nr_bi=2), driven
concurrently: unbind/bind flips race the RP's count up and down under
a live sysfs reader, then region create/commit/destroy churn.

## t19 / t20 — window-level 2-way interleave

```
cxl.1 ─ rp0 ─ mem0 (hdm-db)     one 2-way BI window targeting BOTH
cxl.2 ─ rp1 ─ mem1              HBs (fmw.0.targets.0/1)
```

t19: both endpoints `hdm-db` — nr_bi=1 at each RP; a manual 2-way
HDM-DB region commits. t20: `mem1` plain — `rp1` stays 0; the mixed
attach must reject in either wiring order.

## t21 — BOTH-coherency fallback

t2's shape plus a second (HDM-H) window, with
`x-bi-commit-fault=timeout` on the DSP when QEMU offers it: BI setup
then fails at boot and the rollback returns every count to 0; an HDM-DB
attach fails closed while a host-only region still commits on the same
endpoint decoder. Without the knob the path enables (t2's counts) and
the fallback checks SKIP.

## t22 — Unknown Supported Coherency Models

t1's direct-attach shape (`rp0` nr_bi=1) with `x-coherency-unknown=on`:
the endpoint advertises 00b in Supported Coherency Models (Table 8-116)
and must still commit into an HDM-DB region via the `cxlds->bi` gate.

## t23 — commit faults (six boots, host-driven)

t2's single-switch shape, re-launched per scenario with fault knobs:
`x-bi-commit-fault=error|timeout` on the DSP (BI Decoder commit) or
the USP (BI RT commit), `x-bi-committed=on` on the DSP (committed
decoder, uncommitted RT — the adopt-rt leg), and
`x-bi-commit-fault=error,x-bi-commit-fault-after=1` on the DSP (the
allocate-time commit succeeds, the dealloc-time one faults). Counts:
the four fault legs roll back to 0 everywhere (a failing level never
increments); adopt-rt and dealloc-err reach t2's steady state
(`dsp0`/`rp0` nr_bi=1); only dealloc-err then tears down (cxl_pci
unbind), adopt-rt ends at steady state.

## t24 — firmware adoption (five boots, host-driven)

```
(adopt)      rp0 ─ mem0 (x-committed=hdm-db)      full firmware path
(fresh-dev)  rp0 ─ us0(x-bi-rt-committed) ─ dsp0(x-bi-committed) ─ mem0
(wrong-role) rp0 ─ us0 ─ dsp0(x-bi-committed!) ─ us1 ─ dsp1 ─ mem0
(fw-path)    rp0 ─ us0(x-bi-rt-committed) ─ dsp0(x-bi-fw-committed)
               ─ us1(x-bi-rt-committed) ─ dsp1(x-bi-committed) ─ mem0(x-bi-enabled)
(fw-partial) as fw-path, but us1 WITHOUT x-bi-rt-committed (inner RT uncommitted)
```

Adoption as a path property: a firmware-enabled direct-attach device
adopts with zero commit cycles; staged-committed dports under a device
firmware did NOT enable still owe their commits; a DSP that is Above
HBR USP but staged with the Above-SLD role (Enable) gets corrected to
Forward and committed. Counts: adopt `rp0`=1 (an adopted level still
takes nr_bi++, so teardown unwinds it like any other); fresh-dev
`dsp0`/`rp0`=1; wrong-role `dsp1`/`dsp0`/`rp0`=1. The adopt and
fresh-dev unbinds walk their counts back to 0; wrong-role and the two
fw legs end at steady state.

Two further boots stage a cascade firmware brought up end to end:
`x-bi-enabled=on` sets only the endpoint's BI Enable (so, unlike
`x-committed`, it composes with switches), `x-bi-fw-committed=on`
stages the transit DSP's Forward+committed, `x-bi-committed=on` the
adjacent DSP's Enable+committed, `x-bi-rt-committed=on` a USP's route
table. fw-path (every level correct and committed) adopts the whole way
up with zero commit cycles and both DSP roles kept; fw-partial leaves
the inner RT (`us1`) uncommitted, so adoption dies at `dsp1` and `dsp0`
above it - staged perfectly - must still program and commit (4
commits, not 2). Counts: `dsp1`/`dsp0`/`rp0`=1 in both; neither unbinds.

## t26 — Type 2 accelerator coherency (one boot)

```
pxb-cxl (cxl.1)
|- cxl-rp rp0 - cxl-accel accel0   hdm-db=on, Supported Coherency
|                                  Models = device-coherent only
`- cxl-rp rp1 - cxl-type3 mem1     host+dev coherency (control)
fmw0: BI (HDM-DB)   fmw1: default (HDM-H)   fmw2: host-only=off (HDM-D)
```

The cxl-accel qemu device (a type3 subtype) advertises
device-coherent-only HDM, as an accelerator that computes on its
memory must. The suite pins both arms of the region attach coherency
gate: the accelerator commits an HDM-DB region (back_invalidate=1,
target_type inherited as accelerator) and is refused an HDM-H attach
("HDM is device-coherent only") that the type3 control then commits
on the same window. The reject arm is reachable by no other device
model - plain type3 advertises host+dev, x-coherency-unknown nothing.
The HDM-D window (host-only=off, no BI) documents today's kernel gap:
its root decoder carries cap_type2 without cap_back_invalidate, and
can_create_ram() offers no create attr for DEVMEM-without-BI, so the
window is enumerable but not yet usable.

## t29 — mixed Type 2 / Type 3 (one boot)

```
pxb-cxl (cxl.1)
|- rp0 - us0 -+- dsp0 - cxl-type3        (hdm-db, host+dev)
|            `- dsp1 - cxl-accel (type2) (hdm-db, dev-only)
`- rp1 - us1 -+- dsp2 - cxl-accel (type2)
             `- dsp3 - cxl-type3
```

Two switches, each carrying one Type 2 accelerator (device-coherent
only) and one Type 3 expander (host+dev) behind a single BI window -
the first suite where BI runs over a topology of mixed device
coherency. All four commit their own HDM-DB region; a 2-way HDM-DB
region then interleaves a Type 2 and a Type 3 target under one switch
(both bi=1, both target_type accelerator, positions computed by
cxl_calc_interleave_pos), and teardown reverts every decoder cleanly.
Both switch groups happen to carry one device of each class, so the
mixed-pair selection for the interleave leg is topology-robust.

## t30 — HDM-D decoder vs window coherency restriction (three boots)

```
(hdm-d)     cxl.1 ─ rp0 ─ cxl-accel mem0 (x-committed=hdm-d)   fmw.0: host-only=off
(refusal)   cxl.1 ─ rp0 ─ cxl-accel mem0 (x-committed=hdm-d)   fmw.0: device-coherent=off
(refusal2)  cxl.1 ─ rp0 ─ cxl-type3 mem0 (x-committed=hdm-h)   fmw.0: host-only=off
            rp0: no BI role, nr_bi=0 in all three
```

Not a BI topology: no window carries `back-invalidate`, no device
carries `hdm-db` (qemu defaults it off, so nothing is BI-capable) and
neither `rp0` nor the endpoint carries `x-256b-flit`. The endpoint is a
`cxl-accel` because HDM-D is a Type 2 decode. `x-committed=hdm-d`
stages a firmware-committed device-coherent decoder (TRT and BI both
clear); qemu picks the lowest window whose restrictions match and
otherwise falls back to the lowest window targeting the HB. Boot 1
offers the matching device-coherent window (`host-only=off`) and the
region must auto-assemble and commit with endpoint `bi=0`. Boot 2
narrows the only window to host-only (`device-coherent=off`), so the
staging falls back into a window that contradicts the decoder and
assembly must refuse ("coherency model not permitted by the window",
no region). Boot 3 is the mirror: a `cxl-type3` with
`x-committed=hdm-h` under the device-coherent-only window, same refusal
from the opposite direction. SKIPs wholesale when qemu lacks `cxl-accel`
with `x-committed`, or its `hdm-d` flavor.

## t27 — BI across a device reset (seven boots)

```
pxb-cxl (cxl.1)
└─ cxl-rp rp0            RP → Enable   nr_bi=1   (untouched by the reset)
   └─ cxl-type3 mem0     (hdm-db)      reset target
```

Direct attach so the device is connected directly to the Root Port and
the reset lands strictly below it - which makes "the endpoint's BI Decoder
was wiped while the dport above still points at it" directly
observable. Reset is issued through the kernel (`/sys/bus/pci/devices/
<ep>/reset`; method `cxl_bus` on the SBR arms, `flr` on the FLR arms)
rather than a raw setpci poke, so the
`pci_error_handlers` `.reset_prepare`/`.reset_done` path actually runs.
Boot 1 resets with nothing committed, then walks the whole recovery
arc: the invalidated flag refuses an HDM-DB attach, unbind unwinds the
RP anyway, and a rebind re-runs the enable path from scratch until a
region commits again. Boot 2 commits an HDM-DB region first. Boots 3 and 4 are
the FLR arms, live against the faithful-FLR qemu: DEVCAP FLR
advertised, CXL.cache/mem component registers preserved, so the reset
that must not wipe BI measurably does not - and the invalidation stays
silent. Boot 4 repeats it with a committed HDM-DB region, where the
two flavors diverge: the SBR of boot 2 wipes the decoders and trips
the decoder-loss taint, while the FLR leaves region, decoders and BI
all standing.
Boot 5 moves the device below a switch:

```
pxb-cxl (cxl.1)
└─ cxl-rp rp0            RP  → Forward  (above the reset boundary)
   └─ cxl-upstream us0
      └─ cxl-downstream dsp0   DSP → Enable   (above the reset boundary)
         └─ cxl-type3 mem0     (hdm-db)       reset target
```

The bus reset lands on the endpoint's bus only, so both dports above
keep their programming and their nr_bi across it - and the later
unbind must unwind both levels despite the invalidated cxlds->bi,
the multi-level form of the leak the unconditional dealloc prevents.

Boot 6 resets a firmware-adopted path (t24's adopt shape, direct-attach
`mem0` with `x-committed=hdm-db`): the SBR wipes the adopted endpoint
Enable, invalidation fires exactly as on a driver-enabled path, and
recovery must come up fresh - the rebind window shows "BI requests
enabled" and no re-adopt of the wiped seed (the unbind also walks the
dead auto-region down through a wiped decoder). Boot 7 swaps in a Type 2
accelerator and adds a plain window:

```
pxb-cxl (cxl.1)
└─ cxl-rp rp0            RP → Enable   nr_bi=1
   └─ cxl-accel accel0   (hdm-db, device-coherent only)   reset target
fmw.0: BI    fmw.1: plain (HDM-H)
```

With an HDM-DB region committed, the SBR invalidates `cxlds->bi`; the
HDM-DB attach then refuses and the device-coherent-only check refuses
the plain window - nothing attachable remains until a rebind, after
which the region commits again. Boots 6 and 7 SKIP when qemu lacks
`x-committed` / `cxl-accel`.

## t28 — AER fatal-error recovery (two boots)

```
pxb-cxl (cxl.1)
└─ cxl-rp rp0            RP → Enable   nr_bi=1   (AER irq thread runs here)
   └─ cxl-type3 mem0     (hdm-db)      injection target: MALF_TLP
```

t27's direct-attach shape and its one BI window, booted with
`pcie_ports=native` so the OS owns AER. Each boot injects an
Uncorrectable Fatal through qemu's HMP (`pcie_aer_inject_error mem0
MALF_TLP`): scenario A with nothing committed, scenario B with an HDM-DB
region live (detached and decommitted by the bounce, never deleted).
The AER path never runs `.reset_prepare`/`.reset_done`
(`PCI_RESET_NO_RESTORE`); `cxl_error_detected()` bounces the memdev
driver before the link reset and `cxl_slot_reset()`'s `device_attach()`
re-runs the enable path from scratch, so the RP's count round-trips:

```
                        rp0
boot                     1
bounce (devres)          0     cxl_error_detected, before the link reset
slot reset + attach      1     RP re-programmed Enable, endpoint Enable back
```

A fresh HDM-DB region then commits `bi=1`. Premise-SKIPs when the guest
lacks CONFIG_PCIEAER / CONFIG_CXL_RAS or qemu rejects the injection.

## t31 — eight endpoints under one switch, 4-way and 8-way (one boot)

```
cxl-fmw.0 (BI, one target)
└─ pxb-cxl (cxl.1)                 passthrough host bridge
   └─ cxl-rp rp0                   RP  → Forward, nr_bi=8
      └─ cxl-upstream us0          USP decoder iw=4, then iw=8, ig=256
         ├─ cxl-downstream dsp0    DSP → Enable
         │  └─ cxl-type3 mem0      (hdm-db, 256M memdevs)   4-way and 8-way member
         ├─ cxl-downstream dsp1..dsp3          4-way and 8-way members
         └─ cxl-downstream dsp4..dsp7          8-way members only
```

The window has one target, so the root decoder is iw=1 and the region
granularity is free; 256 keeps the USP's eiw/eig inside its 256B
interleave mask at both widths. The 8-way set is the widest a switch
decoder takes (eight targets), and the second half of its target list
lands in TARGET_LIST_HI. The refcount leg unbinds seven of the eight
endpoints under the shared RP before the last one.

## t32 — two switches under two host bridges, 4-way (one boot)

```
cxl-fmw.0 (BI, two targets, 4k)    root decoder iw=2, ig=4096
├─ pxb-cxl (cxl.1)                 window target 0, passthrough
│  └─ cxl-rp rp0                   RP  → Forward, nr_bi=2
│     └─ cxl-upstream us0          USP decoder iw=2, ig=8192
│        ├─ cxl-downstream dsp0 — cxl-type3 mem0   position 0   (512M memdevs throughout)
│        └─ cxl-downstream dsp1 — cxl-type3 mem1   position 2
└─ pxb-cxl (cxl.2)                 window target 1, passthrough
   └─ cxl-rp rp1                   RP  → Forward, nr_bi=2
      └─ cxl-upstream us1          USP decoder iw=2, ig=8192
         ├─ cxl-downstream dsp2 — cxl-type3 mem2   position 1
         └─ cxl-downstream dsp3 — cxl-type3 mem3   position 3
```

Positions are dport-major: position p goes to window target p % 2,
so consecutive positions alternate host bridges and each USP sees
every other 4k stripe (ig = 4k x 2). Wiring the targets in plain BDF
order puts mem1 at position 1, under window target 0, and the attach
refuses it.

## t33 — two switches under one host bridge, two RPs, 4-way (one boot)

```
cxl-fmw.0 (BI, one target)         root decoder iw=1
└─ pxb-cxl (cxl.1)                 HB decoder iw=2, ig=1024 (not passthrough)
   ├─ cxl-rp rp0 (port 0)          RP  → Forward, nr_bi=2
   │  └─ cxl-upstream us0          USP decoder iw=2, ig=2048
   │     ├─ cxl-downstream dsp0 — cxl-type3 mem0   position 0   (512M memdevs throughout)
   │     └─ cxl-downstream dsp1 — cxl-type3 mem1   position 2
   └─ cxl-rp rp1 (port 1)          RP  → Forward, nr_bi=2
      └─ cxl-upstream us1          USP decoder iw=2, ig=2048
         ├─ cxl-downstream dsp2 — cxl-type3 mem2   position 1
         └─ cxl-downstream dsp3 — cxl-type3 mem3   position 3
```

Same shape as t32 one level down: with two RPs the host bridge is not
passthrough and its own HDM decoder carries the first interleave
level. The one-target window leaves the region granularity free, and
1k is used so a granularity other than 256 and 4k is exercised through
three decoder levels.

## t34 — refused attach and stale BI flag (one boot)

```
cxl-fmw.0 (BI, one target)
└─ pxb-cxl (cxl.1)
   └─ cxl-rp rp0            RP → Enable   nr_bi=1
      └─ cxl-type3 mem0     (hdm-db)
```

t1's shape, used for two regressions the v8 review found. Arm 1 commits
an HDM-DB region on mem0, writes the same endpoint decoder into a second
region's target, and requires the refusal to leave the decoder's type,
`bi` and region untouched, with a re-commit still programming BI. Arm 2
clears the endpoint's BI Enable through `/dev/mem`, the stand-in for a
reset the driver never observes, unbinds the endpoint port so the BI
dealloc finds the hardware already clear, then rebinds and requires BI
to come up from scratch. The unbind-versus-reset race at the end is
best effort; the deterministic proof of the released-mapping read needs
the detach work delayed. Arm 3 attaches a region's target without
committing, issues an SBR through `reset_method=cxl_bus` so
`.reset_done` invalidates `cxlds->bi`, and requires the commit to be
refused rather than program BI on a device whose BI Enable the reset
cleared.
