#!/bin/bash
# t7-noflit-uplink.sh - RP not in 256B Flit mode, BI CFMWS.
#
# cxl_bi_setup walks the topology and calls cxl_is_bi_capable() on
# every hop; on the root port it checks cxl_pci_flit_256(pdev). When
# the RP is out of 256B Flit mode the walk bails at the RP hop and
# returns 0 silently. cxlds->bi ends up false, so a HDM-DB region
# attach later rejects with "BI not enabled on device".
#
# QEMU rejects hdm-db=on when the endpoint itself is not in flit mode
# (see cxl_type3.c: "hdm-db requires operating in 256b flit"), so
# t7 puts the non-flit hop on the RP instead. t8 covers the same code
# path at the DSP for symmetry.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=off \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
