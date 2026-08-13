# CXL Back-Invalidate (BI) test suite

Boots QEMU with BI-capable and BI-incapable CXL topologies, then runs
an in-guest driver against the kernel's HDM-DB region support: the
root `cap_back_invalidate` / endpoint `back_invalidate` sysfs ABI, the region attach gates, the
`cxl_bi_setup`/`cxl_bi_dealloc` lifecycle, and the fail-closed paths
(256B Flit, CFMWS BI restriction, non-BI devices). Enumeration,
provisioning and lifetime only: BISnp/BIRsp wire behaviour is out of
scope (QEMU does not emulate it).

Requires a kernel with CXL BI support and a QEMU providing `hdm-db`,
`x-256b-flit` and `cxl-fmw.N.back-invalidate`. Suites that need other
QEMU knobs skip themselves when the binary lacks them.

## Topologies

Twenty-two topology scripts under `topos/`, each varying one axis so the
gate under test is isolated.

| Suite | Topology | What it exercises |
|-------|----------|-------------------|
| **t1** | Endpoint directly under an RP, no switch, BI CFMWS | BI enables end-to-end through a single dport; an HDM-DB region commits and the endpoint reports `bi=1`. |
| **t2** | Endpoint under DSP + USP + RP, BI CFMWS | BI enables through the full DSP + USP + RP walk; an HDM-DB region commits. Phase 2 verifies `cxl_bi_dealloc` on unbind and a fresh `cxl_bi_setup` on rebind. |
| **t3** | BI-capable endpoint, non-BI CFMWS | No BI root decoder is created; an HDM-H region commits without any BI activation on the topology. |
| **t4** | Non-BI endpoint (`hdm-db` off), BI CFMWS | Region attach rejects with "BI not enabled on device". |
| **t5** | Two BI endpoints sharing one switch and one RP, BI CFMWS | A 2-way HDM-DB region commits with both endpoints in BI. Phase 2 verifies the shared RP keeps BI enabled while any child still needs it (`nr_bi` refcount) and that rebinding one endpoint does not leak the dport BI Decoder mapping. |
| **t6** | Switch USP with `hdm-db`, BI RT optional per §8.2.4.26 | Exercises the "USP BI RT is optional" branch in `cxl_is_bi_capable()`. Same visible result as t2 pending a QEMU knob to suppress BI RT on a switch USP. |
| **t7** | RP not in 256B Flit, BI CFMWS | `cxl_bi_setup` must bail at the RP hop. Emits TAP `# SKIP` today — see Known limitations. |
| **t8** | DSP not in 256B Flit ("68b DSP"), BI CFMWS | `cxl_bi_setup` must bail at the DSP hop (a CXL 4.0 §9.14.3 mixed configuration). Emits TAP `# SKIP` today — see Known limitations. |
| **t9** | Cascaded switches (two switch pairs), BI + HDM-H CFMWS | BI works at any switch depth: an HDM-DB region creates and commits two switch hops down (endpoint `back_invalidate=1`), the capability walk finds four BI decoders, both route tables and a commit at each switch level, and an HDM-H region still commits across both switches. Phase 2 unbinds the outer switch port's driver with an HDM-H region committed: the devres cascade tears the child subtree down first and disables BI on the way, the emptied port is reaped, and a `cxl_mem` rebind re-enumerates the cascade and re-enables BI; a second cycle fires the unbind under region churn and a decoder reader. |
| **t10** | Two endpoints under **different** RPs, BI CFMWS | Each RP gets its own independent BI setup; an HDM-DB region commits (2-way cross-RP when the root allows it, otherwise a per-RP 1-way). |
| **t11** | Endpoint with persistent memdev, BI CFMWS | An HDM-DB PMEM region commits and the endpoint reports `bi=1`. |
| **t12** | One BI + one non-BI endpoint under one switch, BI CFMWS | A 2-way region attach across both rejects the non-BI target. |
| **t13** | *Host-only*: CFMWS with `host-only=on,back-invalidate=on` | QEMU must refuse the launch (CXL 4.0 §9.18.1.3 Window Restrictions). No guest boot. |
| **t14** | Two CFMWS (BI + HDM-H) with two endpoints, BI CFMWS on one | BI and HDM-H root decoders coexist; endpoints bind to the correct one and cross-assignment rejects. |
| **t15** | One endpoint, two CFMWS (BI + HDM-H) targeting the same RP | A decoder cycled out of an HDM-DB region reverts to its default `target_type`, then commits into an HDM-H region with no type-mismatch WARN. |
| **t16** | Firmware-committed decoders via QEMU `x-committed=hdm-h\|hdm-db` (host-driven, multi-boot) | Adoption of a committed HDM-DB decoder (plus re-adoption across reboot), HDM-H control, the BI-decoder-in-a-non-BI-window reject (§9.18.1.3), and a combined 3-HB boot asserting per-device independence of the adopt/reject paths. Scenarios 6-7 stage a committed 2-way interleave set (`x-committed-ways=2`, one BI window targeting two passthrough HBs): an all-BI control that must assemble into one HDM-DB region, and a mixed BI + HDM-H set that must never reach a committed region nor silently coerce the committed-BI decoder's type. Skips wholesale when QEMU lacks `x-committed` (scenarios 6-7: `x-committed-ways`); region-assembly checks SKIP when the kernel lacks the out-of-series passthrough assembly patch. |
| **t17** | QMP runtime hotplug: one endpoint + two empty DSPs (host-driven) | BI setup driven by real pciehp events rather than driver rebind: hot-add enables BI through the fresh dport and commits a region; hot-remove with a committed HDM-DB region tears down WARN-free while the survivor's path stays enabled (`nr_bi`); add-after-remove completes the lifecycle. Skips if QEMU rejects cxl-type3 hotplug. |
| **t18** | Same topology as t5, storm-driven | Concurrency storms: parallel unbind/bind flips of both endpoints under a live back_invalidate/cap_back_invalidate sysfs reader (races `nr_bi`, setup/dealloc, devres), then region create/commit/destroy churn with per-cycle timing to catch 5s commit-poll leaks, then a post-storm 2-way commit and a dmesg hygiene sweep (WARN, lockdep, refcount, leaked mappings). |
| **t19** | 2-target BI window (window-level interleave), two BI endpoints on separate passthrough HBs | Manual counterpart of t16's committed 2-way set: a sysfs-created 2-way HDM-DB region across a deterministically iw=2 root decoder attaches, commits, reaches `bi=1` on both, and survives a full teardown + re-create cycle. |
| **t20** | Same shape as t19, second device host-only coherent | Manual interleave across mixed coherency models: the 2-way HDM-DB attach rejects the plain target in both wiring orders (device gates: "BI not enabled on device" / "HDM is host-only coherent"), nothing is left committed, no WARNs. t19 is the paired positive control. |
| **t21** | Same window pair as t15 (BI + HDM-H) but behind a switch, so the DSP commit machinery is in the path | BOTH-coherency fallback: with BI setup failed at boot (a qemu whose BI commit latches past the advertised 2s timeout), an HDM-DB attach fails closed ("BI not enabled on device") while a host-only region still creates, commits and tears down on the same endpoint decoder with `bi=0` and the default `expander` target_type throughout. SKIPs on stock QEMU, where BI setup succeeds. |
| **t22** | Endpoint reporting Unknown in Supported Coherency Models (`x-coherency-unknown=on`), BI CFMWS | The only topology whose device does not name the coherency models it supports. Table 8-116 permits 00b, which says nothing about whether Target Range Type is writable, so the kernel does not refuse it: the decoder defaults to `expander`, inherits `accelerator` on attach to an HDM-DB region with `cxlds->bi` as the gate, commits with `bi=1`, and reverts on destroy. SKIPs when QEMU lacks the knob. |

## Configuration

Environment variables consumed by `topo-lib.sh`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `QEMU` | `$HOME/code/qemu-upstream/build/qemu-system-x86_64` | QEMU binary. |
| `KERNEL` | `$HOME/code/linux-torvalds/arch/x86/boot/bzImage` | bzImage with CXL BI support enabled. |
| `IMG` | `$HOME/img/cxl-test.qcow2` | Guest rootfs. |
| `ROOTDEV` | `/dev/sda1` | Guest root partition. |
| `SSH_KEY` | *(unset)* | Optional ssh identity file. |
| `EXTRA_APPEND` | *(empty)* | Extra kernel command-line arguments. |
| `SSHPORT` | `27210` | Host port forwarded to guest sshd. |
| `RUNDIR` | `/tmp/cxl-bi-tests` | Work directory (console log, qmp socket, results). |
| `OUT` | `$RUNDIR/results` | Results directory (`<suite>.tap`, `<suite>.dmesg`). |

Guest requirements: DHCP on `enp0s2` (first NIC), root SSH via
public-key authentication, and `dmesg` readable by root.

## Invocation

Full run:

```
./run-all.sh
```

Subset:

```
./run-all.sh t1 t4 t8
```

Single suite, interactive (leaves the guest up):

```
./topos/t2-switch.sh
source topo-lib.sh
wait_for_guest 150
guest_ssh "bash /tmp/run-tests.sh t2"
```

Each suite writes `<suite>.tap` (TAP output on stdout) and
`<suite>.dmesg` (full kernel log after the run) to `$OUT`. Suites
`t2`, `t5` and `t9` additionally emit `t2-unbindrebind.{tap,dmesg}`,
`t2-lifecycle.{tap,dmesg}`, `t5-nrbi.{tap,dmesg}` and
`t9-cascade.{tap,dmesg}` for their phase helpers (t2 phase 3 races a
decoder-attribute reader against repeated committed-region unbinds to
pin the endpoint-vs-cxlds teardown orderings; t9 phase 2 covers the
mid-level switch-port unbind cascade).

## Diagnostics

Failures map to specific root causes:

- Missing `cap_back_invalidate` (root) or `back_invalidate` (endpoint) → kernel lacks the HDM-DB
  region ABI, or the attribute group's `is_visible` is misconfigured.
- `BI setup failed` in dmesg on t1/t2/t5/t6/t9 → topology walk failed
  where it should have succeeded (register probing, USP probe, or
  `nr_bi` accounting regression).
- `BI setup failed` **absent** in dmesg on t7/t8 → `cxl_bi_setup`
  didn't bail on the missing 256B Flit hop as it should.
- `-EBUSY` on the second bind in t2/t5 phase 2 → dport BI Decoder
  mapping leaked on unbind (devres group boundary regression).
- `mismatch decoder type` WARN in dmesg on t15 → region detach did not
  restore the endpoint decoder's default `target_type`.
- 5s+ pause on t7/t8 rollback → err_rollback drove disable on the
  failed dport instead of skipping it.

## Known limitations

- No BISnp/BIRsp emulation in QEMU. Commit-timeout injection has no
  QEMU knob either: t21 stages it with a local QEMU modification that
  latches the BI commit past the advertised 2s timeout, and records
  itself as a SKIP on stock QEMU.
- t7/t8 emit `# SKIP`: upstream QEMU's `x-256b-flit=off` is not
  reflected in the `LnkCtl2` flit bit that `cxl_pci_flit_256()` reads.
  When QEMU wires it through, both flip to strict fail-closed checks
  with no code changes.
- t6 is indistinguishable from t2 until QEMU grows an `x-bi-rt=off`
  knob on `cxl-upstream`.
- t13 greps QEMU's stderr for the launch refusal; adjust the regex if
  QEMU's wording changes.
- t12 classifies the BI endpoint by attempting the HDM-DB commit; if a
  future QEMU emulates BI on the non-`hdm-db` device too, switch to a
  positive `cap_back_invalidate` probe.
- QEMU (v11.1.0-rc0) never finalizes a cxl-type3 unplug: the guest
  completes the removal but the device stays in the QOM tree and the
  slot reads occupied forever. t17 therefore re-adds into a spare DSP
  instead of reusing the vacated slot.
- A cxl_mem probe racing a sibling's switch-port reap can fail
  terminally (silent -ENXIO; the memdev is left driverless and only a
  rebind recovers it). The kernel does not promise otherwise, so t18
  converges through at most one recovery rebind per endpoint and
  reports it as a TAP diagnostic; only an unrecoverable memdev fails
  the suite.
