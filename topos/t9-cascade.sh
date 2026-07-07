#!/bin/bash
# t9-cascade.sh - cascaded switches: endpoint two switch hops from RP.
#
#   pxb-cxl (cxl.1)
#     cxl-rp (rp0, flit)
#       cxl-upstream (us0, flit)                # outer switch
#         cxl-downstream (dsp0, flit)
#           cxl-upstream (us1, flit)            # inner switch
#             cxl-downstream (dsp1, flit)
#               cxl-type3 (mem0, hdm-db, flit)
#
# What t9 exercises beyond t2:
#   - cxl_bi_setup walks two switch pairs (inner DSP + inner USP,
#     outer DSP + outer USP), then the RP. Every cxl_is_bi_capable()
#     check must pass and every dport's BI enable must commit.
#   - Cascaded USPs each map a BI RT (or tolerate the absence, per
#     8.2.4.26). Neither should be missed on rollback if enable fails.
#   - No CXL 4.0 spec text explicitly covers cascaded switches for BI
#     (see the review discussion around v5 patch 2's DSP nr_bi debate).
#     Kernel behaviour today is "walk everything, enable every dport
#     in the chain"; this suite makes any regression on that visible.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-upstream,bus=dsp0,id=us1,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us1,id=dsp1,chassis=0,slot=6,x-256b-flit=on \
	-device cxl-type3,bus=dsp1,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
