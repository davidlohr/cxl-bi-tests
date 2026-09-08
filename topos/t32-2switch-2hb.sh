#!/bin/bash
# t32-2switch-2hb.sh - 4-way HDM-DB interleave across two switches
# under two host bridges: window-level 2-way times switch-level 2-way.
#
#   cxl-fmw.0 (BI, 4k granularity, TWO targets)
#     pxb-cxl (cxl.1) - cxl-rp (rp0) - cxl-upstream (us0)
#       cxl-downstream (dsp0) - cxl-type3 (mem0, hdm-db, flit)
#       cxl-downstream (dsp1) - cxl-type3 (mem1, hdm-db, flit)
#     pxb-cxl (cxl.2) - cxl-rp (rp1) - cxl-upstream (us1)
#       cxl-downstream (dsp2) - cxl-type3 (mem2, hdm-db, flit)
#       cxl-downstream (dsp3) - cxl-type3 (mem3, hdm-db, flit)
#
# What t32 exercises beyond t19 and t5:
#   - Two interleave levels at once: the root decoder is iw=2 across
#     the host bridges, each USP decoder must land iw=2 at granularity
#     8k (window granularity times window ways), the endpoints iw=4.
#   - Region positions are dport-major (pos = hb + 2 * dsp): wiring
#     the targets in plain BDF order puts two same-switch endpoints at
#     consecutive positions and must be refused before anything
#     commits; the dport-major order commits with bi=1 on all four.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=512M \
	-object memory-backend-ram,id=m1,size=512M \
	-object memory-backend-ram,id=m2,size=512M \
	-object memory-backend-ram,id=m3,size=512M \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device pxb-cxl,bus_nr=64,bus=pcie.0,id=cxl.2 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-rp,port=0,bus=cxl.2,id=rp1,chassis=1,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-downstream,port=1,bus=us0,id=dsp1,chassis=0,slot=5,x-256b-flit=on \
	-device cxl-upstream,bus=rp1,id=us1,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us1,id=dsp2,chassis=1,slot=4,x-256b-flit=on \
	-device cxl-downstream,port=1,bus=us1,id=dsp3,chassis=1,slot=5,x-256b-flit=on \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=dsp1,volatile-memdev=m1,id=mem1,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=dsp2,volatile-memdev=m2,id=mem2,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=dsp3,volatile-memdev=m3,id=mem3,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.targets.1=cxl.2,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
