#!/bin/bash
# t10-cross-rp.sh - two BI-capable endpoints under different root ports.
#
#   pxb-cxl (cxl.1)
#     cxl-rp (rp0, flit)
#       cxl-type3 (mem0, hdm-db, flit)
#     cxl-rp (rp1, flit)
#       cxl-type3 (mem1, hdm-db, flit)
#
# Cross-RP interleave is a distinct code path: the region attaches
# targets that live below different Root Ports, so cxl_bi_setup runs
# once per endpoint, each bumping its RP's nr_bi independently.
#
# What t10 exercises:
#   - Two direct-attach BI walks in parallel through separate RPs.
#     Each RP ends up with dport->nr_bi = 1 after both endpoints bind.
#   - 2-way HDM-DB region across mem0+mem1: because both endpoints are
#     BI-capable and both RPs enabled BI, the region commits and both
#     endpoints' bi=1.
#   - When one endpoint is unbound, only its RP's nr_bi drops; the
#     other RP stays BI-enabled (verified via re-bind).
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-object memory-backend-ram,id=m1,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-rp,port=1,bus=cxl.1,id=rp1,chassis=0,slot=3,x-256b-flit=on \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=rp1,volatile-memdev=m1,id=mem1,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
