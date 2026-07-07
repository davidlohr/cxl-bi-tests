#!/bin/bash
# t3-hdmh-cfmws.sh - BI-capable device under a plain (HDM-H) CFMWS.
#
# Same topology as t2 (BI-capable device under a switch), but the
# machine's CFMWS carries no back-invalidate restriction. This is the
# v5 cover letter's "Type3 device supports BI but CFMW does not" case.
# Expectations:
#   - cxl_bi_setup succeeds on the topology and cxlds->bi=1 (the
#     device path is BI-capable end-to-end).
#   - Root decoder's cap_bi=0 (CFMWS has no BI flag).
#   - A ram region created via the root decoder is HOSTONLYMEM, and
#     endpoint decoder's bi stays 0 after commit.
#   - Attempting to force the endpoint decoder into an HDM-DB region
#     is impossible: no BI-restricted root decoder exists.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k
