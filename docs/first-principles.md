# CXL Back-Invalidate: first principles

The rules everything else in this repository and in the
`cxl-bi-support-v8` series follows. Each rule quotes the specification
extract at `~/prompts/CXL-BI.txt` verbatim, then states what Linux does
with it and which suite under `../topos/` proves it. Where Linux goes
beyond the letter of the specification, or stops short of it, the rule
says so.

The four rules that started this file, kept verbatim:

- A CFMW restrictions cannot have bit1 (HOST) and bit5 (BI) set.
- A CFMW restrictions cannot have bit0 (DEVICE) unset and bit5 (BI) set.
- A type3 device may only have HDM-H or HDM-DB coherency models.
- A type2 device may only have HDM-D or HDM-DB coherency models.

## 1. Coherency models and device classes

**Rule 1.1: three models, each bound to device classes.**
Spec, 3.3: "HDM-H (Host-only Coherent): Used only for Type 3 Devices";
"HDM-D (Device Coherent): Used only for legacy Type 2 Devices that rely
on CXL.cache to manage coherence with the Host"; "HDM-DB (Device
Coherent using Back-Invalidate): Can be used by Type 2 Devices or Type 3
Devices".
Linux: a Type 3 region is HDM-H or HDM-DB, a Type 2 region is HDM-D or
HDM-DB. There is no such thing as a Type 2 device running HDM-H; a
device brought up host-only is operating as a Type 3.
Tested: t26, t29, t30.

**Rule 1.2: the device says which models its decoders may be programmed
for, and that is a programming contract, not a class label.**
Spec, Table 8-116, Supported Coherency Models: "01b = Device Coherent.
The Target Range Type bit in an HDM decoder must be 0 when the HDM
decoder is committed; otherwise, the device behavior is undefined";
"10b = Host-only Coherent. The Target Range Type bit in an HDM decoder
must be 1 when the HDM decoder is committed; otherwise, the device
behavior is undefined"; "11b = Host-only Coherent or Device Coherent.
The Target Range Type bit in an HDM decoder is RW"; "00b = Unknown".
Linux: an HDM-DB or HDM-D region refuses a host-only HDM ("HDM is
host-only coherent"); an HDM-H region refuses a device-only HDM ("HDM
is device-coherent only"); Unknown is accepted on both paths because it
declares nothing. The driver never consults the device class directly;
this field and BI capability are the only inputs.
Tested: t4, t12, t20, t22, t26.

**Rule 1.3: HDM-DB is mandatory for 256B-flit devices, HDM-D is the
68B-flit compatibility path.**
Spec, 2.2.1: "HDM-DB support is required for all devices that implement
256B Flit mode, but the HDM-D flows will be supported for compatibility
with 68B Flit mode."
Linux: HDM-D regions are never created through sysfs; they exist only
when firmware committed one on a Type 2 device and the kernel adopts
it. A Type 2 that advertises HDM-D through the BI Decoder Capability
(Table 8-156 bit 0, "HDM-D Capable") is not yet consulted by the driver.
Tested: t30 (auto HDM-D), t26 (no create attribute on an HDM-D window).

**Rule 1.4: BI is optional for a Type 3 device.**
Spec, 9.14.3.3: "A BI-capable Type 3 device is required to operate
correctly when System Software has not enabled BI. In this case, the
device functionality that is dependent on BI will not be available."
Linux: a BI-capable Type 3 under a non-BI window commits a plain HDM-H
region with the endpoint decoder's BI bit clear, whatever the path's BI
state. BI setup itself is window-independent and still runs at probe.
Tested: t3, t14, t15.

**Rule 1.5: a Type 2 that cannot run HDM-DB or HDM-D falls back to
something else, by policy outside the kernel.**
Spec, 9.14.3.2 and Table 9-15: fallback to RCD, PCIe device, Type 1 or
Type 3 "based on the Fallback Capability field value", each by
"programming the DSP registers and issuing a Secondary Bus Reset".
Linux: none of these policies are implemented. A Type 2 whose region
cannot be assembled is left unassembled; its endpoint stays alive.
Tested: t27 accel scenario (nothing attachable after invalidation),
t30 refusals.

## 2. Windows (CFMWS Window Restrictions)

Spec, 9.18.1.3: "It is the OSPM's responsibility to adhere to these
restrictions. Failure to adhere to these restrictions results in
undefined behavior. More than one bit within this field may be set."
Bit 0: "Window is configured to expose device-coherent memory (HDM-D if
bit[5]=0; HDM-DB if bit[5]=1)." Bit 1: "Window is configured to expose
Host-only coherent memory (HDM-H). If an HDM decoder that is mapped to
this windows has the BI bit set (bit[5]=1), it will result in undefined
behavior." Bit 5: "Window is configured for use with Back-Invalidate
flows."

**Rule 2.1: a window sets bit 0 or bit 1, or it is not a window.**
Neither bit means the window is configured to expose nothing.
Linux: rejected at parse, "CFMWS has no coherency model". No emulator
builds such a window.

**Rule 2.2: bit 1 and bit 5 never coexist.** (Sacred rule 1.)
Linux: rejected at parse, "CFMWS cannot have both HDM-H and HDM-DB".
Tested: t13 (QEMU refuses it at launch).

**Rule 2.3: bit 5 requires bit 0.** (Sacred rule 2.)
HDM-DB is defined only as bit 0 together with bit 5.
Linux: rejected at parse, "CFMWS BI requires device-coherent".
Consequence: every BI window the kernel keeps exposes device-coherent
memory and nothing else, so every region under a BI root is HDM-DB.

**Rule 2.4: a window with both type bits exposes both models; nothing
mixes them within one interleave set.**
Linux: user-created regions are HDM-H there; auto-assembly admits a
committed HDM-H or HDM-D first member and then requires every later
member to match it.
Tested: t16 scenarios 8 and 9.

**Rule 2.5: creation follows the bits; assembly checks the bits.**
Linux: `create_ram_region` and `create_pmem_region` are visible only on
a host-only window or a device-coherent BI window, with the matching
volatile or persistent bit, so a user cannot place a region in a window
that forbids its type. Auto-assembly checks the first committed member
against the window on both axes, BI bit and range type, "coherency
model not permitted by the window".
Tested: t16 scenarios 4 and 5, t26, t30.

## 3. The link

**Rule 3.1: BI needs 256B flit mode on every link between device and
host.**
Spec, 9.14.1: "Back-Invalidate (BI) messages require the link to
operate in 256B Flit mode." 9.14.2: "System Software must ensure that
the device, the host, and any switch(es) in the path are capable of BI
and that the link(s) between the device and the host are operating in
256B Flit mode." 3.3.7 and 3.3.8: the BIRsp and BISnp message classes
are "not supported in 68B Flit mode".
Linux: every root port, downstream port and upstream port on the path
must report 256B flit, or the device is not BI-capable, `cxlds->bi`
stays clear, and an HDM-DB attach refuses with "BI not enabled on
device". HDM-H keeps working on the same device (rule 1.4).
Tested: t4; t7 and t8 SKIP on upstream QEMU, whose port flit knobs do
not reach the link status the kernel reads.

**Rule 3.2: when BI cannot be enabled, no decoder on the path may carry
the BI bit.**
Spec, 9.14.3.3: "The System Software shall ensure that the BI bit in
none of the HDM decoders in the device, the switch, or the host that
spans the device's HDM is set", and "the BI bit in the CXL BI Decoder
Control register in the device, as well as the Downstream Port it is
connected to, is programmed to 0."
Linux: the endpoint decoder's BI bit is set at commit only for a
device-coherent decoder in a region under a BI root on a device with
BI enabled; a committed decoder found with BI set on a path that cannot
do BI is refused at enumeration, "path not BI capable".
Tested: t16, t24.

## 4. Capabilities, roles and identity

**Rule 4.1: capability is advertised by structure presence.**
Spec, 9.14.1: "The presence of the CXL BI Decoder Capability structure
indicates that the component is capable of supporting BI." 9.14.2:
"BI-capable Downstream Ports and devices advertise the CXL BI Decoder
Capability structure." The route table is optional: "The USP in a
BI-capable Switch may advertise the CXL BI Route Table capability
Structure."
Linux: the endpoint, every root port and downstream port on the path
must carry the BI Decoder capability; an upstream port needs only flit
mode, its route table being optional.
Tested: t2, t6, t9, t25.

**Rule 4.2: Enable means adjacency, Forward means transit, never both.**
Spec, Table 8-157, BI Enable: "DSP or Root Port: If set to 1, indicates
a BI-capable device is connected directly to this Downstream Port."
BI Forward: "DSP or RP: Controls whether BI messages are forwarded."
Table 9-13, Enable=1 with Forward=1: "Discard (Invalid setting)".
Linux: the role of a dport is decided by position, not port type. A
root port with the device directly below it takes Enable; a root port
above a switch takes Forward; the downstream port adjacent to the
device takes Enable; every downstream port above that takes Forward.
Tested: t1 (RP Enable), t2 (DSP Enable, RP Forward), t9 and t25
(transit DSPs Forward at two and three levels).

**Rule 4.3: identity is the bus number.**
Spec, 9.14.2: "The BI-ID of a device must be unique within a VH. This is
ensured by using the device's Bus Number as the BI-ID." Table 9-13,
DSP: "Set BI-ID=Secondary Bus Number and forward upstream". Table 7-97,
HBR USP below RP or PBR/HBR DSP: "BI-ID[7:0] contains BusNum";
"Above HBR USP": "Propagate BI-ID".
Linux: nothing to program; the identity falls out of PCI enumeration.
The consequence is rule 4.5: bus number reassignment below a port
obliges a recommit.

**Rule 4.4: BI works at any switch depth.**
Spec, Table 7-97: a DSP "Above HBR USP" propagates BI-ID in both
directions; a DSP "Above SLD" stamps it.
Linux: the enable walk visits every dport from the device up to the
root port, whatever the depth, and every level is refcounted (rule 5.2).
Tested: t9 (two levels), t25 (three levels).

**Rule 4.5: explicit commits are per-port contracts.**
Spec, Table 8-156, Explicit BI Decoder Commit Required: "software must
set the BI Decoder Commit bit whenever a new BI device is enabled
anywhere below this port or any component below this port undergoes
bus number reassignment." Table 8-152 says the same for the route
table. Table 8-157: "Software must not set this bit unless the Explicit
BI Decoder Commit Required bit is set."
Linux: one commit edge per device enabled, at every port that requires
it, both when a device is enabled and when it is released; a port that
does not require it is never asked to commit.
Tested: t23, t24, t25.

## 5. Bringing BI up and down

The specification's own sequence, 9.14.2 implementation note: verify
256B flit on all links (1), a valid bus number (2), adjacent DSP
"BI Forward=0. BI Enable=1" (3), commit the DSP if required (4), commit
the USP route table if required (5), then the root port "If BI
Forward=0, set BI Forward=1. Ensure BI Enable=0" (6), then the device
"BI Enable=1" (7), then "inform the device driver that Device D may now
issue BI requests" (8). Deallocation runs it backwards, device first.

**Rule 5.1: the device is enabled last and disabled first.**
Spec, allocate step 7 and deallocate steps 1 and 2.
Linux: the path is programmed bottom-up and the endpoint's BI Enable is
written only after every dport committed; on release the endpoint is
disabled before any dport is touched, and the region's decoders are
reset before BI is deallocated.
Tested: t2 phases 2 and 3, t18.

**Rule 5.2: a shared dport is released by the last device, not the
first.**
Spec, deallocate step 6: stop forwarding at the root port only "if
... no other devices in this VCS have been assigned a BI-ID".
Linux: every dport carries `nr_bi`; enable increments, release
decrements, and Forward or Enable is cleared only at zero. The count
survives any number of siblings.
Tested: t5 phase 2 (two), t31 (eight, seven releases), t25 (shared
transit DSP).

**Rule 5.3: a failed commit fails the whole enable, and only fully
enabled levels are unwound.**
Spec, steps 4d-4f and 5d-5f: "BI Decoder Error Not Committed=1 ...
Software should treat this as an error condition"; "If neither bit is
set and the timeout is reached, Software should treat this as an error
condition."
Linux: Error Not Committed or a timeout at any level fails BI setup
cleanly, the endpoint stays alive with `back_invalidate=0`, and the
rollback decrements only the levels that completed; the failing level
never took the reference.
Tested: t21, t23.

**Rule 5.4: a firmware-enabled path is adopted as a whole, and only
then.**
Spec, Tables 8-152 and 8-156: a commit is owed "whenever a new BI
device is enabled anywhere below this port". A path firmware already
enabled and committed owes nothing.
Linux: adoption is a path property. The seed is the endpoint's BI
Enable; when it is set, committed dports above are adopted with zero
commit cycles and untouched registers. A device firmware did not enable
declines staged dport state and runs its own commits; a dport staged
with the wrong role for its position is corrected; an uncommitted
route table breaks adoption at that level and forces the commits above
it. Adoption still takes the reference count, so teardown unwinds it
like any other enable.
Tested: t16 scenarios 1 and 2, t24.

## 6. HDM decoders

**Rule 6.1: the BI bit lives on device-coherent decoders only.**
Spec, Table 8-157, device BI Enable: "the device is allowed to generate
BISnp requests to addresses covered by any of its local HDM decoders
with BI=1". Table 9-13, Enable=1: "Locate the HDM decoder in the USP or
RC that decodes the BISnp address. Verify that the BI bit in that HDM
decoder is set." Rule 2, bit 1: a BI decoder in a host-only window is
undefined behaviour.
Linux: BI is programmed at commit only when the decoder's Target Range
Type is device-coherent and the region sits under a BI root; switch
and host-bridge decoders serving that region get the bit too, so the
DSP's check in Table 9-13 passes. A committed decoder found with BI set
and Target Range Type host-only is refused at enumeration, "BI with
host-only".
Tested: t2 (USP decoder BI by readback), t9, t16 scenario 5.

**Rule 6.2: a committed decoder cannot inherit; it must already match.**
Linux: a user-created region's decoders inherit the region's type at
attach and are programmed at commit. A decoder firmware committed is
neither reprogrammed nor retyped: at attach its committed range type
must equal the region's and its committed BI bit must equal the root's,
"coherency model mismatch: <committed> vs <region>". The kernel keeps
the range type as software state derived from the register at
enumeration; the BI bit it reads back from the register, having no copy
of its own.
Tested: t16 scenarios 8 and 9.

**Rule 6.3: an interleave set shares one model.**
Every member of a region carries the region's type and, under a BI
root, the BI bit. A set can mix Type 2 and Type 3 devices as long as
they agree on the model.
Linux: manual sets refuse a non-BI or host-only device (rules 1.2 and
3.1); auto sets refuse a mismatched member (rule 6.2).
Tested: t12, t20, t29, t31-t33.

## 7. Resets

**Rule 7.1: BI control state does not survive a reset of the
component that holds it.**
Spec, Table 8-157: BI Forward and BI Enable each have "Reset default
value is 0."
Linux: after a Secondary Bus Reset below a dport, the device's BI
Enable is gone while the dport above keeps its programming and its
reference. `.reset_done` compares the kernel's `cxlds->bi` with the
register and fails closed, "BI disabled by reset": an HDM-DB attach
refuses until a rebind re-runs the enable path from scratch, and the
unbind still unwinds every dport despite the invalidated flag. A
committed decoder wiped by the reset ends its region. A Function Level
Reset that preserves the component registers changes nothing and is
left silent.
Tested: t27.

**Rule 7.2: error recovery that bounces the driver brings BI down
orderly and up again from scratch.**
Linux: AER fatal-error recovery never runs the reset handlers; the
driver bounce releases BI through devres, decoders first, and the
slot-reset reattach re-runs the enable path. A live user-created region
is detached and decommitted, never deleted.
Tested: t28.

## 8. Where Linux stops

- The HDM-D Capable bit (Table 8-156 bit 0) is defined but not consumed.
- Type 2 fallback modes (Table 9-15) are policy the kernel does not
  implement.
- Root-port BI-ID checks are "host proprietary mechanisms" (Table 9-13)
  and are not modelled.
- Target Range Type read-back after commit, the device-side half of
  rule 1.2, is not verified by the driver.
- A committed mixed Type 2 and Type 3 HDM-DB set (rule 6.3, auto path)
  rests on code reading; no emulator stages it.
