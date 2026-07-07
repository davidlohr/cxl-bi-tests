#!/bin/bash
# t7-noflit-uplink.sh - endpoint not in 256B Flit mode, BI window.
#
# Same switched topology as t2 but the endpoint's uplink is not
# operating in 256B Flit mode. cxl_pci_flit_256(pdev) returns false, so
# cxl_is_bi_capable() bails early. cxl_bi_setup returns 0 silently and
# cxlds->bi stays 0.
#
# Expectations mirror t4 (device-side gate rather than device-cap gate):
#   - Root decoder cap_bi=1 (CFMWS carries the flag).
#   - Endpoint decoder attach to a DEVMEM region rejected with -ENXIO.
#   - HDM-H region not creatable from the BI-restricted root decoder,
#     so no successful commit is possible on this endpoint.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
