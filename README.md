# CXL Back-Invalidate (BI) test suite

Boots QEMU with a set of BI-capable and BI-incapable CXL topologies, then
runs an in-guest driver that exercises the kernel's HDM-DB region path,
the `cxl_bi_setup`/`cxl_bi_dealloc` lifecycle, and the fail-closed gates
around 256B Flit mode and the CFMWS BI restriction.

The kernel side is the v6 series *cxl: Support Back-Invalidate* on top of
`torvalds/master`; the QEMU side is upstream with the `hdm-db`,
`x-256b-flit`, and `cxl-fmw.N.back-invalidate` support already merged.

## Scope

The suite validates enumeration, region provisioning, and lifetime
management. There is no BI data path here: BISnp/BIRsp wire behaviour
is out of scope (QEMU does not emulate it). What we do check:

- Root decoder ABI: `cap_bi` from CFMWS BI restriction (patch 4).
- Endpoint decoder ABI: `bi` reflects HDM-DB configuration state.
- `cxl_bi_setup` walk: verify the topology, enable BI on every dport,
  set `cxlds->bi`. Fail-closed on missing 256B Flit or missing BI
  Decoder capability anywhere in the path (patch 2).
- `cxl_region_attach` gates: reject BI-flavored region attach when the
  device isn't BI (patch 4), or when the HDM's supported coherency is
  incompatible with the region type.
- Unbind/rebind lifecycle: `cxl_bi_dealloc` on unbind, fresh enable on
  rebind, shared-RP `nr_bi` refcount across two endpoints.
- Devres hygiene: hot-add/hot-remove does not leak the dport BI Decoder
  mapping (regression cover for the patch 1 fix Richard flagged).

## Topologies

Fourteen topology scripts under `topos/`, each one small, each one
varying one axis so the fail-closed gate under test is isolated.

| Suite | Topology | What it exercises |
|-------|----------|-------------------|
| **t1** | Endpoint directly under an RP, no switch, BI CFMWS | Minimal happy path: single-dport walk. Verifies `cap_bi`/`bi` enumeration, read-only ABI, HDM-DB region create/commit, endpoint decoder `target_type=accelerator`, endpoint `bi` 0→1 across commit and back to 0 on destroy. |
| **t2** | Endpoint under DSP + USP + RP, BI CFMWS | Full switched happy path. Also asserts `create_ram_region` and `create_pmem_region` visibility on the BI root, `decoders_committed` bumps across commit/destroy, no `mismatch decoder type` WARN, and a create → destroy → re-create → commit cycle. Phase 2 drives the unbind/rebind lifecycle. |
| **t3** | Same as t2 but the CFMWS carries no BI restriction | No BI root decoder present; HDM-H region created + committed; endpoint decoder `target_type=expander`; endpoint `bi=0`. |
| **t4** | Endpoint without `hdm-db`, BI CFMWS | Region attach rejects with "BI not enabled on device"; region cannot reach the committed state. |
| **t5** | Two BI endpoints sharing one switch, BI CFMWS | Main body: 2-way HDM-DB region; both endpoints `bi=1`. Phase 2: commit a 1-way region on one endpoint, unbind the other (region-less) endpoint, verify the committed endpoint stays `bi=1` (shared-RP `nr_bi` invariant), rebind the unbound endpoint with no `BI setup failed` or `Failed to request region` (patch 1 leak cover). |
| **t6** | Switch USP with `hdm-db` present (RT optional per 8.2.4.26) | Same shape as t2; load-bearing marker for the `@bi==NULL` USP branch in `cxl_is_bi_capable()`. Becomes distinct once QEMU can suppress BI RT on a switch USP. |
| **t7** | RP not in 256B Flit mode, BI CFMWS | *Intended:* `cxl_bi_setup` bails at the RP hop; attach rejects. *Actual:* QEMU's `x-256b-flit=off` on ports doesn't propagate to the register `cxl_pci_flit_256()` reads, so the driver detects this via `bi_setup_succeeded` and emits TAP `# SKIP` for the fail-closed assertions. Ships the topology so a future QEMU fix flips it green automatically. |
| **t8** | DSP not in 256B Flit ("68b DSP"), BI CFMWS | The v5 cover-letter mixed-config case. Same QEMU limitation as t7 - emits TAP `# SKIP` today. |
| **t9** | Two cascaded switches, BI CFMWS | Two-level `cxl_bi_setup` walk (inner + outer switch). Confirms two `cxl_port` entries and the HDM-DB region commits across the cascade. |
| **t10** | Two endpoints under **different** RPs, BI CFMWS | Independent BI walks per RP. Attempts a 2-way cross-RP region if the root's `interleave_ways >= 2`, otherwise falls back to a 1-way region on RP0 to prove BI setup succeeded on that path. |
| **t11** | Endpoint with `persistent-memdev` + LSA, BI CFMWS | PMEM HDM-DB region: `cap_pmem=1` on the BI root, `create_pmem_region` present, uuid-before-size ordering, endpoint `mode=pmem` and `dpa_size` on the pmem partition, endpoint decoder `target_type=accelerator` after commit, endpoint `bi=1`. |
| **t12** | One BI + one non-BI endpoint under one switch, BI CFMWS | Identifies BI vs non-BI endpoint by probing 1-way HDM-DB commits, then attempts a 2-way region across both: attach rejects the non-BI target with "BI not enabled on device". |
| **t13** | *Host-only*: CFMWS with `host-only=on,back-invalidate=on` | Negative launch: QEMU must refuse per CXL 4.0 9.14.3. Runs `qemu-system-x86_64` directly, greps stderr for the refusal wording, no guest boot. |
| **t14** | Two CFMWS (BI + HDM-H) with two endpoints under separate pxb | Both BI and HDM-H root decoders coexist with distinct `cap_bi` values. Each endpoint binds to its "own" root; cross-assignment (HDM-H endpoint into the BI root) rejects. |

## Layout

```
cxl-bi-tests/
├── README.md
├── topo-lib.sh         # QEMU launcher + guest_ssh helpers
├── run-all.sh          # orchestrator (TAP + dmesg per suite)
├── topos/
│   ├── t1-direct.sh
│   ├── t2-switch.sh
│   ├── t3-hdmh-cfmws.sh
│   ├── t4-nobi-dev.sh
│   ├── t5-2way.sh
│   ├── t6-usp-nort.sh
│   ├── t7-noflit-uplink.sh
│   ├── t8-noflit-dsp.sh
│   ├── t9-cascade.sh
│   ├── t10-cross-rp.sh
│   ├── t11-pmem.sh
│   ├── t12-mixed-iw.sh
│   ├── t13-hostonly-bi.sh          # host-only negative launch
│   └── t14-mixed-cfmws.sh
└── guest/
    ├── run-tests.sh                # in-guest TAP driver, one case per suite
    ├── unbindrebind-phase.sh       # t2 phase 2: cxl_bi_dealloc/setup lifecycle
    └── nrbi-refcount-phase.sh      # t5 phase 2: shared-RP nr_bi refcount
```

## Configuration

Environment variables consumed by `topo-lib.sh`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `QEMU` | `$HOME/code/qemu-upstream/build/qemu-system-x86_64` | QEMU binary. |
| `KERNEL` | `$HOME/code/linux-torvalds/arch/x86/boot/bzImage` | bzImage with the v6 BI series. |
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

## Kernel invariants each suite locks in

The series has five patches; each fail-closed gate lives in one of them
so the mapping is worth writing down:

- **Patch 1** (`cxl: Add BI register probing and port initialization`) —
  covered by every suite that reaches region commit: if the dport BI
  Decoder mapping ever leaks (Richard's hot-remove regression) the t2
  and t5 phase-2 unbind/rebind cycles will surface `-EBUSY` on rebind.
- **Patch 2** (`cxl/pci: Add BI topology enable/disable`) — happy paths
  in t1/t2/t5/t6/t9/t10; the rollback path is exercised implicitly by
  the fail-closed gates in t7/t8. The err_rollback fix (skip the failed
  dport) is what keeps t7/t8 boot times reasonable (no double 5s commit
  timeout).
- **Patch 3** (`cxl/hdm: Add BI coherency support for endpoint decoders`) —
  drives `target_type` from `cxlhdm->supported_coherency`; t4 exercises
  the "device not BI-capable" attach reject.
- **Patch 4** (`cxl: Add HDM-DB region creation`) — root `cap_bi` and
  endpoint `bi` sysfs are exercised in every suite. t3 verifies HDM-H
  region creation on a non-BI CFMWS; t4 verifies the "BI not enabled on
  device" attach reject.
- **Patch 5** (`cxl/hdm: Rename decoder coherency flags`) — rename only;
  covered by anything that reads `cap_bi` (which cohabits with the
  renamed `cap_ram`/`cap_pmem` in the same attribute group).

## Diagnostics

Failures map to specific root causes:

- Missing `cap_bi` on root decoders → patch 4 not applied (or
  `is_visible` misconfigured).
- Missing `bi` on endpoint decoders → same as above, endpoint side.
- `BI setup failed` in dmesg on t1/t2/t5/t6/t9 → topology walk failed
  where it should have succeeded (register probing regression, USP
  probe, or `nr_bi` accounting).
- `BI setup failed` **absent** in dmesg on t7/t8 → cxl_bi_setup didn't
  bail on the missing 256B Flit hop as it should.
- `-EBUSY` on the second bind in t2/t5 phase 2 → dport BI Decoder
  region leaked on unbind (patch 1 regression).
- 5s+ pause on t7/t8 rollback → err_rollback disables the failed dport
  (patch 2 rollback regression).

## Known limitations

- No BI data-path validation: BISnp/BIRsp wire behaviour is out of
  scope. QEMU does not currently emulate the response side.
- No BI-ID commit timeout injection (v5 cover-letter scenario 5): the
  suite has no way to make QEMU refuse a `__cxl_bi_commit_decoder()`
  poll. If QEMU grows a knob for this, a `t15-commit-timeout.sh`
  becomes straightforward.
- t7 and t8 model non-flit hops (on the RP and DSP respectively) but
  currently emit TAP `# SKIP` because upstream QEMU's `x-256b-flit=off`
  device option is not reflected in the `LnkCtl2.FlitModeEnable` bit
  that the kernel's `cxl_pci_flit_256()` reads. The driver detects
  that `cxl_bi_setup` still succeeded (via a `bi_setup_succeeded`
  probe against dmesg) and skips the fail-closed assertions. When
  QEMU wires the flit register through, both suites flip to strict
  fail-closed checks with no code changes.
- t6 (USP without BI RT) is currently indistinguishable from t2 in
  upstream QEMU. It is included as a documentation marker; add a
  future `x-bi-rt=off` knob on `cxl-upstream` to make it distinct.
- t13 is a host-only negative launch and does not use the guest
  driver; it captures QEMU's stderr and grep's for the expected
  `host-only coherent + back-invalidate` refusal message. If QEMU's
  wording changes, adjust the regex there.
- t12 identifies the BI vs non-BI endpoint by trying to commit an
  HDM-DB region on each; on a topology where cxl_bi_setup succeeds on
  both (e.g. a future QEMU that emulates BI on the non-`hdm-db` device
  too) the classification will need to switch to a positive `cap_bi`
  probe on the endpoint side.
