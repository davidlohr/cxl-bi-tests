#!/bin/bash
# t26-type2.sh - Type 2 accelerator coherency (cxl-accel + HDM-DB).
#
# The cxl-accel qemu device is a type3 subtype whose HDM Decoder
# Capability advertises Supported Coherency Models = device-coherent
# only (an accelerator computes on its memory). One boot, two devices,
# three windows:
#
#   pxb-cxl (cxl.1)
#   |- cxl-rp rp0 - cxl-accel accel0  (hdm-db=on, DEV-only coherency)
#   `- cxl-rp rp1 - cxl-type3 mem     (host+dev coherency)
#   fmw0: BI (HDM-DB)   fmw1: default (HDM-H)   fmw2: host-only=off (HDM-D)
#
# Positive arm: the accelerator commits an HDM-DB region with bi=1 -
# a Type 2 device on device-coherent memory, end to end. Negative arm:
# the same accelerator is refused an HDM-H attach ("HDM is
# device-coherent only") - the reject no other model can reach, since
# type3 advertises host+dev - while the plain type3 attaches to the
# same window as a control. The HDM-D window documents today's kernel
# gap: its root decoder carries cap_type2 without cap_back_invalidate,
# and can_create_ram() offers no create attr for the DEVMEM-without-BI
# combo, so the window is enumerable but not yet usable.
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

echo "# CXL BI type2 suite t26"
# Graceful skip on a qemu without the type2 model: probe the device
# list up front rather than letting the launch die into the boot
# timeout.
if ! "$QEMU" -device help 2>/dev/null | grep -q '"cxl-accel"'; then
	skip "qemu lacks the cxl-accel device - suite reserved"
	exit 0
fi
launch_qemu \
  -object memory-backend-ram,id=m0,size=1G \
  -object memory-backend-ram,id=m1,size=1G \
  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
  -device cxl-rp,port=1,bus=cxl.1,id=rp1,chassis=1,slot=3,x-256b-flit=on \
  -device cxl-accel,bus=rp0,volatile-memdev=m0,id=accel0,x-256b-flit=on,hdm-db=on \
  -device cxl-type3,bus=rp1,volatile-memdev=m1,id=mem1,x-256b-flit=on,hdm-db=on \
  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on,cxl-fmw.1.targets.0=cxl.1,cxl-fmw.1.size=4G,cxl-fmw.1.interleave-granularity=4k,cxl-fmw.2.targets.0=cxl.1,cxl-fmw.2.size=4G,cxl-fmw.2.interleave-granularity=4k,cxl-fmw.2.host-only=off
if wait_for_guest 200; then
	ok "guest booted"
else
	# a parameter rejection (e.g. no host-only window knob) is an
	# unsupported-qemu condition, not a harness failure
	if grep -qiE "not a valid device|invalid parameter|Property.*not found" \
			"$RUNDIR/qemu.log" "$CONSOLE_LOG" 2>/dev/null; then
		skip "qemu rejected the type2 topology - suite reserved"
		exit 0
	fi
	fail "guest booted"; exit 1
fi
CXL=/sys/bus/cxl/devices

# the accelerator is the memdev whose PCI function is device 0xd94
accel=""
for m in $(g "ls -d $CXL/mem*"); do
	bdf=$(g "readlink -f $m" | awk -F/ '{print $(NF-1)}')
	[ "$(g "cat /sys/bus/pci/devices/$bdf/device")" = 0x0d94 ] &&
		accel=$(basename $m) && break
done
if [ -n "$accel" ]; then
	ok "accelerator memdev bound by the CXL core ($accel)"
else
	fail "accelerator memdev bound by the CXL core"; exit 1
fi

# classify the three windows by root decoder flags
bi_rd=""; h_rd=""; d_rd=""
for d in $(g "ls -d $CXL/decoder0.*"); do
	dn=$(basename $d)
	bi=$(g "cat $d/cap_back_invalidate 2>/dev/null")
	t2=$(g "cat $d/cap_type2 2>/dev/null")
	t3=$(g "cat $d/cap_type3 2>/dev/null")
	if [ "$bi" = 1 ]; then bi_rd=$dn
	elif [ "$t2" = 1 ] && [ "$t3" = 0 ]; then d_rd=$dn
	elif [ "$t3" = 1 ]; then h_rd=$dn
	fi
done
[ -n "$bi_rd" ] && [ -n "$h_rd" ] && [ -n "$d_rd" ] &&
	ok "windows classified (BI=$bi_rd H=$h_rd D=$d_rd)" ||
	fail "windows classified (BI='$bi_rd' H='$h_rd' D='$d_rd')"

# HDM-D window: enumerable, flagged, but not yet creatable (kernel gap)
if g "test -e $CXL/$d_rd/create_ram_region"; then
	fail "HDM-D window has no create attr (kernel gap documented)"
else
	ok "HDM-D window has no create attr (kernel gap documented)"
fi

adec() { g "basename \$(readlink -f $CXL/$accel)" >/dev/null;
	g "for e in $CXL/endpoint*; do
		[ \"\$(basename \$(readlink -f \$e/uport))\" = $accel ] &&
			basename \$(ls -d \$e/decoder*.$1) && break; done"; }

# positive arm: HDM-DB region on the accelerator
g "dmesg -C" >/dev/null
dec=$(adec 0)
reg=$(g "cat $CXL/$bi_rd/create_ram_region")
g "sz=\$((256<<20)); echo $reg > $CXL/$bi_rd/create_ram_region;
   R=$CXL/$reg; echo 256 > \$R/interleave_granularity;
   echo 1 > \$R/interleave_ways; echo \$sz > \$R/size;
   echo ram > $CXL/$dec/mode; echo \$sz > $CXL/$dec/dpa_size;
   echo $dec > \$R/target0; echo 1 > \$R/commit" >/dev/null
[ "$(g cat $CXL/$reg/commit 2>/dev/null)" = 1 ] &&
	ok "accel HDM-DB region committed" ||
	fail "accel HDM-DB region committed"
[ "$(g cat $CXL/$dec/back_invalidate 2>/dev/null)" = 1 ] &&
	ok "accel back_invalidate=1" || fail "accel back_invalidate=1"
[ "$(g cat $CXL/$dec/target_type 2>/dev/null)" = accelerator ] &&
	ok "accel decoder target_type=accelerator" ||
	fail "accel decoder target_type=accelerator"

# negative arm: HDM-H attach on the DEV-only accelerator must refuse
dec2=$(adec 1)
reg2=$(g "cat $CXL/$h_rd/create_ram_region")
g "sz=\$((256<<20)); echo $reg2 > $CXL/$h_rd/create_ram_region;
   R=$CXL/$reg2; echo 256 > \$R/interleave_granularity;
   echo 1 > \$R/interleave_ways; echo \$sz > \$R/size;
   echo ram > $CXL/$dec2/mode; echo \$sz > $CXL/$dec2/dpa_size" >/dev/null
if g "echo $dec2 > $CXL/$reg2/target0"; then
	fail "accel refused HDM-H attach"
else
	ok "accel refused HDM-H attach"
fi
g "dmesg | grep -q 'HDM is device-coherent only'" &&
	ok "refusal names device-coherent-only HDM" ||
	fail "refusal names device-coherent-only HDM"

# control: the plain type3 attaches to the same HDM-H window
mem3=""
for m in $(g "ls -d $CXL/mem*"); do
	[ "$(basename $m)" != "$accel" ] && mem3=$(basename $m) && break
done
dec3=$(g "for e in $CXL/endpoint*; do
	[ \"\$(basename \$(readlink -f \$e/uport))\" = $mem3 ] &&
		basename \$(ls -d \$e/decoder*.0) && break; done")
g "sz=\$((256<<20)); echo ram > $CXL/$dec3/mode;
   echo \$sz > $CXL/$dec3/dpa_size;
   echo $dec3 > $CXL/$reg2/target0; echo 1 > $CXL/$reg2/commit" >/dev/null
[ "$(g cat $CXL/$reg2/commit 2>/dev/null)" = 1 ] &&
	ok "type3 control commits on the same HDM-H window" ||
	fail "type3 control commits on the same HDM-H window"

if g dmesg | grep -qE "WARNING:|BUG:"; then
	fail "no splat"
else
	ok "no splat"
fi
if [ "$(grep -c "CXL BI oracle" "$RUNDIR/qemu.log" 2>/dev/null)" = 0 ]; then
	ok "qemu BI oracle silent"
else
	fail "qemu BI oracle silent"
fi
g dmesg > "$OUT/t26.dmesg" 2>/dev/null
exit $((FAIL != 0))
