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
# Two CFMWS windows over the same host bridge: fmw.0 carries the BI
# restriction, fmw.1 is plain HDM-H.
#
# BI is a single-switch-level feature: a transit DSP would stamp its
# own Secondary Bus Number over the originating BI-ID (Table 9-13),
# so cxl_bi_probe_capable() refuses this topology outright. t9
# verifies:
#   - The refusal: bi_capable stays 0, "cascaded switches unsupported"
#     in dmesg, the BI window rejects the endpoint at attach ("BI not
#     enabled on device"), and the endpoint itself survives.
#   - Everything but BI works across the cascade: an HDM-H region on
#     fmw.1 creates and commits through both switches.
#   - Port lifecycle (phase 2): outer-port unbind tears the subtree
#     down, the emptied outer port is reaped, rebind rebuilds the
#     cascade, and the refusal re-fires on re-probe.
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
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on,\
cxl-fmw.1.targets.0=cxl.1,cxl-fmw.1.size=4G,cxl-fmw.1.interleave-granularity=4k
