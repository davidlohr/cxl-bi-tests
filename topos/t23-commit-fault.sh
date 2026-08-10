#!/bin/bash
# t23-commit-fault.sh - BI-ID commit error/timeout legs (9.14.2).
#
# The allocate/deallocate implementation notes make the DSP BI Decoder
# commit (steps 4d-4f) and the USP BI RT commit (steps 5d-5f) fallible:
# Error Not Committed and commit timeout must both be treated as error
# conditions. QEMU's x-bi-commit-fault knob (cxl-downstream: BI Decoder,
# cxl-upstream: BI RT) forces those outcomes, which are otherwise
# unreachable - the emulated commit always succeeds.
#
# Host-driven multi-boot suite (t16 style) on the t2 single-switch
# topology. Each scenario asserts the kernel refuses BI cleanly: the
# specific commit diagnostic, BI setup failure, endpoint bi=0 with the
# endpoint otherwise alive, and a silent qemu BI oracle throughout
# (the programming is topology-valid; only the commit outcome is
# forced, and the failure path must restore, not mis-program).
set -o pipefail
BI_TESTS_DIR=$(dirname "$(readlink -f "$0")")/..
source "$BI_TESTS_DIR/topo-lib.sh"
OUT=${OUT:-$RUNDIR/results}
mkdir -p "$OUT"

PASS=0; FAIL=0; N=0
ok()   { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - $1"; }
fail() { N=$((N+1)); FAIL=$((FAIL+1)); echo "not ok $N - $1"; }
skip() { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - # SKIP $1"; }
finish() {
	stop_qemu >/dev/null 2>&1
	echo "1..$N"
	echo "# passed: $PASS  failed: $FAIL"
}
trap finish EXIT

echo "# CXL BI commit-fault suite t23"

if ! "$QEMU" -device cxl-downstream,help 2>/dev/null | \
		grep -q "x-bi-commit-fault"; then
	skip "qemu lacks x-bi-commit-fault"
	exit 0
fi

launch_t23() { # launch_t23 <dsp-extra> <usp-extra>
	launch_qemu \
	  -object memory-backend-ram,id=m0,size=1G \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on$2 \
	  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on$1 \
	  -device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
}
g() { guest_ssh "$@" 2>/dev/null; }
dmesg_has() { [ "$(g dmesg | grep -c "$1")" -gt 0 ]; }

# check_refused <tag> <diagnostic regex>
check_refused() {
	if [ "$(g dmesg | grep -cE "$2")" -gt 0 ]; then
		ok "$1: commit diagnostic"
	else
		fail "$1: commit diagnostic"
	fi
	if dmesg_has "BI setup failed"; then
		ok "$1: BI setup refused"
	else
		fail "$1: BI setup refused"
	fi
	if [ "$(g 'cat /sys/bus/cxl/devices/endpoint*/decoder*.0/back_invalidate')" = 0 ]; then
		ok "$1: endpoint bi=0"
	else
		fail "$1: endpoint bi=0"
	fi
	if [ -n "$(g 'cat /sys/bus/cxl/devices/endpoint*/decoder*.0/mode')" ]; then
		ok "$1: endpoint survives"
	else
		fail "$1: endpoint survives"
	fi
	if [ "$(grep -c "CXL BI oracle" "$RUNDIR/qemu.log" 2>/dev/null)" = 0 ]; then
		ok "$1: qemu BI oracle silent"
	else
		fail "$1: qemu BI oracle silent"
	fi
}

# --- scenario 1: DSP BI Decoder commit error (alloc step 4e) ----------
launch_t23 ",x-bi-commit-fault=error" "" || { fail "dsp-err: launch"; exit 1; }
if wait_for_guest 180; then
	ok "dsp-err: guest booted"
else
	fail "dsp-err: guest booted"; exit 1
fi
check_refused "dsp-err" "pcieport.*BI-ID commit rejected by hardware"
g dmesg > "$OUT/t23-dsp-err.dmesg" 2>/dev/null

# --- scenario 2: USP BI RT commit error (alloc step 5d) ---------------
# The DSP decoder commit succeeds first; the RT rejection must undo the
# DSP enablement (register restore, oracle stays silent).
launch_t23 "" ",x-bi-commit-fault=error" || { fail "rt-err: launch"; exit 1; }
if wait_for_guest 180; then
	ok "rt-err: guest booted"
else
	fail "rt-err: guest booted"; exit 1
fi
check_refused "rt-err" "port[0-9]+: BI-ID commit rejected by hardware"
g dmesg > "$OUT/t23-rt-err.dmesg" 2>/dev/null

# --- scenario 3: DSP BI Decoder commit timeout (alloc step 4f) --------
launch_t23 ",x-bi-commit-fault=timeout" "" || { fail "dsp-tmo: launch"; exit 1; }
if wait_for_guest 180; then
	ok "dsp-tmo: guest booted"
else
	fail "dsp-tmo: guest booted"; exit 1
fi
check_refused "dsp-tmo" "BI-ID commit timed out"
g dmesg > "$OUT/t23-dsp-tmo.dmesg" 2>/dev/null

# --- scenario 4: USP BI RT commit timeout (alloc step 5f) -------------
launch_t23 "" ",x-bi-commit-fault=timeout" || { fail "rt-tmo: launch"; exit 1; }
if wait_for_guest 180; then
	ok "rt-tmo: guest booted"
else
	fail "rt-tmo: guest booted"; exit 1
fi
check_refused "rt-tmo" "BI-ID commit timed out"
g dmesg > "$OUT/t23-rt-tmo.dmesg" 2>/dev/null

# --- scenario 5: dealloc-time DSP commit error (dealloc step 4d) ------
# x-bi-commit-fault-after=1 lets the allocate-time commit succeed and
# fails the next one, which is the deallocation commit issued by the
# cxl_mem unbind. The dealloc path is best-effort: it must log the
# failed dport disable and still tear the endpoint down.
if ! "$QEMU" -device cxl-downstream,help 2>/dev/null | \
		grep -q "x-bi-commit-fault-after"; then
	skip "qemu cxl-downstream lacks x-bi-commit-fault-after (dealloc scenario)"
	exit $((FAIL != 0))
fi
launch_t23 ",x-bi-commit-fault=error,x-bi-commit-fault-after=1" "" || \
	{ fail "dealloc-err: launch"; exit 1; }
if wait_for_guest 180; then
	ok "dealloc-err: guest booted"
else
	fail "dealloc-err: guest booted"; exit 1
fi
# No region here, so decoder back_invalidate stays 0 by design (it
# requires an attached DEVMEM region); the device-level allocate is
# what must have succeeded.
if dmesg_has "BI requests enabled"; then
	ok "dealloc-err: BI allocated (fault armed for dealloc only)"
else
	fail "dealloc-err: BI allocated (fault armed for dealloc only)"
fi
g 'mem=$(ls /sys/bus/cxl/devices | grep -m1 "^mem")
bdf=$(readlink -f /sys/bus/cxl/devices/$mem | \
      grep -oE "[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]" | tail -1)
echo $bdf > /sys/bus/pci/drivers/cxl_pci/unbind'
sleep 3
if dmesg_has "BI-ID commit rejected by hardware"; then
	ok "dealloc-err: dealloc commit diagnostic"
else
	fail "dealloc-err: dealloc commit diagnostic"
fi
if dmesg_has "BI dport disable failed"; then
	ok "dealloc-err: best-effort disable logged"
else
	fail "dealloc-err: best-effort disable logged"
fi
if [ "$(g ls /sys/bus/cxl/devices/ | grep -c '^endpoint')" = 0 ]; then
	ok "dealloc-err: endpoint torn down despite commit error"
else
	fail "dealloc-err: endpoint torn down despite commit error"
fi
if [ "$(grep -c "CXL BI oracle" "$RUNDIR/qemu.log" 2>/dev/null)" = 0 ]; then
	ok "dealloc-err: qemu BI oracle silent"
else
	fail "dealloc-err: qemu BI oracle silent"
fi
g dmesg > "$OUT/t23-dealloc-err.dmesg" 2>/dev/null

exit $((FAIL != 0))
