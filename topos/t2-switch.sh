#!/bin/bash
# t2-switch.sh - single-switch happy path, one BI-capable endpoint.
#
#   pxb-cxl (cxl.1)
#     cxl-rp (rp0, flit)
#       cxl-upstream (us0, flit)
#         cxl-downstream (dsp0, flit)
#           cxl-type3 (mem0, hdm-db, flit)
#
# What t2 exercises beyond t1:
#   - The full DSP->USP->RP walk in cxl_bi_setup, including the USP's
#     optional BI Route Table cap (present here, absent in t6).
#   - cap_bi is only on root decoder(s); switch decoders should not
#     have a cap_bi file.
#   - Phase 2 (driven from run-all.sh) drives an unbind/rebind cycle
#     to prove the cxl_bi_dealloc/setup lifecycle: post-unbind BI must
#     be disabled on device and dports, post-rebind it must be back.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
