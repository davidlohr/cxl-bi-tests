# CXL Back-Invalidate (BI) test suite

Boots QEMU with a set of BI-capable and BI-incapable CXL topologies, then
runs an in-guest driver that exercises the kernel's HDM-DB region path,
the `cxl_bi_setup`/`cxl_bi_dealloc` lifecycle, and the fail-closed gates
around 256B Flit mode and the CFMWS BI restriction. Structure and style
follow the PCIe UIO test suite ([davidlohr/uio-tests][uio]).

[uio]: https://github.com/davidlohr/uio-tests

The kernel side is the v6 series *cxl: Support Back-Invalidate* on top of
`torvalds/master`; the QEMU side is upstream with the `hdm-db`,
`x-256b-flit`, and `cxl-fmw.N.back-invalidate` support already merged.

## Scope

The suite validates enumeration, region provisioning, and lifetime
management. As with the UIO suite there is no BI data path: BISnp/BIRsp
wire behaviour is out of scope. What we do check:

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

Ten topology scripts under `topos/`, each one small, each one varying
one axis so the fail-closed gate under test is isolated.

| Suite | Topology | What it exercises |
|-------|----------|-------------------|
| **t1** | Endpoint directly under an RP, no switch, BI CFMWS | Minimal happy path: single-dport walk. |
| **t2** | Endpoint under DSP + USP + RP, BI CFMWS | Full switched happy path. Phase 2 drives unbind/rebind lifecycle. |
| **t3** | Same as t2 but the CFMWS carries no BI restriction | HDM-H region; `cap_bi=0`; endpoint `bi=0`. |
| **t4** | Endpoint without `hdm-db`, BI CFMWS | Region attach rejects with "BI not enabled on device". |
| **t5** | Two BI endpoints sharing one switch, BI CFMWS | 2-way HDM-DB region; both endpoints `bi=1`. Phase 2 drives the shared-RP `nr_bi` refcount case. |
| **t6** | Switch USP with `hdm-db` present (RT optional per 8.2.4.26) | Load-bearing marker for the `@bi==NULL` USP branch in `cxl_is_bi_capable()`. |
| **t7** | Endpoint uplink not in 256B Flit, BI CFMWS | `cxl_bi_setup` bails on the endpoint check; attach rejects. |
| **t8** | DSP not in 256B Flit ("68b DSP"), BI CFMWS | The v5 cover-letter mixed-config case. |
| **t9** | Two cascaded switches, BI CFMWS | Two-level `cxl_bi_setup` walk. |
| **t10** | Two endpoints under **different** RPs, BI CFMWS | Independent BI walks per RP; optional 2-way cross-RP region. |

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
│   └── t10-cross-rp.sh
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

Guest requirements match the UIO suite: DHCP on `enp0s2` (first NIC),
root SSH via public-key authentication, and `dmesg` readable by root.

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
  poll. If QEMU grows a knob for this, a `t11-commit-timeout.sh`
  becomes straightforward.
- t6 (USP without BI RT) is currently indistinguishable from t2 in
  upstream QEMU. It is included as a documentation marker; add a
  future `x-bi-rt=off` knob on `cxl-upstream` to make it distinct.
