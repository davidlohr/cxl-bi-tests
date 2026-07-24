# CXL Back-Invalidate (BI) test suite

Boots QEMU with BI-capable and BI-incapable CXL topologies, then runs
an in-guest driver against the kernel's HDM-DB region support: the
root `cap_bi` / endpoint `bi` sysfs ABI, the region attach gates, the
`cxl_bi_setup`/`cxl_bi_dealloc` lifecycle, and the fail-closed paths
(256B Flit, CFMWS BI restriction, non-BI devices). Enumeration,
provisioning and lifetime only: BISnp/BIRsp wire behaviour is out of
scope (QEMU does not emulate it).

Requires a kernel with CXL BI support and a QEMU providing `hdm-db`,
`x-256b-flit` and `cxl-fmw.N.back-invalidate`.

## Topologies

Eighteen topology scripts under `topos/`, each varying one axis so the
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
| **t9** | Cascaded switches (two switch pairs), BI CFMWS | BI enables through both switch layers; an HDM-DB region commits across the cascade. |
| **t10** | Two endpoints under **different** RPs, BI CFMWS | Each RP gets its own independent BI setup; an HDM-DB region commits (2-way cross-RP when the root allows it, otherwise a per-RP 1-way). |
| **t11** | Endpoint with persistent memdev, BI CFMWS | An HDM-DB PMEM region commits and the endpoint reports `bi=1`. |
| **t12** | One BI + one non-BI endpoint under one switch, BI CFMWS | A 2-way region attach across both rejects the non-BI target. |
| **t13** | *Host-only*: CFMWS with `host-only=on,back-invalidate=on` | QEMU must refuse the launch (CXL 4.0 §9.18.1.3 Window Restrictions). No guest boot. |
| **t14** | Two CFMWS (BI + HDM-H) with two endpoints, BI CFMWS on one | BI and HDM-H root decoders coexist; endpoints bind to the correct one and cross-assignment rejects. |
| **t15** | One endpoint, two CFMWS (BI + HDM-H) targeting the same RP | A decoder cycled out of an HDM-DB region reverts to its default `target_type`, then commits into an HDM-H region with no type-mismatch WARN. |
| **t16** | Firmware-committed decoders via QEMU `x-committed=hdm-h\|hdm-db` (host-driven, multi-boot) | Adoption of a committed HDM-DB decoder (plus re-adoption across reboot), HDM-H control, the BI-decoder-in-a-non-BI-window reject (§9.18.1.3), and a combined 3-HB boot asserting per-device independence of the adopt/reject paths. Scenarios 6-7 stage a committed 2-way interleave set (`x-committed-ways=2`, one BI window targeting two passthrough HBs): an all-BI control that must assemble into one HDM-DB region, and a mixed BI + HDM-H set that must never reach a committed region nor silently coerce the committed-BI decoder's type. Skips wholesale when QEMU lacks `x-committed` (scenarios 6-7: `x-committed-ways`); region-assembly checks SKIP when the kernel lacks the out-of-series passthrough assembly patch. |
| **t17** | QMP runtime hotplug: one endpoint + two empty DSPs (host-driven) | BI setup driven by real pciehp events rather than driver rebind: hot-add enables BI through the fresh dport and commits a region; hot-remove with a committed HDM-DB region tears down WARN-free while the survivor's path stays enabled (`nr_bi`); add-after-remove completes the lifecycle. Skips if QEMU rejects cxl-type3 hotplug. |
| **t18** | Same topology as t5, storm-driven | Concurrency storms: parallel unbind/bind flips of both endpoints under a live bi/cap_bi sysfs reader (races `nr_bi`, setup/dealloc, devres), then region create/commit/destroy churn with per-cycle timing to catch 5s commit-poll leaks, then a post-storm 2-way commit and a dmesg hygiene sweep (WARN, lockdep, refcount, leaked mappings). |

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
`<suite>.dmesg` (full kernel log after the run) to `$OUT`. Suites `t2`
and `t5` additionally emit `t2-unbindrebind.{tap,dmesg}` and
`t5-nrbi.{tap,dmesg}` for their phase-2 helpers.

## Diagnostics

Failures map to specific root causes:

- Missing `cap_bi` (root) or `bi` (endpoint) → kernel lacks the HDM-DB
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

- No BISnp/BIRsp emulation and no commit-timeout injection in QEMU; a
  knob for the latter would make a `__cxl_bi_commit_decoder()` timeout
  suite straightforward.
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
  positive `cap_bi` probe.
- QEMU (v11.1.0-rc0) never finalizes a cxl-type3 unplug: the guest
  completes the removal but the device stays in the QOM tree and the
  slot reads occupied forever. t17 therefore re-adds into a spare DSP
  instead of reusing the vacated slot.
