#!/bin/bash
# t35-noflit-usp.sh - switch USP not in 256B Flit, BI CFMWS + HDM-H CFMWS.
#
# The CXL 4.0 9.14.3 mixed configuration that t7/t8 cannot reach:
# qemu re-syncs a downstream-facing port's LnkSta2 flit bit from its
# child, so cxl-rp and cxl-downstream cannot be held at 68B, but a
# cxl-upstream is never re-synced. With the USP at 68B and the DSP and
# endpoint at 256B, cxl_bi_probe_capable() must stop at the USP hop
# ("BI not supported by USP"), the endpoint stays bi=0, an HDM-DB
# attach fails closed and an HDM-H region still commits.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	-device cxl-upstream,bus=rp0,id=us0,x-256b-flit=off \
	-device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	-device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on,cxl-fmw.1.targets.0=cxl.1,cxl-fmw.1.size=4G,cxl-fmw.1.interleave-granularity=4k
