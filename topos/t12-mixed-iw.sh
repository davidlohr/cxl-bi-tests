#!/bin/bash
# t12-mixed-iw.sh - one BI-capable + one non-BI endpoint, BI CFMWS.
#
#   pxb-cxl (cxl.1)
#     cxl-rp (rp0, flit)
#       cxl-upstream (us0, flit)
#         cxl-downstream (dsp0, flit)
#           cxl-type3 (mem0, hdm-db, flit)      <- BI capable
#         cxl-downstream (dsp1, flit)
#           cxl-type3 (mem1, flit)              <- no hdm-db
#
# What t12 exercises:
#   - Two independent cxl_bi_setup invocations: mem0 succeeds
#     (cxlds->bi=1), mem1 sees "BI not supported by topology" at the
#     endpoint check (its bi_decoder cap is missing) and stays bi=0.
#   - 1-way HDM-DB region on mem0: commits, mem0 bi=1.
#   - 1-way HDM-DB region on mem1: attach rejects with "BI not enabled
#     on device" (cxlds->bi=0), commit never fires.
#   - Attempted 2-way HDM-DB region across mem0+mem1: the attach for
#     mem1 rejects, so the region cannot reach the committed state.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-object memory-backend-ram,id=m1,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-downstream,port=1,bus=us0,id=dsp1,chassis=0,slot=5,x-256b-flit=on \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=dsp1,volatile-memdev=m1,id=mem1,x-256b-flit=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
