# Suite topologies

The QEMU shape behind every suite, as launched by `topos/t*.sh`.

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
Phase 2 hot-removes one endpoint: `rp0` 2→1 and it must hold Forward
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

No guest, barely a topology: one `pxb-cxl` and a CFMWS declaring both
`host-only=on` and `back-invalidate=on`. QEMU must refuse to launch
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

Three shapes across its scenarios, all passthrough single-RP (the only
staging QEMU supports):

```
(a) cxl.1 ─ rp0 ─ vmem0 (x-committed=hdm-db | hdm-h)      per scenario
(b) cxl.1/cxl.2/cxl.3 ─ rp1/rp2/rp3 ─ vmem0/1/2           combined boot
(c) cxl.1 ─ rp0 ─ vmem0 ┐  x-committed-ways=2: a staged 2-way
    cxl.2 ─ rp1 ─ vmem1 ┘  committed interleave set
```

`x-committed` stages the endpoint HDM decoder committed (BI bit per
mode) and, for `hdm-db`, the endpoint BI Enable — the firmware
adoption entry state. nr_bi=1 at each RP above an `hdm-db` device
(adoption takes the refcount exactly like a fresh enable), 0 above the
`hdm-h` ones (no `hdm-db`, not BI-capable). Window variants (BI
present/absent) drive the adopt vs reject legs.

## t17 — QMP hotplug

```
rp0 ─ us0 ─ dsp0 ─ ep0 (sn=0x171, cold-plugged)
         └─ dsp1   (empty: hot-add target, sn=0x172)
         └─ dsp2   (empty: re-add target, sn=0x173)
```

BI setup driven by real pciehp events, with `rp0` aggregating:

```
                    rp0  dsp0  dsp1  dsp2
boot                 1     1     -     -
hot-add 0x172        2     1     1     -
hot-remove 0x172     1     1     0     -     survivor path stays enabled
hot-add 0x173        2     1     0     1
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
`x-bi-commit-fault=timeout` on the DSP: BI setup fails at boot and the
rollback returns every count to 0; an HDM-DB attach then fails closed
while a host-only region still commits on the same endpoint decoder.

## t22 — Unknown Supported Coherency Models

t1's direct-attach shape (`rp0` nr_bi=1) with `x-coherency-unknown=on`:
the endpoint advertises 00b in Supported Coherency Models (Table 8-116)
and must still commit into an HDM-DB region via the `cxlds->bi` gate.

## t23 — commit faults (multi-boot, host-driven)

t2's single-switch shape, re-launched per scenario with fault knobs:
`x-bi-commit-fault=error|timeout` on the DSP (BI Decoder commit) or
the USP (BI RT commit), `x-bi-committed=on` on the DSP (committed
decoder, uncommitted RT — the adopt-rt leg), and
`x-bi-commit-fault-after=1` (dealloc-time fault). Counts: the four
fault legs roll back to 0 everywhere (a failing level never
increments); adopt-rt and dealloc-err reach t2's steady state
(`dsp0`/`rp0` nr_bi=1) before their teardowns.

## t24 — firmware adoption (multi-boot, host-driven)

```
(adopt)      rp0 ─ mem0 (x-committed=hdm-db)      full firmware path
(fresh-dev)  rp0 ─ us0(x-bi-rt-committed) ─ dsp0(x-bi-committed) ─ mem0
(wrong-role) rp0 ─ us0 ─ dsp0(x-bi-committed!) ─ us1 ─ dsp1 ─ mem0
```

Adoption as a path property: a firmware-enabled direct-attach device
adopts with zero commit cycles; staged-committed dports under a device
firmware did NOT enable still owe their commits; a DSP that is Above
HBR USP but staged with the Above-SLD role (Enable) gets corrected to
Forward and committed. Counts: adopt `rp0`=1 (an adopted level still
takes nr_bi++, so teardown unwinds it like any other); fresh-dev
`dsp0`/`rp0`=1; wrong-role `dsp1`/`dsp0`/`rp0`=1. Each scenario's
unbind walks its counts back to 0.

## t26 — intentionally unused

Reserved for an HDM-D window suite (a CFMWS with bit[0]=1, bit[5]=0 via
`cxl-fmw.0.host-only=off`), which would cover the endpoint-vs-window
asymmetry in `cxld_set_type()`. Not buildable today: QEMU models only
`cxl-type3`, and HDM-D flows belong to Type 2 devices, so the window
would have no legitimate occupant. `x-committed` cannot stage such a
decoder either - it is binary, setting either the BI bit or the
host-only bit, never leaving both clear.

## t27 — BI across a device reset (two boots)

```
pxb-cxl (cxl.1)
└─ cxl-rp rp0            RP → Enable   nr_bi=1   (untouched by the reset)
   └─ cxl-type3 mem0     (hdm-db)      reset target
```

Direct attach so the device is connected directly to the Root Port and
the reset lands strictly below it - which makes "the endpoint's BI Decoder
was wiped while the dport above still points at it" directly
observable. Reset is issued through the kernel (`/sys/bus/pci/devices/
<ep>/reset`, method `cxl_bus`) rather than a raw setpci poke, so the
`pci_error_handlers` `.reset_prepare`/`.reset_done` path actually runs.
Boot 1 resets with nothing committed; boot 2 commits an HDM-DB region
first.
