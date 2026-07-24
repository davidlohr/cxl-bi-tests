#!/bin/bash
# t18-storm.sh - concurrency storm topology: identical to t5 (two BI
# endpoints under one switch/RP), but driven by the t18 storm case in
# run-tests.sh:
#
#   - parallel unbind/bind flips of both endpoints (races nr_bi on the
#     shared RP, cxl_bi_setup/cxl_bi_dealloc, and devres teardown)
#     under a concurrent bi/cap_bi sysfs reader
#   - region create/commit/destroy churn with per-cycle timing (a
#     rollback regression that re-polls a failed dport shows up as a
#     5s+ jump in cycle time)
#   - dmesg hygiene across the whole storm: no WARN, no lockdep splat,
#     no refcount underflow, no leaked BI mappings
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-object memory-backend-ram,id=m1,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-downstream,port=1,bus=us0,id=dsp1,chassis=0,slot=5,x-256b-flit=on \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-device cxl-type3,bus=dsp1,volatile-memdev=m1,id=mem1,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
