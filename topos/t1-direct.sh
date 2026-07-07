#!/bin/bash
# t1-direct.sh - the minimal BI topology: one root port, one cxl-type3
# directly under it, no switch. Establishes the happy path with the RP
# as the sole upstream hop between the endpoint and the cxl_root. Every
# BI wire prerequisite (256B Flit on RP, 256B Flit + hdm-db on the
# endpoint, back-invalidate on the CFMWS) is satisfied.
#
# What t1 exercises:
#   - cxl_bi_setup walks the topology: single dport (the RP), the
#     endpoint's BI Decoder is mapped, cxlds->bi ends up 1.
#   - Root decoder sysfs advertises cap_bi=1.
#   - A ram region created via the BI-restricted root decoder is a
#     DEVMEM region; endpoint decoder's bi=1 after commit.
#   - The RP's nr_bi bumps to 1 across the enable path (verifiable
#     indirectly by re-binding the same device in t2 phase 2).
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
