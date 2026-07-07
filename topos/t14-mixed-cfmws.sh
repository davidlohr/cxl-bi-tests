#!/bin/bash
# t14-mixed-cfmws.sh - two CFMWS windows, one BI and one HDM-H.
#
#   pxb-cxl (cxl.1)                 pxb-cxl (cxl.2)
#     cxl-rp (rp0, flit)              cxl-rp (rp1, flit)
#       cxl-type3 (mem0, hdm-db)        cxl-type3 (mem1, hdm-db)
#
#   cxl-fmw.0 (targets=cxl.1, back-invalidate=on)     -> BI window
#   cxl-fmw.1 (targets=cxl.2)                          -> HDM-H window
#
# What t14 exercises:
#   - Multiple root decoders present with distinct cap_bi values (one
#     1, one 0). The endpoint under RP0 is BI-eligible, the one under
#     RP1 is HDM-H eligible.
#   - Both endpoints are hdm-db capable (device-side BI is up for both).
#   - Creating a region under the BI root and attaching mem0 succeeds
#     with endpoint bi=1.
#   - Creating a region under the HDM-H root and attaching mem1
#     succeeds with endpoint bi=0.
#   - Cross-assignment (mem1 into BI root, mem0 into HDM-H root) is
#     rejected: mem1 lives outside the BI window's HPA range so its
#     host bridge is not a valid target for that root decoder.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-object memory-backend-ram,id=m1,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device pxb-cxl,bus_nr=222,bus=pcie.0,id=cxl.2 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-rp,port=0,bus=cxl.2,id=rp1,chassis=0,slot=3,x-256b-flit=on \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=rp1,volatile-memdev=m1,id=mem1,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on,\
cxl-fmw.1.targets.0=cxl.2,cxl-fmw.1.size=4G,cxl-fmw.1.interleave-granularity=4k
