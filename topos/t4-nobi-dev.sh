#!/bin/bash
# t4-nobi-dev.sh - non-BI device (no hdm-db) in a BI-restricted CFMWS.
#
# Same switched topology as t2, but the endpoint has hdm-db=off. This
# is the v5 cover letter's "Type3 device does not support BI, but CFMW
# has BI restriction" case.
# Expectations:
#   - cxl_bi_setup finds the endpoint's BI Decoder capability absent
#     and returns 0 silently; cxlds->bi stays 0.
#   - Root decoder's cap_bi=1 (CFMWS carries the flag).
#   - create_ram_region under the BI root produces a DEVMEM region,
#     but attaching the non-BI endpoint to it fails: cxl_region_attach
#     rejects with -ENXIO ("BI not enabled on device") because
#     cxlr->type==DEVMEM && cxl_root_decoder_is_bi(cxlrd) && !cxlds->bi.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
