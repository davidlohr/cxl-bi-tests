# CXL Back-Invalidate on Type 3 hardware: test plan

Validation plan for the BI series (`cxl-bi-support-v8`) on **Type 3
memory expanders that support Back-Invalidate** (devices that can
operate HDM-DB).

Companion to the QEMU suites in `topos/` (see `../README.md`) and the
`cxl_test` mock in `tools/testing/cxl/`. Those exercise the driver's
logic exhaustively against emulation; this plan covers what emulation
cannot answer and re-confirms the emulated invariants on silicon.

**Scope.** Type 3 + BI only. Type 2 (HDM-D/HDM-DB accelerators) is out
of scope — no known Type 2 + BI hardware exists — and stays with QEMU's
`cxl-accel` (t26/t29/t30) and the mock. A missing Type 2 result is not
a gap. (Note HDM-D is a Type 2 flow that needs no BI at all, per
CXL-BI.txt §2.2 lines 53-57 — do not read this plan's BI focus as
covering HDM-D.)

**Phase order is deliberate.** Phase G (resets) and the memory-online
steps are destructive; they are ordered so that no phase bricks the
setup for a later one. Read §3.4 before starting.

---

## 1. What BI is *for* on a Type 3 device

HDM-DB gives the device a dedicated S2M **BISnp** channel to snoop the
host (CXL-BI.txt §2.2.1):

> "the protocol enables channels in the CXL.mem protocol that allow
> direct snooping by the device to the host using a dedicated
> Back-Invalidate Snoop (BISnp) channel... the coherence flows to the
> host for the HDM-DB must only use the CXL.mem S2M BISnp channel and
> not the D2H CXL.cache Request channel."

For a memory expander this matters when device-side content changes
**without host involvement** — ranged sanitize/zero via Media
Operations, and shared/multi-host coherent memory (GFAM). Phase A is
honest about which of those are drivable from in-tree software.

Also (CXL-BI.txt §2.2.1): "HDM-DB support is required for all devices
that implement 256B Flit mode" — so a 256B-flit Type 3 device that does
*not* advertise the BI Decoder Capability is itself a finding.

---

## 2. What only real hardware can answer

Ordered by risk retired.

| # | Question | Why QEMU can't answer it |
|---|---|---|
| 1 | Does a BISnp actually invalidate a host-cached line? | QEMU never generates a BISnp — it models registers, not the CXL.mem protocol. **No test to date exercises coherency itself.** |
| 2 | Real BI-ID commit latencies (switch topologies only — see §6) | Commit timeout scale/base are HwInit fields read from the device; QEMU's are invented (~200 ms). |
| 3 | Does a real switch BI Route Table behave as the driver assumes? | The QEMU switch implements the driver's own reading of the spec. Circular. |
| 4 | Does Alternate Protocol Negotiation land in 256B flit, read correctly? | QEMU's flit mode is a device property, not a negotiated outcome. |
| 5 | Do real FLR/SBR preserve or wipe the CXL.cache/mem registers as modelled? | QEMU's reset register behaviour was written to match the driver. Circular. |
| 6 | Does firmware pre-enable BI / pre-commit decoders (adopt path)? | QEMU stages this artificially. Real BIOS behaviour unknown. |

---

## 3. Prerequisites

### 3.1 Hardware

Minimum:

- Host with CXL 3.x+ root ports supporting BI.
- **Type 3 memory expander advertising the BI Decoder Capability**
  (component register block capability ID `0xC`) capable of HDM-DB.
- Endpoint link negotiated to **256B flit** (§7 otherwise).
- Platform firmware publishing a CFMWS restricted to **Device-Coherent
  + Back-Invalidate + Volatile (and/or Pmem)** — this is the HDM-DB
  window (CFMWS bits 0+5+volatile/pmem). Without it there is no HDM-DB
  region and most of this plan is unreachable. A device-coherent
  window *without* bit 5 is HDM-D, not HDM-DB — not what this plan
  needs.

Extended (each adds a phase):

- **CXL switch with BI** (BI Route Table on the USP) → §6 commit-latency
  data, §12. **Required for any commit-latency result** (see §6).
- **≥2 endpoints under one switch/RP** → shared-dport refcounting (§9.4).
- **Second BI device** → interleaved x2 HDM-DB regions (§6).
- **A device with a media-modifying path** (Media Operations 4402h,
  GFAM/multi-host, P2P/UIO, or vendor DMA) → §4, coherency. **Confirm
  this exists before scheduling hardware time.**

### 3.2 Kernel

- Branch `cxl-bi-support-v8` (or the posted series).
- `CONFIG_CXL_BUS`, `CXL_PCI`, `CXL_ACPI`, `CXL_MEM`, `CXL_PORT`,
  `CXL_REGION`.
- **`CONFIG_DYNAMIC_DEBUG`** — mandatory; almost every BI trace point
  is `dev_dbg` emitted at *probe* (§3.3).
- `CONFIG_DEV_DAX`, `CONFIG_DEV_DAX_KMEM`, `CONFIG_DEV_DAX_HMEM` for the
  dax/system-ram steps in §4.
- `CONFIG_ACPI_APEI_EINJ` for §8 error injection.
- `CONFIG_PROVE_LOCKING` + `CONFIG_DEBUG_KERNEL` for §9-§10.
- `CONFIG_KASAN` for the soak (§11).

### 3.3 Observability — enable BI trace *at boot*

The BI enable path, capability discovery, and adopt logic log through
`dev_dbg` **during probe**, before userspace runs. A runtime `echo`
into `dynamic_debug/control` is too late and would make Phase B report
false failures on a healthy machine. Set on the **kernel command
line**:

```
cxl_core.dyndbg=+p cxl_port.dyndbg=+p cxl_pci.dyndbg=+p cxl_acpi.dyndbg=+p
```

Re-arm at runtime only to recover trace after a `dmesg -C`:

```sh
for m in cxl_core cxl_port cxl_pci cxl_acpi; do
    echo "module $m +p" > /sys/kernel/debug/dynamic_debug/control
done
```

> Match on `module`, not `file` — file-path matching fails on
> wrapped/out-of-tree builds.

Sysfs surface:

| Path | Meaning |
|---|---|
| `decoder0.N/cap_back_invalidate` | root decoder: CFMWS BI restriction (HDM-DB window) |
| `decoder0.N/cap_type2` | root decoder: window permits device-coherent |
| `endpointN/decoderN.0/back_invalidate` | endpoint decoder operating HDM-DB (device BI enabled **and** attached to a DEVMEM region under a BI window) |
| `endpointN/decoderN.0/target_type` | `expander` (host-only) or `accelerator` (device-coherent) |

Driver strings used as pass/fail (verbatim; **dbg** needs §3.3):

```
found BI RT capability (0x...)      dbg   switch USP route table found
BI requests enabled|disabled        dbg   device BI Enable written
adopting firmware-enabled BI        dbg   adopt path taken
BI-ID commit wait took %lluus       dbg   per-level commit latency (switch only)
Invalid BI commit timeout: scale=%u base=%u  dbg  HwInit fields absent -> 5s fallback
BI-ID commit timed out (%luus)      ERR   commit did not complete
BI-ID commit rejected by hardware   ERR   commit error status
BI not supported by topology        dbg   a level above the endpoint lacks BI/flit
BI RT advertised but unmapped       dbg   USP RT present but unmappable
BI setup failed rc=%d               dbg   enable path failed (probe continues)
BI disabled by reset                dbg   reset wiped device BI Enable
BI not enabled on device            ERR   HDM-DB attach refused
coherency model not permitted by the window   ERR  committed decoder vs CFMWS
decoder%d.%d: path not BI capable   WARN  committed BI decoder on a non-BI path
```

### 3.4 Destructive-step map — read before starting

- **Never run §9 (unbind/churn) or §11 (soak) while an HDM-DB region is
  onlined as system RAM.** `dax_kmem` does not offline on removal;
  unbinding under it leaks memory until reboot and can panic. §4.3 ends
  with a mandatory teardown that returns the region to devdax and
  offlines it.
- **§10 (resets) is terminal for its boot.** After an SBR that wipes BI
  Enable, the driver does **not** re-enable BI without a full re-probe.
  Do §10 last, and **reboot + re-run Phase B** before any further
  phase. Do not let §11's soak run after §10 on the same boot — it
  would silently test the non-BI path.
- Recommended order: **B → C → D → E → (F if switch) → A → I(soak) →
  H(firmware, needs its own boots) → G(resets, last) → reboot.**

---

## 4. Phase A — Coherency validation (highest value, hardest to stage)

Everything else proves the driver programs registers correctly. This is
the only phase that proves the feature works.

### 4.1 The test

With a committed HDM-DB region (§5):

1. Host reads a line, pulling it into CPU cache.
2. The device changes that line's content **without host involvement**.
3. Host re-reads. **Pass:** host sees new data (BISnp invalidated the
   host copy). **Fail:** host sees stale cached data.

### 4.2 Triggering step 2 from in-tree software

| Mechanism | Status | Usable? |
|---|---|---|
| Media Operations 4402h ranged sanitize/zero | **not in mainline** | only with the out-of-tree patches |
| Sanitize 4400h (`memN/security/sanitize`) | in tree | **No** — `cxl_mem_sanitize()` returns `-EBUSY` unless `cxl_num_decoders_committed()==0`, i.e. refuses while any region is mapped (mbox.c:1307-1310) |
| GFAM / multi-host shared memory | HW dependent | Yes, if a second host writes the line |
| P2P / PCIe UIO | HW dependent | Yes, if available |
| Vendor debug/DMA path | vendor dependent | Yes — **ask the vendor which BI-dependent function the device implements; per CXL-BI.txt §9.14.3.3 a BI-capable device has one by construction** |

**If none is available, coherency is `N/A (no media-modifying path)` —
register programming only is validated.** The single most important
caveat in this document. Do not log a pass by omission.

### 4.3 Always-testable integrity (with mandatory teardown)

1. **System-RAM path.**
   ```
   daxctl reconfigure-device --mode=system-ram daxN.0
   # confirm the new NUMA node / online blocks, run write/verify
   ```
   Write/verify patterns across the full region; sustained mixed
   read/write ≥1 h; no corruption, MCE, or RAS event.
2. **device-dax path.** `daxctl reconfigure-device --mode=devdax daxN.0`;
   repeat write/verify through `/dev/daxN.0`.
3. **Negative control.** Same workload on an HDM-H region — must be
   equally clean (proves the harness is sound).
4. **Perf delta.** Bandwidth/latency HDM-DB vs HDM-H; a large
   unexplained HDM-DB regression is a finding. (Measure with a fixed
   tool, e.g. `fio`/`mlc`; record the tool and version.)

> **MANDATORY teardown to close Phase A** before any unbind/reset/soak:
> stop all workloads, `daxctl reconfigure-device --mode=devdax daxN.0`
> (or unbind `dax_kmem`), **confirm the blocks are offline**
> (`daxctl list`, `/proc/iomem`), then delete the region. A region left
> onlined as system RAM makes §9/§10/§11 dangerous and will look like a
> teardown bug in the driver when it is not.

---

## 5. Phase B — Preconditions and enablement

Cold boot with §3.3 dyndbg on, no regions.

| Step | Check | Pass |
|---|---|---|
| B.1 | `dmesg \| grep -i "found BI"` (needs §3.3) | BI Decoder / BI RT capabilities discovered at probe. **Not `lspci`** — the cap lives in the CXL.cache/mem MMIO block, not PCI config space |
| B.2 | Flex Bus DVSEC on the endpoint link (`lspci -vvxxx`, decode manually) | 256B flit negotiated |
| B.3 | `decoder0.*/cap_back_invalidate`, `cap_type2`, and `create_ram_region` presence | a root decoder with `cap_back_invalidate=1` **and** `cap_type2=1` **and** an existing `create_ram_region`/`create_pmem_region` attr |
| B.4 | `dmesg \| grep "BI requests enabled"` | present for the endpoint |
| B.5 | `dmesg \| grep -c "BI setup failed"` | 0 |
| B.6 | record `endpointN/decoderN.0/target_type` and the device's Supported Coherency Models | for context (t22 analogue); no pass/fail |

**Path programming.** endpoint→root, exactly one of: device-adjacent
dport BI **Enable**; every level above BI **Forward**. Verify via raw
MMIO read of each dport's BI Decoder Control register (see §14 on raw
access), or the dmesg trace if the platform blocks MMIO.

---

## 6. Phase C — HDM-DB region lifecycle and commit latency

| Step | Action | Expected |
|---|---|---|
| C.1 | `echo regionN > $ROOT/create_ram_region` on the BI root decoder | region created; dbg `created HDM-DB regionN` |
| C.2 | set granularity, ways, size, endpoint `dpa_size`, then `target0` | attach succeeds; `target_type` reads `accelerator` here (see below) |
| C.3 | `echo 1 > $REGION/commit` | commit succeeds |
| C.4 | `cat $EP_DECODER/back_invalidate` | `1` |
| C.5 | endpoint HDM decoder CTRL register (raw MMIO) | TRT (HostOnly) clear, BI bit set |
| C.6 | decommit, delete | clean teardown, no splat |

> **Expected surprise:** `target_type` reads **`accelerator`** for a
> Type 3 in HDM-DB (HDM-DB is device-coherent), from the `target0`
> write onward — **not a bug**, do not report it.

**Commit latency (switch topologies only).** `BI-ID commit wait took`
is emitted only for switch DSP BI Decoders and USP route tables — a
**switchless direct-attach device produces no commit-latency data at
all**. Where a switch is present:

- Record the raw HwInit `scale`/`base` and derived `tmo_us` per level
  (the `Invalid BI commit timeout` dbg line signals the 5 s fallback
  was taken — a fallback, not a real measurement).
- The wait value is **quantized** to roughly `[tmo_us/40, tmo_us/10]`
  by the driver's poll loop — it bounds, not measures, the latency.
  Treat it as "did it complete, and roughly how long", not precise
  hardware timing.
- Fail on any `timed out` or `rejected by hardware` on a healthy path.

Repeat C.1-C.6 as **x2 interleave** with a second BI device: both
endpoints read `back_invalidate=1`.

---

## 7. Phase D — Spec-mandated behaviour with BI *not* enabled

CXL-BI.txt §9.14.3.3 obligations on system software — driver-correctness
tests.

**D.1 — device works with BI unenabled.**
> "A BI-capable Type 3 device is required to operate correctly when
> System Software has not enabled BI."

Attach the device to an **HDM-H window** and run §4.3 integrity.
Expected: works normally, `back_invalidate=0`, no BI programming. Legal
fallback, not a failure.

**D.2 — no BI bit anywhere when the path is not 256B flit.**
> "the System Software shall ensure that the BI bit in none of the HDM
> decoders in the device, the switch, or the host that spans the
> device's HDM is set."

Two distinct sub-cases if link mode can be forced:
- **Degrade the *endpoint* link to 68B flit:** the endpoint itself is
  not BI-enabled — pass is *silence*: **no** `BI requests enabled`,
  **no** `BI not supported by topology` (that string is for a level
  *above* the endpoint), and an HDM-DB attach fails.
- **Degrade a link *above* the endpoint (RP/DSP/USP):** expect `BI not
  supported by topology`; no BI programming on the path.
Skip N/A if link mode cannot be forced.

**D.3 — BI Decoder Control BI bit = 0.** In the D.2 configuration, raw-
read the BI Decoder Control register on both device and DSP: BI bit 0.

---

## 8. Phase E — Fail-closed gates and error recovery

| Step | Setup | Expected |
|---|---|---|
| E.1 | non-BI-capable device to a BI window | `BI not enabled on device`, `-ENXIO` |
| E.2 | BI-capable device to an HDM-H window | *succeeds* (= D.1); `back_invalidate=0` |
| E.3 | switch present, BI RT unmappable | `BI RT advertised but unmapped`; BI declined |
| E.4 | **AER recovery** (t28 analogue): inject a fatal AER on the endpoint via `aer-inject`, or a CXL.mem/CXL.cache error via **ACPI EINJ** (this subsystem surfaces those, core/port.c) | `cxl_slot_reset()` re-runs the enable path via `device_attach()`; after recovery `back_invalidate=1` again and a fresh HDM-DB region commits; no oops |

---

## 9. Phase F — Teardown, unbind/rebind, refcounting

⚠ **Precondition:** no HDM-DB region onlined as system RAM (see §3.4 /
§4.3 teardown). Where lifetime/ordering bugs live (this series'
`cxl_decoder_reset()` UAF was found in exactly this shape).

1. **Unbind with a committed region** (region deleted or devdax, not
   system-ram): decoders reset, **then** `BI requests disabled`; path
   dports clear; no splat, no hang.
2. **Rebind** → BI re-enables from scratch; region recreatable.
3. **Port unbind** (`cxl_port`, the switch/HB port) → subtree tears down
   cleanly; memdev rebind recovers.
4. **Shared-dport refcounting** (≥2 endpoints sharing an upstream
   dport — the **root port** in a single-switch two-endpoint topology,
   or a **transit DSP** in a cascade): both up → shared level
   programmed once; unbind one → **stays**; unbind the second → clears.
5. **Region churn against unbind** (the crash reproducer's shape): loop
   create/commit/delete in the background while unbinding the port
   above, ≥100 iterations. **No oops, no wedged region sysfs.** Direct
   analogue of the QEMU `race: cascade under churn` case.

---

## 10. Phase G — Reset behaviour (**TERMINAL — run last**)

⚠ **Destructive. Run last, on a machine you can lose.** No region
onlined as system RAM. SBR on a live device can take the host down.
**Each SBR sub-case ends its useful boot** — the driver does not
re-enable BI after a wipe without a full re-probe; reboot and re-run
Phase B to continue.

| Step | Reset | Expected |
|---|---|---|
| G.1 | FLR, no region | component registers **survive**; no `BI disabled by reset`; BI still enabled |
| G.2 | FLR with committed HDM-DB region | region, decoders and BI all survive |
| G.3 | SBR (`echo cxl_bus > .../reset_method`), no region | if BI Enable wiped: `BI disabled by reset`; a later HDM-DB attach refused with `BI not enabled on device` |
| G.4 | **reboot**, re-run Phase B, then recreate the region | BI re-enabled from scratch; HDM-DB region works again |
| G.5 | SBR with committed region | decoder-loss path fires (`dev_crit` + taint); host survives; **then reboot** |

Record whether real FLR/SBR match the modelled behaviour (§2 item 5).

---

## 11. Phase I — Soak (before §10)

`CONFIG_KASAN` + `CONFIG_PROVE_LOCKING`. ⚠ Region in **devdax**, never
system-ram, throughout. 24 h of:

- HDM-DB region create/commit/read-write/decommit/delete cycles,
- interleaved endpoint and port unbind/rebind,
- concurrent sysfs readers (`back_invalidate`, `target_type`,
  `cap_back_invalidate`).

**Pass:** no oops, no KASAN report, no lockdep splat, no leaked regions
or DPA, BI programming fully cleared on every level once all endpoints
are unbound. (Runs before §10 so it exercises the BI path, not a
reset-wiped non-BI device.)

---

## 12. Phase H — Firmware-committed / adopt (own boots)

Firmware pre-commit is rare, but **kexec manufactures it portably**: a
committed HDM-DB region's decoder state is plain hardware register
state, and `cxl_pci` has no `.shutdown`, so kexec into the test kernel
inherits committed decoders and exercises the adopt path without any
special BIOS.

1. **Auto-assembly** (firmware or post-kexec): region assembles at boot
   unaided; `back_invalidate=1`.
2. **Adopt**: `adopting firmware-enabled BI`; **zero** `BI-ID commit
   wait took` if the whole path was pre-configured (switch case).
3. **Partial config**: driver programs/commits from the first
   unconfigured level upward.
4. **Window mismatch**: a committed decoder the CFMWS forbids →
   `coherency model not permitted by the window`, no region.
5. **BI decoder on a non-BI path**: `decoder%d.%d: path not BI capable`.

> **kdump do-no-harm:** panic a box holding a committed HDM-DB region
> and confirm the crash kernel captures a dump. kdump skips
> `device_shutdown()`, so BI state is inherited live — the question is
> "can you still get a dump", not "does BI work in the crash kernel".

---

## 13. Phase J — Switch topologies (if a BI switch is available)

- One switch, one endpoint: DSP Enable, RP Forward.
- One switch, two endpoints: shared **root-port** dport refcounted (§9.4).
- Cascaded switches: device-adjacent DSP Enable, every transit level
  Forward, USP route tables commit per level.
- Record USP BI RT commit latencies (§6 caveats apply).

---

## 14. Raw register access

Steps B.6 path-programming, C.5, D.3, and G verification read CXL
**component MMIO** registers (BI Decoder Control, HDM decoder CTRL) —
**not** PCI config space, so **`setpci`/`lspci` cannot reach them**. Use
an MMIO tool against the component register block base (found via the
CXL Register Locator DVSEC / the resource under
`/sys/bus/pci/devices/<bdf>/resourceN`), e.g. a `/dev/mem` mmap reader
or `devmem2`.

If platform lockdown blocks `/dev/mem`/MMIO, these steps fall back to
the dmesg trace, which is **weaker evidence** (it shows the driver's
intent, not the register's final state). Record which was used; a step
proven only by dmesg under lockdown is `partial`, not `pass`.

---

## 15. Reporting

Per phase: **pass / fail / N-A (reason) / partial (dmesg-only)**.

Capture always:

- kernel `.config` and the exact commit SHA under test,
- full `dmesg` with §3.3 dyndbg on,
- serial console / `netconsole` / `pstore` capture (the destructive
  phases can crash before dmesg flushes),
- `cxl list -vvv` before/after, **plus** direct `cat` of
  `cap_back_invalidate`, `cap_type2`, `back_invalidate`, `target_type`
  (`cxl list` does not print these),
- `acpidump -n CEDT` and `lspci -vvxxx` for endpoint and RP,
- §6: raw scale/base, derived tmo_us, and wait values per level,
- §4: exact failing address and pattern on any mismatch.

---

## 16. Known limits

1. **Coherency may end up unvalidated** (§4.2) — if the device has no
   media-modifying path, only register programming is proven. State it.
2. **Some fault injection is emulation-only.** BI-ID commit timeouts,
   commit rejection and mid-path *enable* failures have no hardware
   trigger; their handling stays QEMU-validated (t21/t23). **Protocol
   errors are NOT emulation-only** — ACPI EINJ CXL.mem/CXL.cache
   injection is in-tree and used in §8 E.4.
3. **Firmware phases (§12) may be N/A**, but kexec (§12) and EINJ (§8)
   make more of this reachable than "wait for BIOS".
4. **Raw register verification** may be blocked by lockdown (§14); the
   dmesg fallback is weaker.
5. **Commit-latency numbers are switch-only and poll-quantized** (§6) —
   a direct-attach device yields none, and the values bound rather than
   measure.
6. **Type 2 is out of scope** by design, not by accident.
7. **Suspend/hibernate** interaction is out of scope (blocked by
   `cxl_mem_active_inc()` today); note if the platform reaches it.
