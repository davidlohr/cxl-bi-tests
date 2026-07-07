#!/bin/bash
# t11-pmem.sh - PMEM HDM-DB region via a persistent memdev.
#
# Same shape as t2 (endpoint under a switch, BI CFMWS) but the backing
# memory is persistent-memdev, so the tests exercise:
#   - can_create_pmem visibility on the BI root decoder (must be 1 for
#     an HDM-DB PMEM CFMWS: F_DEVMEM | F_BI | F_PMEM per patch 4)
#   - create_pmem_region on the BI root
#   - endpoint mode=pmem and endpoint decoder bi=1 after commit
#
# QEMU needs a file-backed memdev + LSA for persistent-memdev.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

# Create ephemeral pmem/lsa backing files under RUNDIR.
PMEM_FILE=${PMEM_FILE:-$RUNDIR/t11-pmem.raw}
LSA_FILE=${LSA_FILE:-$RUNDIR/t11-lsa.raw}
truncate -s 1G "$PMEM_FILE"
truncate -s 256M "$LSA_FILE"

launch_qemu \
	-object memory-backend-file,id=m0,share=on,mem-path="$PMEM_FILE",size=1G \
	-object memory-backend-file,id=lsa0,share=on,mem-path="$LSA_FILE",size=256M \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-type3,bus=dsp0,persistent-memdev=m0,lsa=lsa0,id=mem0,sn=0xbeef,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
