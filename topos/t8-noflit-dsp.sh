#!/bin/bash
# t8-noflit-dsp.sh - "68b DSP" mixed config: BI-capable endpoint under
# a DSP that is not in 256B Flit mode.
#
# This models the CXL 4.0 §9.14.3 mixed configuration: a BI-capable
# device sitting on a Downstream Port whose link is not in 256B Flit
# mode. Per §9.14.3.3 System Software shall keep the BI bit unset on
# all decoders in the device / switch / host that span the device's
# HDM.
#
# Expectations:
#   - cxl_bi_setup's check loop finds cxl_is_bi_capable() false on the
#     DSP (no 256B Flit) and returns 0 silently; no dports get BI
#     enabled and cxlds->bi stays 0.
#   - Root decoder cap_back_invalidate=1 (CFMWS carries the flag).
#   - Region attach to a DEVMEM region rejects with -ENXIO.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=off \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
