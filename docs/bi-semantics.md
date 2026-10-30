# Back-Invalidate path semantics: from no firmware involvement to all of it

What the driver does with the BI path of a device, for every degree of
firmware involvement: nothing programmed by firmware, parts of the path,
the whole path, and the whole path plus decoders the driver can never
take down. Each row of the table at the end names the suite that proves
it, and says which columns the suite does not assert. Everything here is
the behaviour of the v10 series; "spec" means CXL 4.0.

## 0. Terms

- A *level* is one downstream port on the device's path, a DSP or the
  root port, with its BI Decoder control register (Table 8-157) and, for
  a DSP, the BI route table (*RT*, Table 8-151) of its switch. The
  level directly above the device is *adjacent* and takes **Enable**;
  every level above it is a *transit* and takes **Forward** (Table
  9-13). A level is *up* when either bit is set.
- A *binding* is one bind of the endpoint port driver to the device.
- *Staged* means programmed and committed by firmware before the driver
  ran. QEMU can stage DSPs, route tables and the device, but not a root
  port; where a scenario stages an RP it writes it from the guest before
  the bind.
- *Committing* a level is the explicit commit sequence of 9.14.2 steps
  4-5 (Commit written, Committed polled), run only where the capability
  advertises Explicit Commit Required (Tables 8-152, 8-156); a level
  that does not require it, every root port included (the bit is
  reserved there), counts as committed.
- *Release* is the one routine run at unbind and on a failed walk; the
  table's Unbind column is release at unbind. Quoted strings are the
  driver's dmesg lines; apart from "BI already disabled in hardware"
  (error), "BI disabled by reset" (warning) and the commit-wait errors
  ("BI-ID commit rejected by hardware", "BI-ID commit timed out"), they
  are debug lines, visible with dynamic debug on cxl_core.
- A *locked* decoder has Lock On Commit set (Table 8-123 bit 8) and is
  read-only once committed; a *locked region* is one assembled on a
  locked decoder, which the driver never resets.

## 1. The rules

Three rules decide everything below.

1. **A level is cleared only if this driver brought it up from zero and
   has not since held it.** A dport found with Enable or Forward already
   set while nothing this driver counts is routed through it
   (`nr_bi == 0`) is *held*: the driver never clears it, for the dport's
   lifetime. It does not matter who set it, firmware or a previous
   binding of this driver; the register is not this binding's to take
   down. A level is also held once a device below it is torn down while
   still decoding with BI (rule 2). (Code: `bi_held`, set in
   `cxl_bi_ctrl_dport_enable()` when `nr_bi == 0` and the register is
   up, and in `cxl_bi_ctrl_dport_disable()` when the device below is
   live at teardown; never cleared.)

2. **The device keeps BI Enable while one of its HDM decoders still
   decodes with BI.** At release the driver reads the device's HDM
   decoders from the hardware. If decoding is enabled globally, the
   device is reachable (the register does not read all ones), and any
   decoder is committed with its BI bit set, that range is still
   configured for device-managed coherence (Table 8-123 bit 13), and BI
   Enable is the device-wide permission that lets the device snoop it
   (Table 8-157); clearing it would leave a decoding HDM-DB range unable
   to issue BISnp, and a level with neither Enable nor Forward would
   discard one anyway (Table 9-13). So at teardown the device keeps its
   Enable and every level on its path is held. Otherwise the Enable is
   released by the binding that holds it, whether firmware or the
   driver set it. A failed walk never holds (section 4). (Code:
   `cxl_hdm_bi_live()`, `cxl_bi_release()`.)

3. **A commit is owed when a level's BI-ID assignments change, never per
   register write.** Once for each device newly enabled below the level
   (allocate; Tables 8-152, 8-156), and once when its last device is
   unassigned and the role bits cleared (deallocate; 9.14.2 steps 3-5).
   Every DSP decoder and every switch route table on the path is
   committed for each device the driver takes up through it, unless the
   level is *adopted* (2.2). A role correction is committed because a
   new device was enabled below, not because of the write. A held level
   reaching zero is not committed: nothing was unassigned, and the
   deallocate sequence is an implementation note. Root ports never
   commit.

Rule 1 is about *levels*, rule 2 about the *device*, and they are
deliberately different. A level is shared: its committed state does not
say which device it was committed for, and a dport re-created after its
switch port was reaped cannot know whether a device below still decodes,
so the driver can never prove a level it found up is safe to clear. The
device's Enable is not shared: every HDM decoder behind it belongs to
this device and is read by this driver at release, so it can prove
nothing is live before clearing it, whoever set it.

## 2. The bind walk

`cxl_bi_setup()` runs at endpoint port probe, before the device's
decoders are enumerated and regions assembled, and walks the dports from
the device upward (9.14.2 allocate order):

- the adjacent level takes Enable, every transit Forward, at any switch
  depth;
- at each level: read the control register; if `nr_bi == 0` and the
  register is up, **hold** it (rule 1); decide adoption (2.2);
  otherwise write the role if it differs, and **commit** the DSP decoder
  and the switch's route table (rule 3); count the device (`nr_bi++`);
- last, set the device's BI Enable, or take it as found if already set
  ("adopting firmware-enabled BI"). That line is about the device's own
  register only; which levels above were adopted is shown by the commit
  count and the register readbacks, not by it.

A failed commit at any level restores that level's previous value,
commits the restore if a value was written, and unwinds (section 4).

`nr_bi` counts, per dport, the endpoints this driver has taken up
through it, adopted or programmed. It is what keeps a shared level up
while any such endpoint is bound, and it is the only thing that can
clear a level: at zero, and only if the level is not held.

### 2.1 Capability

The walk runs only in VH mode (never for an RCD) and only if the device,
its root port and every DSP on the path carry a BI Decoder capability,
every link up to the root is in 256B Flit mode, and every USP either
advertises no BI route table or had it mapped (9.14.2). Otherwise BI
stays off for the device and an HDM-DB region is refused at attach
("BI not enabled on device"). Firmware Enable/Forward bits on such a
path are not cleared (9.14.3.3 is not implemented). An HDM decoder that
firmware committed with BI set on such a path, or with BI and a
host-only target type, is refused at enumeration ("path not BI
capable", "BI with host-only") and the endpoint port probe fails with
it; untested.

### 2.2 Adoption

Adoption means taking a level as firmware left it: no write and no
commit. It is seeded from the device's own BI Enable: only a device
already enabled can have had its BI-ID accounted for by the committed
state above it. A level is adopted when all of these hold:

- the device's BI Enable was already set when the walk started;
- nothing is counted through the level yet (`nr_bi == 0`);
- the register already has the role this walk would write;
- the level's BI Decoder reads committed, and the switch's route table
  too if the USP has one. A level that does not require an explicit
  commit passes by construction; a root port always does, so an RP that
  already holds the right role is adopted whenever the levels below it
  were.

The decoder and its switch's route table are one test: an uncommitted
route table fails the DSP below it. Adoption is a prefix of the path:
the first level that fails any test ends it, and from there up the
driver programs and commits as for a new device. An adopted level was
found up, so it is also held (rule 1).

## 3. Release

One routine, `cxl_bi_release()`, serves both teardown (devres of the
endpoint port, after regions are detached, which resets their decoders
unless the region is locked, and the decoder devices are unregistered; a
committed decoder that was never in a region is not written) and the
unwind of a failed walk:

1. read whether a decoder still decodes with BI (rule 2);
2. the device: release its Enable if this binding holds it and nothing
   is live; otherwise leave it. If the hardware already reads clear, the
   disable reports "BI already disabled in hardware" and the binding's
   claim is dropped anyway;
3. each level up the path, in the deallocate order of 9.14.2: drop this
   endpoint's count; if the device is live and this binding took its
   BI up, hold the level; at zero,
   clear the role bits and commit, unless the level is held. A commit
   fault here is reported by the commit wait, the disable failure
   itself only at debug level ("BI dport disable failed"), and the walk
   continues: teardown always completes.

A held level is never cleared again for the dport's lifetime, even after
the decoder that justified it is gone (a reset or removal of the
device). The leftover permission is harmless for routing: with no device
below entitled to issue BISnp nothing is forwarded, and a device enabled
below later is still committed for (Tables 8-152, 8-156). It does leave
the deallocate steps 3-5 undone for that level (an implementation note,
not a requirement), and leaves a DSP Enable that 9.14.3.3 would want
cleared if a non-256B-Flit device were later plugged below it; neither
is handled.

Switch ports and their dports are deleted when their last endpoint
detaches and re-created when one returns; the host bridge's survive. A
re-created dport carries no memory, which is why the hold is taken from
the register whenever the count is zero (rule 1) rather than remembered.

## 4. A failed walk

The unwind releases the levels the walk took a reference on, below the
level that failed. A level brought up by this walk is cleared; a level
found up (adopted, or found up but not adoptable) is held and left as
the walk left it: as found when the role was already right, or with the
corrected role when the walk rewrote it (row 2). Only the level whose
own commit failed is restored to its previous value. The device is
never touched: its Enable is the last step of the walk and was not
reached. This holds even if the device already decodes with BI (a
firmware-committed decoder): an unwind never holds a level for it,
since the walk failed before the device's BI was taken up and no path
is left to keep. Setup fails, the probe continues with BI off, no release
action is registered, an HDM-DB attach is refused, and a rebind runs the
walk again from the same state.

## 5. Reset

`.reset_done` reads the device's BI Enable: if this binding holds BI and
the register reads clear, a reset wiped it and `cxlds->bi` is
invalidated: an HDM-DB attach or region commit is refused, nothing is
re-enabled, and a rebind recovers by walking the path from scratch (the
device's Enable is clear, so nothing is adopted). The driver does not
ask which reset ran: an SBR wipes the register (Table 8-157 reset
default); on QEMU an FLR preserves it; the t27 flr leg checks only that
the warning tracks the hardware, and flr-region additionally asserts
that the register, the region and the decoder survived. The read is taken only while the
endpoint port is held with its driver bound, since an unbind of that
port alone releases the mapping. Dports above the reset boundary keep
their programming and their counts; the unbind that follows drops every
count, clears the levels this driver brought up and keeps any held
level.

A region commit also re-reads the device's Enable from the hardware
after programming each target, since a reset may not have reached
`.reset_done` yet ("BI disabled by reset during commit", the target is
undone).

## 6. The spectrum

Columns: what firmware left; what the bind walk does; what release does
at unbind; what the rebind after that unbind does; which suite proves
it, and which columns it does not assert ("code-derived" means the
cell follows from the rules above but no suite reads it back). "Kept"
means left as found; "cleared" means role bits cleared and, on a DSP,
committed. Levels marked (RP) in a switch-shaped t24 scenario were left
clear because QEMU cannot stage a root port, so the driver writes them.

| # | Firmware left | Bind | Unbind | Rebind | Proof |
|---|---|---|---|---|---|
| 0 | Nothing: every level 0, device Enable 0, no committed decoder | Every level written and committed, device enabled ("BI requests enabled") | Device released ("BI requests disabled"), then every level cleared at zero | As bind | bind: t1, t2, t5, t9, t25 deep, t31–t33; unbind/rebind: t2 unbindrebind/lifecycle, t5 nrbi/mtunbind, t9 cascade, t25 shared, t31 (device-before-levels order not asserted) |
| 1 | Levels staged (DSP Enable committed, RT committed), **device Enable 0** | Levels found up: held; adoption declined (device not enabled); no write where the value is right; DSP decoder and RT committed for the new device; device enabled by the driver | Device released; staged levels kept as found, no dealloc commit; levels the driver brought up from zero (the RP) cleared | As bind | t24 fresh-dev (bind; unbind: device disabled, DSP kept, no dealloc commit; RP not read back, rebind not asserted), t23 adopt-rt (bind only; the RT is left uncommitted there, which changes nothing since adoption is declined on the device's Enable alone; its "adopted path" wording means the staged path, nothing is adopted) |
| 2 | A transit DSP staged with the **wrong role** (Enable where Forward belongs) | Found up: held; corrected to Forward and committed. A DSP with Enable set stamps BI-ID = its own secondary bus number (Table 9-13), which on a transit would mislabel the device's BISnp and misroute the BIRsp (Table 7-97); 9.14.2 gives Enable only to the adjacent port | Device released; the corrected level kept with the corrected value; the adjacent DSP and RP, brought up from zero, cleared | Transit found with Forward: no write, commit owed; adjacent rewritten; device enabled by the driver | t24 wrong-role (bind only; unbind and rebind code-derived) |
| 3 | Device Enable set, **part** of the path committed (the adjacent switch's RT not) | Nothing adopted: the adjacent level fails on its uncommitted RT, so the adjacent DSP (value right, no write) and inner RT are committed, then the transit DSP and outer RT although staged correctly (4 commits, not 2), then the RP written Forward; device taken as found | Device released if nothing decodes with BI; both DSPs kept (found up, held, although the walk committed them); the RP cleared | As row 1: the device's Enable was released, nothing is adopted | t24 fw-partial (bind: commit count >= 4 and the transit commit; the RP write and the device adoption are not read back; unbind and rebind code-derived) |
| 4a | Device Enable set, **whole path** committed, RP included (direct attach) | Adopted end to end: zero commits, nothing written | Device released if nothing decodes with BI; the RP kept (found up) | As row 1: RP found up and held, not written; device enabled by the driver | t24 fw-whole (bind and unbind; rebind code-derived) |
| 4b | Device Enable set, both **switch levels** staged, RP clear | Both switch levels adopted; the RP written Forward (an RP never commits): zero commits | Device released if nothing decodes with BI; switch levels kept (found up); the RP cleared | As row 1 | t24 fw-path (bind only; the RP write not read back; unbind and rebind code-derived) |
| 5 | Two firmware-enabled devices **sharing a level** | Each adopts its own staged levels. If the shared level is a clear RP, the first writes it and the second finds it counted: zero commits. If it is a staged transit DSP, the first adopts it and the second is refused there (counted) and commits from that level up: that DSP's decoder and its switch's RT, and the same again for every transit above it (none in t24's shape, so exactly two commits) | Each device released; a shared transit found up is kept; a shared RP the driver wrote is kept while the other is bound and cleared when the last leaves | As row 1 for each device | t24 fw-shared-rp, fw-shared-dsp (bind only; the RP is not read back in either; unbind and rebind code-derived) |
| 6 | Device Enable set and a **committed BI decoder** that assembles into a region, RP clear (direct attach) | RP written Enable (no commit); device taken as found | Region detached and its decoder reset, so nothing decodes with BI; device released ("BI requests disabled"); RP cleared | As row 0: Enable released and decoder reset, nothing adopted | t24 adopt (bind and unbind; rebind code-derived), t16 bi (bind; its reboot leg is a fresh boot, not a rebind) |
| 7 | A committed BI decoder that **never joins a region** (window refuses it, or an interleave peer never arrives) | As row 6 | The decoder stays committed: device **keeps** Enable, every level held | Adopted, zero commits | t24 fw-orphan (window refuses the decoder: adopted, no region; the unbind keeps BI Enable and holds the RP the walk brought up from zero; the rebind adopts and writes nothing); t16 orphan (an interleave peer that never commits: the auto region waits, the decoder keeps its type after the region is deleted; its unbind is not asserted); t16 neg, mixed (refusals, endpoint survives) |
| 8 | A committed BI decoder that is **locked**, or in a locked region, whole path staged | As row 4a: adopted end to end, nothing written | Nothing can reset it: device keeps Enable, every level held; no "BI requests disabled" | Adopted again, zero commits, region still locked | t24 fw-locked (direct attach), fw-switch-locked (switch; zero commits asserted at the rebind only, the first bind checks the device line and the locked decoder; region still locked after rebind asserted there; endpoint and RP read back after unbind, DSP and RT not) |
| 9 | Row 8 with a **driver-enabled sibling** under the same switch, RP staged | Sibling programs and commits its own DSP and the switch's RT; the shared RP counted, not written | Sibling leaving first: shared RP kept (count 2 → 1); locked device leaving last: RP kept (found up; the live hold would also keep it, as t24 fw-orphan and t17 locked-remove show on levels brought up from zero). Locked device leaving first is code-derived | As row 0 for the sibling, adopted for the locked device | t24 fw-switch-locked (one leave order; the sibling's DSP/RT commits are not counted and its rebind not asserted; the RP reads back Forward, which cannot distinguish "not written" from a same-value write) |
| 10 | Row 8 behind **nested switches**, both devices unbound so the switch ports are deleted | — | Sibling's unbind leaves the transit up for the locked device | On the sibling's rebind the re-created transit dport is found up and held again, so its next unbind still leaves the locked device's path up | t25 nested-hold |
| 11 | Any of the above, then an **SBR** of the device (reset event in the Unbind column) | — | `.reset_done`: "BI disabled by reset", BI invalidated; attach and commit refused; unbind drops every count, clears the levels this driver brought up and keeps any held level | From scratch: nothing adopted | t27 no-region, switch, adopt-reset, accel; t34 arm 3; t27 held-reset (a held level across a reset: kept at the unbind, committed again on the rebind); t27 switch-sbr (a reset above a switch: the switch's BI Decoder and Route Table wiped with the device, unwound at the unbind, programmed from scratch on the rebind) |
| 12 | Any of the above, then an **FLR** | — | Whatever the FLR preserved stays; the register is re-read and nothing is invalidated unless it reads clear | — | t27 flr (warning tracks the hardware), flr-region (QEMU preserves the register) |
| 13 | A **commit fault** at some level during bind | Unwind: levels brought up by the walk cleared, even when the device already decodes with BI; found-up levels held and left with the role the walk gave them (as found, or corrected); device untouched; setup fails (logged, probe continues), BI off, HDM-DB attach refused | Nothing to release: no release action was registered | The walk runs again | t23 dsp-err/rt-err/dsp-tmo/rt-tmo (setup refused, bi=0), t25 rollback/shared-rollback (levels brought up cleared), t25 adopt-rollback (adopted level kept, RP never reached), t25 live-rollback (a live decoder does not make the unwind hold), t21 (attach refused); a found-up but not adopted level in an unwind is untested |
| 14 | A **commit fault during release** | — | Best effort: the clear is written, the fault logged ("BI dport disable failed"), the walk continues up and teardown completes | As bind | t23 dealloc-err (diagnostic and teardown completion; the written clear is not read back, the rebind is code-derived) |
| 15 | Device Enable **cleared behind the driver** without a reset (firmware, another agent, /dev/mem) | — | Release finds the hardware already clear ("BI already disabled in hardware"), still drops every count; a region commit re-reads the device and refuses ("BI disabled by reset during commit") | From scratch | t34 arms 2 and 4 (the count drop is not read back on the RP: code-derived) |
| 16 | A device whose path is **not BI capable** (no 256B Flit, no BI Decoder) | No walk; BI off; HDM-DB attach refused. A firmware-committed BI decoder on such a path fails the endpoint probe (2.1) | Nothing to release | — | t4 (no BI Decoder on the device), t35 (68B USP); t7/t8 (68B RP/DSP) SKIP on QEMU, whose flit knob does not reach LnkCtl2 |
| 17 | **Hot-add / hot-remove** through pciehp | Hot-add: as row 0 for the new device | Orderly hot-remove: the region is detached and its decoder reset before release, so the device is disabled, the levels it alone held cleared, shared ones counted down. A removed device whose decoder is locked holds its levels: no disable, its adjacent DSP kept at Enable. Surprise removal reads all ones and is never live | Add after remove is a hot-add | t17 (device disable, the survivor's region and add-after-remove; the removed device's DSP and the shared levels are not read back, so the clearing and count-down are code-derived); t17 locked-remove (live decoder: no disable, adjacent DSP held at Enable, survivor commits) |

## 7. What is never done

- A level found up, or held for a live device, is never cleared, then
  or later.
- BI is never re-enabled after a reset wiped it; a rebind does that.
- A root port is never committed (Table 8-156).
- Bus number reassignment below a port is not detected; adoption
  presumes the bus numbers firmware committed for are unchanged.
- Firmware BI bits on a path that is not BI capable are not cleared
  (9.14.3.3).
- The device driver is not notified before BI is taken down (9.14.2
  deallocate step 1); for a Type 3 device this driver is that driver.

## 8. What the suites cannot show

Upstream QEMU does not implement Lock On Commit: writes to a locked
decoder land. The suites were last run on QEMU with Lock On Commit
enforced (a committed, locked decoder drops every write to its
registers; "hw/cxl: Enforce Lock On Commit on HDM decoders", not yet
upstream), so the locked rows pass both because the driver never writes
a locked decoder and because the emulated decoder refuses it. On
upstream QEMU only the former is shown. QEMU also returns zero, not all
ones, for a removed device, so the surprise-removal branch of the live
check is untested. Every cell marked code-derived above is backed only
by the rules and ad-hoc runs on the QEMU knobs, not by suites.
