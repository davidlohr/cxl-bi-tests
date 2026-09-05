#!/bin/bash
# t30-hdmd-window.sh - a device-coherent decoder vs the window's
# coherency restriction, on auto-assembly.
#
# HDM-D is a Type 2 flow (a Type 3 device never decodes device
# coherent), so the device under test is a cxl-accel. Two boots, both
# staging a firmware-committed HDM-D decoder (x-committed=hdm-d:
# TRT=0, BI=0 - device coherent, no BISnp, no BI machinery):
#
#   1. device-coherent window present (host-only=off): the legal
#      T2xHDM-D cell. The region must auto-assemble.
#   2. only a host-only-restricted window (device-coherent=off): the
#      staging falls back to it, emulating firmware that committed a
#      device-coherent decoder where the platform declared host-only.
#      The device and region agree on coherency, so the device gates
#      pass - only the window contradicts, and region assembly must
#      refuse ("coherency model not permitted by the window"). This is
#      the TRT axis of the same gate whose BI axis the v7 cover
#      letter's "BI decoder in a non-BI window" test exercises.
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

g() { guest_ssh "$@" 2>/dev/null; }

echo "# CXL HDM-D window-restriction suite t30"

if ! "$QEMU" -device help 2>/dev/null | grep -q '"cxl-accel"' ||
   ! "$QEMU" -device cxl-accel,help 2>/dev/null | grep -q "x-committed"; then
	for i in $(seq 1 11); do
		skip "qemu lacks cxl-accel with x-committed"
	done
	exit 0
fi

# --- boot 1: staged HDM-D accel, matching device-coherent window -----
launch_qemu \
  -object memory-backend-ram,id=m0,size=1G \
  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2 \
  -device cxl-accel,bus=rp0,volatile-memdev=m0,id=mem0,x-committed=hdm-d \
  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.host-only=off
if ! wait_for_guest 200; then
	if grep -qiE "x-committed must be|not a valid|invalid parameter" \
			"$RUNDIR/qemu.log" "$CONSOLE_LOG" 2>/dev/null; then
		for i in $(seq 1 11); do
			skip "qemu cxl-accel lacks the hdm-d flavor"
		done
		exit 0
	fi
	fail "hdm-d: guest booted"; exit 1
fi
ok "hdm-d: guest booted"

path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
ep=$(awk -F/ '{print $(NF-1)}' <<<"$path")
if [ "$(g "cat /sys/bus/pci/devices/$ep/device")" = 0x0d94 ]; then
	ok "hdm-d: device under test is the accel (0x0d94)"
else
	fail "hdm-d: device under test is the accel"
fi

region=$(g 'ls -d /sys/bus/cxl/devices/region* 2>/dev/null | head -1')
if [ -n "$region" ]; then
	ok "hdm-d: region auto-assembled ($(basename $region))"
else
	fail "hdm-d: region auto-assembled"
fi
if [ "$(g "cat $region/commit" 2>/dev/null)" = 1 ]; then
	ok "hdm-d: region committed"
else
	fail "hdm-d: region committed"
fi
bi=$(g 'cat /sys/bus/cxl/devices/endpoint*/decoder*.0/back_invalidate' 2>/dev/null)
if [ "$bi" = 0 ]; then
	ok "hdm-d: endpoint decoder bi=0 (HDM-D, not HDM-DB)"
else
	fail "hdm-d: endpoint decoder bi=0 (got '$bi')"
fi
dm=$(g dmesg)
if grep -q "coherency model not permitted" <<<"$dm"; then
	fail "hdm-d: no window refusal for the legal placement"
else
	ok "hdm-d: no window refusal for the legal placement"
fi
grep -qE "WARNING:|BUG:" <<<"$dm" &&
	fail "hdm-d: no splat" || ok "hdm-d: no splat"
g dmesg > "$OUT/t30-hdmd.dmesg" 2>/dev/null

# --- boot 2: same staging, only a host-only-restricted window --------
# device-coherent=off narrows the sole window to host-only (a bare
# window defaults to BOTH models, which legitimately permits either).
# The picker finds no device-coherent window and falls back, committing
# the accel's HDM-D decode where the platform declared host-only only.
launch_qemu \
  -object memory-backend-ram,id=m0,size=1G \
  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2 \
  -device cxl-accel,bus=rp0,volatile-memdev=m0,id=mem0,x-committed=hdm-d \
  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.device-coherent=off
if ! wait_for_guest 200; then
	fail "refusal: guest booted"; exit 1
fi
ok "refusal: guest booted"

dm=$(g dmesg)
if grep -q "coherency model not permitted by the window" <<<"$dm"; then
	ok "refusal: window gate refused the staged HDM-D decode"
else
	fail "refusal: window gate refused the staged HDM-D decode"
fi
region=$(g 'ls -d /sys/bus/cxl/devices/region* 2>/dev/null | head -1')
if [ -z "$region" ]; then
	ok "refusal: no region assembled"
else
	fail "refusal: no region assembled ($(basename $region))"
fi
if grep -q "failed to add to region" <<<"$dm"; then
	ok "refusal: discovery reported the refusal"
else
	fail "refusal: discovery reported the refusal"
fi
grep -qE "WARNING:|BUG:" <<<"$dm" &&
	fail "refusal: no splat" || ok "refusal: no splat"
g dmesg > "$OUT/t30-refusal.dmesg" 2>/dev/null

exit $((FAIL != 0))
