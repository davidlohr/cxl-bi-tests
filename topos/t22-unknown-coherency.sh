#!/bin/bash
# t22-unknown-coherency.sh - BI endpoint that reports Unknown in
# Supported Coherency Models, under a BI CFMWS.
#
#   pxb-cxl (cxl.1)
#     cxl-rp (rp0, flit)
#       cxl-type3 (mem0, hdm-db, flit, x-coherency-unknown=on)
#
# Table 8-116 lets a device report 00b (Unknown) rather than naming the
# coherency models it supports, and that says nothing about whether the
# HDM Decoder Target Range Type bit is writable - Host+Device means RW,
# a single model means the bit may be hardwired to it, Unknown declares
# neither.
#
# The kernel does not refuse such a device: a Type 3 decoder defaults
# to host-only and inherits device-coherent when it joins an HDM-DB
# region, with cxlds->bi as the gate. Refusing on Unknown would also
# exclude devices that support both models without saying so.
#
# Every other topology here uses a device reporting Host+Device, so
# this is the only coverage of the Unknown path. Skips when QEMU has no
# knob to stage it.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

if ! "$QEMU" -device cxl-type3,help 2>&1 | grep -q "x-coherency-unknown"; then
	echo "1..0 # SKIP qemu lacks cxl-type3 x-coherency-unknown"
	exit 0
fi

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on,x-coherency-unknown=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
