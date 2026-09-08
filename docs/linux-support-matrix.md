# Linux CXL Back-Invalidate: support matrix

What the `cxl-bi-support-v8` series (base v7.3-rc1) assembles, refuses,
and leaves alone, by coherency model, CFMWS Window Restriction, device
class and creation path. Every cell is taken from the driver as it
stands on 2026-09-08; the "verified by" column names the QEMU suite
under `../topos/` that exercises it, or says when a cell rests on code
reading alone.

Terms:

- **HDM-H**: host-only coherent. **HDM-D**: device coherent without
  Back-Invalidate (legacy Type 2). **HDM-DB**: device coherent with
  Back-Invalidate (Type 2 or Type 3).
- **manual**: a region created through sysfs, `create_ram_region` or
  `create_pmem_region` on a root decoder, targets written one by one.
- **auto**: a region assembled from decoders firmware committed before
  boot, matched to a window by HPA range, adopted or brought up by the
  kernel at endpoint probe.

## 1. Coherency model by creation path

| model | manual | auto | verified by |
|---|---|---|---|
| HDM-H | Supported under any window carrying the Host-only bit. The region type is host-only; endpoint decoders keep host-only, `back_invalidate=0`. | Supported. The first member's committed range type is host-only with the BI bit clear, in a window not restricted to Device Coherent alone. | t3, t14 (manual); t16 scenario 3 (auto) |
| HDM-DB | Supported only under a BI window, where the BI root forces the region type to device-coherent. Endpoint decoders inherit device-coherent, the BI bit is programmed at commit, `back_invalidate=1`. | Supported. Committed device-coherent with the BI bit set, in a BI window. A firmware-enabled BI path is adopted as-is; otherwise the kernel enables BI on the path at probe. | t1, t2, t5, t19, t29 (manual); t16 scenarios 1-2, t24 (auto) |
| HDM-D | Not creatable. A Device Coherent window without BI exposes no create attribute; Type 2 regions belong to their driver. | Supported. Committed device-coherent without BI, in a non-BI window not restricted to Host-only alone. The only way an HDM-D region exists. | t26 (no create attribute); t30 (auto) |

The region type on the manual path comes from the root decoder alone.
On the auto path it comes from the first member's committed type,
after that member passes the window check of section 2.

## 2. CFMWS Window Restrictions

Bits: 0 Device Coherent, 1 Host-only Coherent, 5 BI. The Volatile and
Persistent bits (2 and 3) additionally decide which create attribute a
window exposes, `create_ram_region` or `create_pmem_region`; they are
orthogonal to coherency and omitted below.

| bit0 DEV | bit1 HOST | bit5 BI | window | manual | auto |
|---|---|---|---|---|---|
| 0 | 0 | 0 | rejected at parse: "CFMWS has no coherency model" | - | - |
| 1 | 0 | 0 | kept | no create attribute | HDM-D only |
| 0 | 1 | 0 | kept | HDM-H | HDM-H only |
| 1 | 1 | 0 | kept | HDM-H | HDM-H or HDM-D, never both in one set |
| 1 | 0 | 1 | kept | HDM-DB | HDM-DB only |
| 0 | 0 | 1 | rejected at parse: "CFMWS BI requires device-coherent" | - | - |
| x | 1 | 1 | rejected at parse: "CFMWS cannot have both HDM-H and HDM-DB" | - | - |

Verified by: t13 (QEMU itself refuses Host-only with BI at launch; the
three kernel parse rejections have no QEMU or mock case, since neither
emulator builds such a window), t3 and t14 (HDM-H windows), t26 (a
Device Coherent window shows `cap_type2` but no create attribute), t30
(auto assembly refused by the window on both axes).

## 3. Device class, both paths

The driver never looks at the device class directly. Class enters
through two things the device advertises: the HDM's Supported
Coherency Models (host-only, device-only, both, or unknown) and whether
BI could be enabled on the path (256B flit end to end, BI Decoder and
BI Route Table capabilities present).

| device, HDM coherency advertised | HDM-H | HDM-DB | HDM-D | verified by |
|---|---|---|---|---|
| Type 3, host-only, no BI capability | yes | refused, "BI not enabled on device" | refused, "HDM is host-only coherent" (auto only) | t4, t12, t20 |
| Type 3, host-only, BI enabled | yes | refused, "HDM is host-only coherent" | refused, same | code reading; no emulator produces this pairing |
| Type 3 with hdm-db, both models | yes | yes | not creatable; on the auto path refused only by the window, not by class | t1-t29 (HDM-DB); t14 (HDM-H) |
| Type 2 accelerator, device-only | refused, "HDM is device-coherent only" | yes | auto only | t26, t29, t30 |
| any device, Unknown coherency | yes | yes | auto only | t22 |
| any device, 68B flit or BI capability missing on the path | yes | refused, "BI not enabled on device" | auto only | t4; t7 and t8 SKIP on upstream QEMU today (port flit knobs are cosmetic there) |

A mixed Type 2 and Type 3 HDM-DB interleave set is supported: t29 on
the manual path; by code reading on the auto path, no suite stages it.

Spec-valid cells are Type 3 with HDM-H or HDM-DB and Type 2 with HDM-D
or HDM-DB. The two invalid cells, Type 2 HDM-H and Type 3 HDM-D, are
refused when the HDM advertises a single model; a device advertising
both models is taken at its word on either path.

## 4. Refusals that exist on one path only

| stage | manual | auto | verified by |
|---|---|---|---|
| enumeration | none; decoders start unprogrammed | a committed decoder with BI and Host-only set, or with BI on a path that cannot do BI, is dropped with -ENXIO | code reading; neither emulator stages either shape |
| region creation | type dictated by the root, nothing to check | the first member's BI bit must equal the window's and its type must be permitted: "coherency model not permitted by the window" | t16 scenarios 4 and 5, t30 |
| joining members | the decoder inherits the region's type | the decoder must already match on both axes: "coherency model mismatch: `<committed>` vs `<region>`" | t16 scenarios 8 and 9 |
| mixed sets | a non-BI or host-only device is refused by the device checks | refused per member by the check above | t12, t20 (manual); t16 scenarios 8 and 9 (auto) |
| after a reset that clears BI | attach refused until rebind, "BI not enabled on device" | same, and a wiped committed decoder ends the region | t27 |

On both paths a refused member leaves the region unassembled and the
endpoint alive. The device checks, BI enabled, HDM coherency and
interleave capability, run identically on both paths.

## 5. Interleave shapes

| shape | manual | auto |
|---|---|---|
| 1-way, any switch depth | yes: t1, t2, t9, t25 | yes: t16, t24 |
| 2-way, one switch | yes: t5, t29 | - |
| 2-way, two host bridges (window-level) | yes: t19 | yes: t16 scenario 7 |
| 4-way and 8-way, one switch | yes: t31 | not stageable in QEMU |
| 4-way across two switches, two host bridges | yes: t32 | not stageable in QEMU |
| 4-way across two switches, one host bridge, two RPs | yes: t33 | not stageable in QEMU |
| pmem HDM-DB | yes: t11 | - |

QEMU stages committed decoders only for a directly attached device
under a passthrough host bridge, so auto sets wider than the window's
target count cannot be emulated.
