#!/bin/bash
# t13-hostonly-bi.sh - negative launch test: host-only + back-invalidate.
#
# Per the CXL 4.0 CFMWS Window Restrictions (9.18.1.3), a BI decoder
# mapped to a host-only window "will result in undefined behavior",
# so a window advertising both host-only coherency and back-invalidate
# is rejected. Upstream QEMU enforces this in the machine-init code
# (see hw/cxl/cxl-host.c: cxl_fixed_memory_window_...) so the launch
# itself must fail before the guest ever comes up.
#
# This suite is host-only: it does not need a booted guest. It emits
# TAP-ish output directly on stdout and exits 0 iff QEMU refused the
# machine with the expected error.
BI_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BI_TESTS_DIR/topo-lib.sh"

STDERR=$RUNDIR/t13-qemu-stderr.log
PASS=0; FAIL=0; N=0
ok()   { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - $1"; }
fail() { N=$((N+1)); FAIL=$((FAIL+1)); echo "not ok $N - $1"; }

echo "# CXL BI negative launch test - host-only + back-invalidate"

# Run QEMU in the foreground so its stderr is captured. -S -no-shutdown
# would keep it around; we just want it to reject the CFMWS.
"$QEMU" -smp 1 -m 512M \
	-machine q35,accel=kvm,cxl=on,\
cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,\
cxl-fmw.0.host-only=on,cxl-fmw.0.back-invalidate=on \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-display none -no-user-config -nodefaults \
	>/dev/null 2>"$STDERR" &
qpid=$!
wait "$qpid" 2>/dev/null
rc=$?

if [ "$rc" -eq 0 ]; then
	fail "QEMU refused host-only + back-invalidate CFMWS"
	echo "# QEMU accepted the invalid CFMWS (rc=$rc)"
elif grep -qEi "host-only.*(back-invalidate|BI)|CFMW.*host-only.*(BI|back-invalidate)" "$STDERR"; then
	ok "QEMU refused host-only + back-invalidate CFMWS"
else
	# QEMU errored, but on a different message. Still likely a launch
	# failure - print what we saw and mark as failed so the tester can
	# investigate.
	fail "QEMU error but not the expected host-only + BI message"
	echo "# QEMU stderr tail:"
	tail -5 "$STDERR" | sed 's/^/# /'
fi

echo "1..$N"
echo "# passed: $PASS  failed: $FAIL"
exit $((FAIL != 0))
