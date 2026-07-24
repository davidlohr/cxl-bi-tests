#!/bin/bash
# t20-manual-mixed.sh - manual interleave across mixed coherency models.
#
#   cxl-fmw.0 (BI, 4k granularity, TWO targets)
#     pxb-cxl (cxl.1) - cxl-rp (rp0) - cxl-type3 (mem0, hdm-db, flit)
#     pxb-cxl (cxl.2) - cxl-rp (rp1) - cxl-type3 (mem1, PLAIN, flit)
#
# The regular (sysfs-driven) counterpart of t16's mixed committed set:
# a 2-way HDM-DB region attempted across one BI-capable and one
# host-only-coherent device must reject the plain target (the device
# gates in cxl_region_attach: "BI not enabled on device" /
# "HDM is host-only coherent") without WARNs, while a 1-way HDM-DB
# region on the BI-capable endpoint alone still commits. Flit stays on
# for both devices so coherency model is the only mixed axis.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-object memory-backend-ram,id=m1,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device pxb-cxl,bus_nr=64,bus=pcie.0,id=cxl.2 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-rp,port=0,bus=cxl.2,id=rp1,chassis=1,slot=2,x-256b-flit=on \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=rp1,volatile-memdev=m1,id=mem1,x-256b-flit=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.targets.1=cxl.2,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
