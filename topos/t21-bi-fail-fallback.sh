#!/bin/bash
# t21-bi-fail-fallback.sh - BOTH-coherency endpoint behind a switch,
# BI + HDM-H windows on one pxb.
#
#   pxb-cxl (cxl.1)
#     cxl-rp (rp0, flit)
#       cxl-upstream (us0, flit)
#         cxl-downstream (dsp0, flit)
#           cxl-type3 (mem0, hdm-db, flit)
#
#   cxl-fmw.0 (targets=cxl.1, back-invalidate=on)  -> BI window
#   cxl-fmw.1 (targets=cxl.1)                      -> HDM-H window
#
# The hdm-db device advertises CXL_HDM_DECODER_COHERENCY_BOTH: its
# decoders default to host-only and only flip to device-coherent when
# an HDM-DB region claims them. The suite verifies that when BI setup
# fails at endpoint probe - staged via x-bi-commit-fault=timeout on
# the switch DSP, so its BI Decoder commit times out - the device
# fails closed for HDM-DB ("BI not enabled on device") but still
# commits host-only regions on the same decoder. On a qemu without
# the knob BI setup succeeds and the fallback checks SKIP.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

FAULT=",x-bi-commit-fault=timeout"
"$QEMU" -device cxl-downstream,help 2>/dev/null | \
	grep -q "x-bi-commit-fault" || FAULT=""

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on$FAULT \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on,\
cxl-fmw.1.targets.0=cxl.1,cxl-fmw.1.size=4G,cxl-fmw.1.interleave-granularity=4k
