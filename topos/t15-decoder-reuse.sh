#!/bin/bash
# t15-decoder-reuse.sh - one endpoint, two CFMWS windows on one pxb.
#
#   pxb-cxl (cxl.1)
#     cxl-rp (rp0, flit)
#       cxl-type3 (mem0, hdm-db)
#
#   cxl-fmw.0 (targets=cxl.1, back-invalidate=on)  -> BI window
#   cxl-fmw.1 (targets=cxl.1)                      -> HDM-H window
#
# Unlike t14 (two windows, two pxbs, two endpoints), both windows here
# decode through the same root port, so the single endpoint decoder can
# be cycled through both region flavors:
#   - commit an HDM-DB region (decoder inherits DEVMEM, bi=1)
#   - delete it: the decoder must return to its default target_type
#   - commit an HDM-H region on the same decoder: must succeed with
#     bi=0 and without tripping the "mismatch decoder type" WARN in
#     cxl_rr_assign_decoder().
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on,\
cxl-fmw.1.targets.0=cxl.1,cxl-fmw.1.size=4G,cxl-fmw.1.interleave-granularity=4k
