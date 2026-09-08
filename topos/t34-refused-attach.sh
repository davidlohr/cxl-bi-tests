#!/bin/bash
# t34-refused-attach.sh - t1's direct-attach shape, two regressions the
# v8 review turned up.
#
#   pxb-cxl (cxl.1)
#     cxl-rp (rp0, flit)
#       cxl-type3 (mem0, hdm-db, flit)
#
# What t34 exercises beyond t1:
#   - A refused attach must leave the decoder alone: the endpoint
#     decoder of a committed HDM-DB region A, written into a second
#     region's target, is refused (-EBUSY) and must keep A's
#     device-coherent type and bi=1; a re-commit of A must still
#     program the endpoint decoder with BI. The error path of
#     cxl_region_attach_position() used to reset the type to the
#     endpoint default although no inheritance had happened.
#   - BI dealloc must not trust a flag the hardware no longer backs:
#     BI Enable is cleared behind the driver through /dev/mem, standing
#     in for a reset .reset_done never sees, then the endpoint port is
#     unbound. The disable finds the hardware already clear; cxlds->bi
#     must come down with the port so a reset in the unbind-to-detach
#     window cannot read through the released BI Decoder mapping.
#     Recovery by rebind must enable BI from scratch. The race itself
#     is only best-effort here; the deterministic proof needs the
#     detach window widened, see ~/code/cxl-bi-repro.
#   - A reset between attach and commit must refuse the commit: a
#     region is created and its target attached but not committed, an
#     SBR (reset_method=cxl_bus) wipes the device's BI Enable and
#     .reset_done invalidates cxlds->bi, and the commit must then be
#     refused rather than program the endpoint decoder with BI on a
#     device whose BI Enable is 0. Recovery by rebind commits again.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
