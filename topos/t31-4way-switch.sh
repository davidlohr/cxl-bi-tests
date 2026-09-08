#!/bin/bash
# t31-4way-switch.sh - eight BI-capable endpoints under one switch.
#
#   pxb-cxl (cxl.1)
#     cxl-rp (rp0, flit)
#       cxl-upstream (us0, flit)
#         cxl-downstream (dsp0..dsp7, flit)
#           cxl-type3 (mem0..mem7, hdm-db, flit)
#
# What t31 exercises beyond t5:
#   - Interleave wider than two: a 4-way HDM-DB region over four DSPs
#     and an 8-way region over all eight, at region granularity 256
#     (the window has one target, so the region granularity is free).
#     The USP decoder must be programmed iw=4 then iw=8 with the
#     target list reaching TARGET_LIST_HI.
#   - nr_bi beyond two on the shared RP: eight children raise it to
#     eight; seven releases must leave the RP forwarding for the
#     survivor, the eighth must clear it, and rebinding all eight must
#     bring it back without a leaked dport mapping.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=256M \
	-object memory-backend-ram,id=m1,size=256M \
	-object memory-backend-ram,id=m2,size=256M \
	-object memory-backend-ram,id=m3,size=256M \
	-object memory-backend-ram,id=m4,size=256M \
	-object memory-backend-ram,id=m5,size=256M \
	-object memory-backend-ram,id=m6,size=256M \
	-object memory-backend-ram,id=m7,size=256M \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-downstream,port=1,bus=us0,id=dsp1,chassis=0,slot=5,x-256b-flit=on \
	-device cxl-downstream,port=2,bus=us0,id=dsp2,chassis=0,slot=6,x-256b-flit=on \
	-device cxl-downstream,port=3,bus=us0,id=dsp3,chassis=0,slot=7,x-256b-flit=on \
	-device cxl-downstream,port=4,bus=us0,id=dsp4,chassis=0,slot=8,x-256b-flit=on \
	-device cxl-downstream,port=5,bus=us0,id=dsp5,chassis=0,slot=9,x-256b-flit=on \
	-device cxl-downstream,port=6,bus=us0,id=dsp6,chassis=0,slot=10,x-256b-flit=on \
	-device cxl-downstream,port=7,bus=us0,id=dsp7,chassis=0,slot=11,x-256b-flit=on \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=dsp1,volatile-memdev=m1,id=mem1,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=dsp2,volatile-memdev=m2,id=mem2,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=dsp3,volatile-memdev=m3,id=mem3,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=dsp4,volatile-memdev=m4,id=mem4,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=dsp5,volatile-memdev=m5,id=mem5,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=dsp6,volatile-memdev=m6,id=mem6,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=dsp7,volatile-memdev=m7,id=mem7,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
