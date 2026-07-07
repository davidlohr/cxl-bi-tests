#!/bin/bash
# t5-2way.sh - two BI-capable endpoints under one switch, 2-way region.
#
#   pxb-cxl (cxl.1)
#     cxl-rp (rp0, flit)
#       cxl-upstream (us0, flit)
#         cxl-downstream (dsp0, flit)
#           cxl-type3 (mem0, hdm-db, flit)
#         cxl-downstream (dsp1, flit)
#           cxl-type3 (mem1, hdm-db, flit)
#
# What t5 exercises beyond t2:
#   - Two independent cxl_mem_probe / cxl_bi_setup invocations sharing
#     the RP; both raise dport->nr_bi on the RP so the RP's BI Decoder
#     stays enabled while either endpoint is bound.
#   - 2-way interleaved HDM-DB region across mem0+mem1: commit
#     succeeds, both endpoints' bi=1.
#   - Phase 2 (nr_bi refcount) hot-removes one memdev and verifies
#     the RP's BI stays enabled for the surviving endpoint; removing
#     the second releases the RP.
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
	-device cxl-type3,bus=dsp1,volatile-memdev=m1,id=mem1,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
