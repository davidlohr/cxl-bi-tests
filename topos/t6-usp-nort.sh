#!/bin/bash
# t6-usp-nort.sh - switch USP whose BI Route Table capability is absent.
#
# CXL 4.0 8.2.4.26 makes the BI RT capability optional on switch USPs.
# The kernel's cxl_is_bi_capable() reflects this: it requires a mapped
# BI Decoder on RP/DSP/endpoint but allows @bi==NULL on USPs. Note that
# QEMU's cxl-upstream currently always advertises BI RT alongside
# hdm-db; when a future QEMU flag lets us build a USP with no BI RT,
# swap it in below. Until then this suite doubles as a documentation
# marker for the code path so a regression on the "USP without RT is
# allowed" invariant surfaces here.
#
# Expected behaviour with QEMU today: same as t2 (BI enables fine on
# the topology). If/when QEMU grows an "x-bi-rt=off" flag on
# cxl-upstream, add it below and the guest test will verify that BI
# still enables and that no "BI RT registers not found" abort occurs.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

# NB: x-bi-rt is a placeholder for a knob that upstream QEMU may add.
# The comma-prefixed extension keeps the line intact if unset.
USP_EXTRA=${USP_EXTRA:-}

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on${USP_EXTRA:+,$USP_EXTRA} \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
