# Suite pages

One page per suite under `topos/`, each documenting what the suite tests,
the QEMU topology it boots (with a diagram), the semantics its checks
enforce, and every TAP line it can emit with its expected value. The
pages are written from the suite scripts, `guest/run-tests.sh`, the guest
phase helpers, `run-all.sh`, the README table and
[topologies.md](../topologies.md); nothing in them goes beyond what those
sources state.

Diagrams are generated: `specs/<suite>.json` describes each shape and
`topo-svg.py` renders it to `img/<suite>.svg`. To regenerate after editing
a spec:

```
cd docs/tests && for s in specs/*.json; do python3 topo-svg.py $s img/$(basename $s .json).svg; done
```

Suites in `run-all.sh`'s default order (happy paths first, then mixed
configurations and fail-closed gates, then the deeper topologies, then the
guest-less check).

| Suite | Page | Mode |
|---|---|---|
| **t1** | [the minimal BI topology: one root port, one cxl-type3 directly under it, no switch](t1.md) | guest-driven |
| **t2** | [single-switch happy path, one BI-capable endpoint](t2.md) | guest-driven |
| **t5** | [two BI-capable endpoints under one switch, 2-way region](t5.md) | guest-driven |
| **t3** | [BI-capable device under a plain (HDM-H) CFMWS](t3.md) | guest-driven |
| **t4** | [non-BI device (no hdm-db) in a BI-restricted CFMWS](t4.md) | guest-driven |
| **t6** | [switch USP whose BI Route Table capability is absent](t6.md) | guest-driven |
| **t7** | [RP not in 256B Flit mode, BI CFMWS](t7.md) | guest-driven |
| **t8** | ["68b DSP" mixed config: BI-capable endpoint under a DSP not in 256B Flit mode](t8.md) | guest-driven |
| **t35** | [switch USP not in 256B Flit, BI CFMWS + HDM-H CFMWS](t35.md) | guest-driven |
| **t9** | [cascaded switches: endpoint two switch hops from RP](t9.md) | guest-driven |
| **t10** | [two BI-capable endpoints under different root ports](t10.md) | guest-driven |
| **t11** | [PMEM HDM-DB region via a persistent memdev](t11.md) | guest-driven |
| **t12** | [one BI-capable + one non-BI endpoint, BI CFMWS](t12.md) | guest-driven |
| **t14** | [two CFMWS windows, one BI and one HDM-H](t14.md) | guest-driven |
| **t15** | [one endpoint, two CFMWS windows on one pxb](t15.md) | guest-driven |
| **t19** | [manual window-level 2-way HDM-DB interleave](t19.md) | guest-driven |
| **t20** | [manual interleave across mixed coherency models](t20.md) | guest-driven |
| **t31** | [eight BI-capable endpoints under one switch](t31.md) | guest-driven |
| **t32** | [4-way HDM-DB interleave across two switches under two host bridges](t32.md) | guest-driven |
| **t33** | [4-way HDM-DB interleave across two switches under one host bridge](t33.md) | guest-driven |
| **t34** | [refused attach and stale BI flag](t34.md) | guest-driven |
| **t21** | [BOTH-coherency endpoint behind a switch, BI + HDM-H windows on one pxb](t21.md) | guest-driven |
| **t22** | [BI endpoint that reports Unknown in Supported Coherency Models](t22.md) | guest-driven |
| **t18** | [concurrency storm topology](t18.md) | guest-driven |
| **t16** | [firmware-committed (auto-discovered) BI decoders](t16.md) | host-driven |
| **t17** | [QMP runtime hotplug of cxl-type3 endpoints](t17.md) | host-driven |
| **t23** | [BI-ID commit error/timeout legs (9.14.2)](t23.md) | host-driven |
| **t24** | [firmware adoption (auto-commit) of the BI path](t24.md) | host-driven |
| **t25** | [multi-level switch BI invariants](t25.md) | host-driven |
| **t26** | [Type 2 accelerator coherency (cxl-accel + HDM-DB)](t26.md) | host-driven |
| **t27** | [BI state across a device reset](t27.md) | host-driven |
| **t28** | [BI across AER fatal-error recovery (bounce -> wipe -> rebind)](t28.md) | host-driven |
| **t29** | [complex topology mixing Type 2 and Type 3 devices](t29.md) | host-driven |
| **t30** | [a device-coherent decoder vs the window's coherency restriction, on auto-assembly](t30.md) | host-driven |
| **t13** | [negative launch test: host-only + back-invalidate](t13.md) | host-driven |
