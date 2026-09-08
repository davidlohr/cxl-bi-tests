#!/bin/bash
# t16-autodiscover.sh - firmware-committed (auto-discovered) BI decoders.
#
# QEMU's x-committed=hdm-h|hdm-db (cxl-type3) emulates firmware having
# programmed and committed HDM decoder 0 against a fixed memory window
# before OS handoff, with the device's BI Enable set for hdm-db. The
# kernel is expected to adopt the inherited configuration: accept the
# committed decoder at enumeration, adopt the enabled BI state, and
# refuse a BI decoder under a window without the BI restriction (CXL
# 4.0 9.18.1.3 Window Restrictions).
#
# Host-driven multi-boot suite (like t13): each scenario needs its own
# QEMU command line, so this script launches the guests itself and
# emits TAP directly. Skips wholesale when QEMU lacks x-committed.
# A final combined machine (three host bridges, one scenario each)
# asserts per-device independence: window auto-selection with several
# windows present, and adoption on one device coexisting with the
# window reject on another in a single boot.
#
# Region auto-assembly through the passthrough host bridge additionally
# needs the out-of-series passthrough-decoder assembly patch; when the
# kernel lacks it ("region sort failed"), the assembly checks are
# emitted as documented SKIPs while adoption itself is still asserted.

set -o pipefail
BI_TESTS_DIR=$(dirname "$(readlink -f "$0")")/..
source "$BI_TESTS_DIR/topo-lib.sh"
OUT=${OUT:-$RUNDIR/results}
mkdir -p "$OUT"

PASS=0; FAIL=0; N=0
ok()   { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - $1"; }
fail() { N=$((N+1)); FAIL=$((FAIL+1)); echo "not ok $N - $1"; }
skip() { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - # SKIP $1"; }
# Always emit the TAP plan and summary, even on bail-out exits, and
# never leave a guest behind. An EXIT trap does not alter the exit
# status.
finish() {
	stop_qemu >/dev/null 2>&1
	echo "1..$N"
	echo "# passed: $PASS  failed: $FAIL"
}
trap finish EXIT

echo "# CXL BI auto-discovery (x-committed) suite t16"

if ! "$QEMU" -device cxl-type3,help 2>/dev/null | grep -q "x-committed"; then
	skip "qemu cxl-type3 lacks x-committed"
	exit 0
fi

# Fixed direct-attach topology: one RP under one host bridge (the
# passthrough shape x-committed supports), one endpoint decoder2.0.
DEC=decoder2.0
launch_t16() { # launch_t16 <device-extra> <fmw-extra>
	launch_qemu \
	  -object memory-backend-ram,id=m0,share=on,size=256M \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2 \
	  -device cxl-type3,bus=rp0,volatile-memdev=m0,id=vmem0,sn=0x1$1 \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k$2
}
g() { guest_ssh "$@" 2>/dev/null; }
# grep -q exits on first match and SIGPIPEs the ssh pipe, which
# pipefail then reports as failure exactly when the line is present;
# count matches instead so the pipe always drains.
dmesg_has() { [ "$(g dmesg | grep -c "$1")" -gt 0 ]; }

# Assembly checks are SKIPs when the kernel cannot assemble committed
# regions through the passthrough decoder (out-of-series patch).
assembly_gap() { dmesg_has "region sort failed"; }
check_assembled() { # check_assembled <tag>
	if assembly_gap; then
		skip "$1: region commit (kernel lacks passthrough assembly)"
		skip "$1: endpoint bi (kernel lacks passthrough assembly)"
		return
	fi
	if [ "$(g cat /sys/bus/cxl/devices/region0/commit)" = 1 ]; then
		ok "$1: auto-assembled region committed"
	else
		fail "$1: auto-assembled region committed"
	fi
	if [ "$(g cat /sys/bus/cxl/devices/$DEC/back_invalidate)" = 1 ]; then
		ok "$1: endpoint bi=1"
	else
		fail "$1: endpoint bi=1"
	fi
}

# --- scenario 1: hdm-db adoption --------------------------------------
launch_t16 ",x-256b-flit=on,hdm-db=on,x-committed=hdm-db" \
	",cxl-fmw.0.back-invalidate=on" || { fail "bi: qemu launch"; exit 1; }
if wait_for_guest 180; then
	ok "bi: guest booted with a committed HDM-DB decoder"
else
	fail "bi: guest booted with a committed HDM-DB decoder"; exit 1
fi
if dmesg_has "adopting firmware-enabled BI"; then
	ok "bi: firmware-enabled BI adopted"
else
	fail "bi: firmware-enabled BI adopted"
fi
if [ "$(g cat /sys/bus/cxl/devices/$DEC/mode)" = ram ]; then
	ok "bi: committed decoder enumerated (mode=ram)"
else
	fail "bi: committed decoder enumerated (mode=ram)"
fi
# Direct attach: the RP must terminate BI (BI Enable), not forward
# (Table 8-157) - asserted by register readback in t24's adopt
# scenario, and by the qemu -d guest_errors oracle below on every
# RP BI write.
if [ "$(grep -c "CXL BI oracle" "$RUNDIR/qemu.log" 2>/dev/null)" = 0 ]; then
	ok "bi: qemu RP BI oracle silent"
else
	fail "bi: qemu RP BI oracle silent"
fi
check_assembled "bi"
# Oracle self-test: mis-program the RP BI decoder from the guest
# (BI FW + BI Enable together, illegal per Table 8-157) and expect
# the oracle to flag it; restore the good value after. The RP's
# component block is BAR0, cachemem at +0x1000, BI decoder ctrl at
# +0xab8 (dmesg: "found BI Decoder capability (0xab4)" + 4). Skipped
# unless the readback shows the expected BI Enable-only value, and
# needs /dev/mem MMIO access (!CONFIG_IO_STRICT_DEVMEM). Gate on
# x-bi-commit-fault as the oracle's generation marker: a qemu without
# it predates the BI oracle and can never flag the poke.
if ! "$QEMU" -device cxl-downstream,help 2>/dev/null | \
		grep -q "x-bi-commit-fault"; then
	skip "bi: oracle fires on illegal RP program (qemu lacks BI oracle)"
else
	RPCTL=$(g 'python3 - <<PYEOF
import ctypes, mmap, os
base = int(open("/sys/bus/pci/devices/0000:0c:00.0/resource")
           .readline().split()[0], 16)
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 4096, offset=base + 0x1000)
reg = ctypes.c_uint32.from_buffer(m, 0xab8)
v = reg.value
print(hex(v))
if v == 0x2:
    reg.value = 0x3
    reg.value = 0x2
del reg
m.close(); os.close(fd)
PYEOF' 2>/dev/null)
	if [ "$RPCTL" != 0x2 ]; then
		skip "bi: oracle fires on illegal RP program (ctrl readback ${RPCTL:-none})"
	elif sleep 1; [ "$(grep -c "both set" "$RUNDIR/qemu.log" 2>/dev/null)" -gt 0 ]; then
		ok "bi: oracle fires on illegal RP program"
	else
		fail "bi: oracle fires on illegal RP program"
	fi
fi
g dmesg > "$OUT/t16.dmesg" 2>/dev/null

# --- scenario 2: re-adoption across guest reboot ----------------------
g reboot
sleep 3
if wait_for_guest 180; then
	ok "reboot: guest returned"
else
	fail "reboot: guest returned"; exit 1
fi
if dmesg_has "adopting firmware-enabled BI"; then
	ok "reboot: BI re-adopted after reset re-commit"
else
	fail "reboot: BI re-adopted after reset re-commit"
fi
check_assembled "reboot"

# --- scenario 3: hdm-h control ----------------------------------------
launch_t16 ",x-committed=hdm-h" "" || { fail "hdm-h: qemu launch"; exit 1; }
if wait_for_guest 180; then
	ok "hdm-h: guest booted with a committed HDM-H decoder"
else
	fail "hdm-h: guest booted with a committed HDM-H decoder"; exit 1
fi
if [ "$(g cat /sys/bus/cxl/devices/$DEC/mode)" = ram ]; then
	ok "hdm-h: committed decoder enumerated (mode=ram)"
else
	fail "hdm-h: committed decoder enumerated (mode=ram)"
fi
if [ "$(g cat /sys/bus/cxl/devices/$DEC/back_invalidate)" = 0 ]; then
	ok "hdm-h: endpoint bi=0"
else
	fail "hdm-h: endpoint bi=0"
fi
if assembly_gap; then
	skip "hdm-h: region commit (kernel lacks passthrough assembly)"
elif [ "$(g cat /sys/bus/cxl/devices/region0/commit)" = 1 ]; then
	ok "hdm-h: auto-assembled region committed"
else
	fail "hdm-h: auto-assembled region committed"
fi

# --- scenario 4: BI decoder under a non-BI window ---------------------
launch_t16 ",x-256b-flit=on,hdm-db=on,x-committed=hdm-db" "" || \
	{ fail "neg: qemu launch"; exit 1; }
if wait_for_guest 180; then
	ok "neg: guest booted (BI decoder, non-BI window)"
else
	fail "neg: guest booted (BI decoder, non-BI window)"; exit 1
fi
if dmesg_has "coherency model not permitted by the window"; then
	ok "neg: rejected per 9.18.1.3 Window Restrictions"
else
	fail "neg: rejected per 9.18.1.3 Window Restrictions"
fi
if [ "$(g ls /sys/bus/cxl/devices/ | grep -c '^region0$')" -gt 0 ]; then
	fail "neg: no region assembled"
else
	ok "neg: no region assembled"
fi
if [ "$(g cat /sys/bus/cxl/devices/$DEC/mode)" = ram ]; then
	ok "neg: endpoint survives (adopt-then-gate layering)"
else
	fail "neg: endpoint survives (adopt-then-gate layering)"
fi

# --- scenario 5: host-only decoder under a BI window ------------------
# The inverse of scenario 4: a committed HDM-H decoder whose HPA lands
# in a BI window. cxl_acpi_cfmws_verify() refuses a CFMWS that
# declares both Host-only Coherent and BI, so a BI window is never
# also a host-only one and the decoder's model is not what the window
# is for. Deliberately a lone device: with a BI peer present the peer
# constructs the region first and the reject arrives from the attach
# path instead of construct_region().
launch_t16 ",x-committed=hdm-h" ",cxl-fmw.0.back-invalidate=on" || \
	{ fail "hostonly-bi: qemu launch"; exit 1; }
if wait_for_guest 180; then
	ok "hostonly-bi: guest booted (HDM-H decoder, BI window)"
else
	fail "hostonly-bi: guest booted (HDM-H decoder, BI window)"; exit 1
fi
if dmesg_has "coherency model not permitted by the window"; then
	ok "hostonly-bi: rejected per 9.18.1.3 Window Restrictions"
else
	fail "hostonly-bi: rejected per 9.18.1.3 Window Restrictions"
fi
if [ "$(g ls /sys/bus/cxl/devices/ | grep -c '^region0$')" -gt 0 ]; then
	fail "hostonly-bi: no region assembled"
else
	ok "hostonly-bi: no region assembled"
fi
if [ "$(g cat /sys/bus/cxl/devices/$DEC/mode)" = ram ]; then
	ok "hostonly-bi: endpoint survives"
else
	fail "hostonly-bi: endpoint survives"
fi

# --- scenario 6: combined 3-HB machine (per-device independence) ------
# One boot, three single-RP host bridges: hdm-db in a BI window
# (adopts + assembles), hdm-h in a plain window (control), hdm-db in a
# plain window (rejected). Exercises x-committed window auto-selection
# with several windows present and the adopt/reject paths coexisting.
launch_qemu \
  -object memory-backend-ram,id=m0,share=on,size=256M \
  -object memory-backend-ram,id=m1,share=on,size=256M \
  -object memory-backend-ram,id=m2,share=on,size=256M \
  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
  -device pxb-cxl,bus_nr=64,bus=pcie.0,id=cxl.2 \
  -device pxb-cxl,bus_nr=128,bus=pcie.0,id=cxl.3 \
  -device cxl-rp,port=0,bus=cxl.1,id=rp1,chassis=0,slot=2 \
  -device cxl-rp,port=0,bus=cxl.2,id=rp2,chassis=1,slot=2 \
  -device cxl-rp,port=0,bus=cxl.3,id=rp3,chassis=2,slot=2 \
  -device cxl-type3,bus=rp1,volatile-memdev=m0,id=vmem0,sn=0x1,x-256b-flit=on,hdm-db=on,x-committed=hdm-db \
  -device cxl-type3,bus=rp2,volatile-memdev=m1,id=vmem1,sn=0x2,x-committed=hdm-h \
  -device cxl-type3,bus=rp3,volatile-memdev=m2,id=vmem2,sn=0x3,x-256b-flit=on,hdm-db=on,x-committed=hdm-db \
  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on,cxl-fmw.1.targets.0=cxl.2,cxl-fmw.1.size=4G,cxl-fmw.1.interleave-granularity=4k,cxl-fmw.2.targets.0=cxl.3,cxl-fmw.2.size=4G,cxl-fmw.2.interleave-granularity=4k \
  || { fail "combined: qemu launch"; exit 1; }
if wait_for_guest 180; then
	ok "combined: guest booted (3 HBs, one x-committed flavor each)"
else
	fail "combined: guest booted (3 HBs, one x-committed flavor each)"
	exit 1
fi

# Resolve each device's endpoint decoder by memdev serial number.
dec_of_sn() {
	g 'for m in /sys/bus/cxl/devices/mem*; do
		s=$(cat $m/serial 2>/dev/null)
		[ "$s" = "'"$1"'" ] || continue
		mem=$(basename $m)
		for ep in /sys/bus/cxl/devices/endpoint*; do
			[ -d "$ep" ] || continue
			u=$(basename $(readlink -f $ep/uport))
			[ "$u" = "$mem" ] || continue
			basename $(ls -d $ep/decoder*.0 | head -1)
			exit
		done
	done'
}
DA=$(dec_of_sn 0x1)
DB=$(dec_of_sn 0x2)
DC=$(dec_of_sn 0x3)
if [ -n "$DA" ] && [ -n "$DB" ] && [ -n "$DC" ]; then
	ok "combined: all three endpoints enumerated ($DA $DB $DC)"
else
	fail "combined: all three endpoints enumerated (DA=$DA DB=$DB DC=$DC)"
	exit 1
fi

nadopt=$(g dmesg | grep -c "adopting firmware-enabled BI")
if [ "$nadopt" = 2 ]; then
	ok "combined: both hdm-db devices adopted (2)"
else
	fail "combined: both hdm-db devices adopted (got $nadopt, want 2)"
fi
nrej=$(g dmesg | grep -c "coherency model not permitted by the window")
if [ "$nrej" = 1 ]; then
	ok "combined: exactly one non-BI-window reject"
else
	fail "combined: exactly one non-BI-window reject (got $nrej)"
fi
if assembly_gap; then
	skip "combined: two regions assembled (kernel lacks passthrough assembly)"
	skip "combined: hdm-db endpoint bi=1 (kernel lacks passthrough assembly)"
else
	nreg=$(g ls /sys/bus/cxl/devices/ | grep -c "^region[0-9]*$")
	if [ "$nreg" = 2 ]; then
		ok "combined: two regions assembled (BI + HDM-H)"
	else
		fail "combined: two regions assembled (got $nreg)"
	fi
	if [ "$(g cat /sys/bus/cxl/devices/$DA/back_invalidate)" = 1 ]; then
		ok "combined: hdm-db endpoint bi=1"
	else
		fail "combined: hdm-db endpoint bi=1"
	fi
fi
if [ "$(g cat /sys/bus/cxl/devices/$DB/back_invalidate)" = 0 ]; then
	ok "combined: hdm-h endpoint bi=0"
else
	fail "combined: hdm-h endpoint bi=0"
fi
if [ "$(g cat /sys/bus/cxl/devices/$DC/mode)" = ram ] && \
   [ "$(g cat /sys/bus/cxl/devices/$DC/back_invalidate)" = 0 ]; then
	ok "combined: rejected endpoint survives, bi=0"
else
	fail "combined: rejected endpoint survives, bi=0"
fi

# --- scenario 7: committed 2-way HDM-DB interleave (control) ----------
# One BI window targeting two passthrough HBs, both devices committing
# decoder 0 as members of the same 2-way set (x-committed-ways=2, the
# endpoint stride mirrors the window's routing). The set must
# auto-assemble into a single committed HDM-DB region.
launch_2way() { # launch_2way <second-device-props>
	launch_qemu \
	  -object memory-backend-ram,id=m0,share=on,size=256M \
	  -object memory-backend-ram,id=m1,share=on,size=256M \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device pxb-cxl,bus_nr=64,bus=pcie.0,id=cxl.2 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp1,chassis=0,slot=2 \
	  -device cxl-rp,port=0,bus=cxl.2,id=rp2,chassis=1,slot=2 \
	  -device cxl-type3,bus=rp1,volatile-memdev=m0,id=vmem0,sn=0x1,x-256b-flit=on,hdm-db=on,x-committed=hdm-db,x-committed-ways=2 \
	  -device cxl-type3,bus=rp2,volatile-memdev=m1,id=vmem1,sn=0x2,"$1" \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.targets.1=cxl.2,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
}
if ! "$QEMU" -device cxl-type3,help 2>/dev/null | grep -q "x-committed-ways"; then
	skip "qemu cxl-type3 lacks x-committed-ways (2-way + mixed scenarios)"
	exit $((FAIL != 0))
fi

launch_2way "x-256b-flit=on,hdm-db=on,x-committed=hdm-db,x-committed-ways=2" \
	|| { fail "2way: qemu launch"; exit 1; }
if wait_for_guest 180; then
	ok "2way: guest booted (committed 2-way HDM-DB set)"
else
	fail "2way: guest booted (committed 2-way HDM-DB set)"; exit 1
fi
if [ "$(g dmesg | grep -c 'adopting firmware-enabled BI')" = 2 ]; then
	ok "2way: both set members adopted"
else
	fail "2way: both set members adopted"
fi
if assembly_gap; then
	skip "2way: region commit (kernel lacks passthrough assembly)"
	skip "2way: both endpoints bi=1 (kernel lacks passthrough assembly)"
else
	if dmesg_has "created HDM-DB region" && \
	   [ "$(g cat /sys/bus/cxl/devices/region0/commit)" = 1 ]; then
		ok "2way: single HDM-DB region committed across the set"
	else
		fail "2way: single HDM-DB region committed across the set"
	fi
	DA=$(dec_of_sn 0x1)
	DB=$(dec_of_sn 0x2)
	if [ "$(g cat /sys/bus/cxl/devices/$DA/back_invalidate)" = 1 ] && \
	   [ "$(g cat /sys/bus/cxl/devices/$DB/back_invalidate)" = 1 ]; then
		ok "2way: both endpoints bi=1"
	else
		fail "2way: both endpoints bi=1"
	fi
fi

# --- scenario 8: mixed-coherency 2-way set must not assemble ----------
# Same window, same set, but the second member commits host-only
# (x-committed=hdm-h): a committed-BI decoder and a committed HDM-H
# decoder describing one interleave set. Whatever the construct order,
# this must never reach a committed region, and the committed-BI
# decoder's coherency model is hardware fact - it must not be silently
# coerced to the peer's model (the device is entitled to generate
# BISnp for any HPA covered by a local decoder with BI=1, Table 8-157).
launch_2way "x-committed=hdm-h,x-committed-ways=2" \
	|| { fail "mixed: qemu launch"; exit 1; }
if wait_for_guest 180; then
	ok "mixed: guest booted (BI + HDM-H committed 2-way set)"
else
	fail "mixed: guest booted (BI + HDM-H committed 2-way set)"; exit 1
fi
ncommitted=$(g 'c=0; for r in /sys/bus/cxl/devices/region*/commit; do
	[ -e "$r" ] && [ "$(cat "$r")" = 1 ] && c=$((c+1)); done; echo $c')
if [ "$ncommitted" = 0 ]; then
	ok "mixed: no committed region across the mixed set"
else
	fail "mixed: no committed region across the mixed set (got $ncommitted)"
fi
DA=$(dec_of_sn 0x1)
if [ "$(g cat /sys/bus/cxl/devices/$DA/mode)" = ram ] && \
   [ -n "$(dec_of_sn 0x2)" ]; then
	ok "mixed: both endpoints survive"
else
	fail "mixed: both endpoints survive"
fi
if [ "$(g cat /sys/bus/cxl/devices/$DA/target_type)" = accelerator ]; then
	ok "mixed: committed-BI decoder type preserved (accelerator)"
else
	fail "mixed: committed-BI decoder type preserved (got '$(g cat /sys/bus/cxl/devices/$DA/target_type)')"
fi
if assembly_gap; then
	skip "mixed: mismatch reject diagnostic (kernel lacks passthrough assembly)"
elif [ "$(g dmesg | grep -cE 'coherency model mismatch|mismatch decoder type|BI not enabled on device|coherency model not permitted by the window')" -gt 0 ]; then
	ok "mixed: mismatch rejected with a diagnostic"
else
	fail "mixed: mismatch rejected with a diagnostic"
fi

# --- scenario 9: mixed-TRT 2-way set (HDM-D accel + HDM-H type3) ------
# Class-honest members: the accel commits HDM-D (legal for a Type 2),
# the type3 commits HDM-H (legal for a Type 3, hdm-db capable so its
# coherency capability is BOTH). Firmware's sin is the set: one 2-way
# interleave under a window permitting both models (bare window, BOTH,
# non-BI), so every member passes the BI parity and the window check
# and only the committed range type contradicts across the set. The
# accel declines to report a coherency model (x-coherency-unknown,
# sanctioned by Table 8-116) so the supported-coherency checks cannot
# fire in either construct order: the committed-flavor range-type
# comparison is the only refusal standing between this set and a
# committed region. A kernel without it assembles the set.
if ! "$QEMU" -device help 2>/dev/null | grep -q '"cxl-accel"' ||
   ! "$QEMU" -device cxl-accel,help 2>/dev/null | grep -q "x-coherency-unknown"; then
	for i in $(seq 1 4); do
		skip "qemu lacks cxl-accel with x-coherency-unknown"
	done
	exit $((FAIL != 0))
fi
launch_qemu \
  -object memory-backend-ram,id=m0,share=on,size=256M \
  -object memory-backend-ram,id=m1,share=on,size=256M \
  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
  -device pxb-cxl,bus_nr=64,bus=pcie.0,id=cxl.2 \
  -device cxl-rp,port=0,bus=cxl.1,id=rp1,chassis=0,slot=2 \
  -device cxl-rp,port=0,bus=cxl.2,id=rp2,chassis=1,slot=2 \
  -device cxl-accel,bus=rp1,volatile-memdev=m0,id=accel0,x-coherency-unknown=on,x-committed=hdm-d,x-committed-ways=2 \
  -device cxl-type3,bus=rp2,volatile-memdev=m1,id=vmem1,sn=0x2,x-256b-flit=on,hdm-db=on,x-committed=hdm-h,x-committed-ways=2 \
  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.targets.1=cxl.2,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k
if ! wait_for_guest 180; then
	fail "mixed-trt: guest booted"; exit 1
fi
ok "mixed-trt: guest booted (HDM-D accel + HDM-H type3 2-way set)"
ncommitted=$(g 'c=0; for r in /sys/bus/cxl/devices/region*/commit; do
	[ -e "$r" ] && [ "$(cat "$r")" = 1 ] && c=$((c+1)); done; echo $c')
if [ "$ncommitted" = 0 ]; then
	ok "mixed-trt: no committed region across the set"
else
	fail "mixed-trt: no committed region across the set (got $ncommitted)"
fi
nmem=$(g 'ls -d /sys/bus/cxl/devices/mem* 2>/dev/null | wc -l')
if [ "$nmem" = 2 ]; then
	ok "mixed-trt: both endpoints survive"
else
	fail "mixed-trt: both endpoints survive (got $nmem)"
fi
if assembly_gap; then
	skip "mixed-trt: range-type mismatch refused (kernel lacks passthrough assembly)"
elif [ "$(g dmesg | grep -c 'coherency model mismatch')" -gt 0 ]; then
	ok "mixed-trt: range-type mismatch refused"
else
	fail "mixed-trt: range-type mismatch refused"
fi
g dmesg > "$OUT/t16-mixed-trt.dmesg" 2>/dev/null

exit $((FAIL != 0))
