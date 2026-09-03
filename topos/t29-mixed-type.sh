#!/bin/bash
# t29-mixed-type.sh - complex topology mixing Type 2 and Type 3 devices.
#
#   pxb-cxl (cxl.1)
#   |- rp0 - us0 -+- dsp0 - cxl-type3        (hdm-db, host+dev)
#   |            `- dsp1 - cxl-accel (type2) (hdm-db, dev-only)
#   `- rp1 - us1 -+- dsp2 - cxl-accel (type2)
#                `- dsp3 - cxl-type3
#
# Two switches, each carrying one Type 2 accelerator and one Type 3
# expander behind a shared BI window. Exercises BI where device
# coherency is heterogeneous:
#   - all four commit their own HDM-DB region; the two accelerators
#     inherit target_type=accelerator, the expanders too (HDM-DB is
#     device-coherent regardless of device class)
#   - a 2-way HDM-DB region interleaves a Type 2 and a Type 3 target
#     under one switch - mixed-coherency back-invalidate in one region
#   - teardown leaves every decoder reverted with no leak or splat
set -o pipefail
BI_TESTS_DIR=$(dirname "$(readlink -f "$0")")/..
source "$BI_TESTS_DIR/topo-lib.sh"
OUT=${OUT:-$RUNDIR/results}
mkdir -p "$OUT"

PASS=0; FAIL=0; N=0
ok()   { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - $1"; }
fail() { N=$((N+1)); FAIL=$((FAIL+1)); echo "not ok $N - $1"; }
skip() { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - # SKIP $1"; }
finish() { stop_qemu >/dev/null 2>&1; echo "1..$N"; echo "# passed: $PASS  failed: $FAIL"; }
trap finish EXIT
g() { guest_ssh "$@" 2>/dev/null; }
CXL=/sys/bus/cxl/devices

echo "# CXL BI mixed type2/type3 suite t29"
if ! "$QEMU" -device help 2>/dev/null | grep -q '"cxl-accel"'; then
	skip "qemu lacks the cxl-accel device - suite reserved"
	exit 0
fi
launch_qemu \
  -object memory-backend-ram,id=m0,size=1G -object memory-backend-ram,id=m1,size=1G \
  -object memory-backend-ram,id=m2,size=1G -object memory-backend-ram,id=m3,size=1G \
  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
  -device cxl-rp,port=1,bus=cxl.1,id=rp1,chassis=1,slot=3,x-256b-flit=on \
  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
  -device cxl-downstream,port=1,bus=us0,id=dsp1,chassis=0,slot=5,x-256b-flit=on \
  -device cxl-upstream,bus=rp1,id=us1,x-256b-flit=on \
  -device cxl-downstream,port=0,bus=us1,id=dsp2,chassis=1,slot=6,x-256b-flit=on \
  -device cxl-downstream,port=1,bus=us1,id=dsp3,chassis=1,slot=7,x-256b-flit=on \
  -device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
  -device cxl-accel,bus=dsp1,volatile-memdev=m1,id=acc1,x-256b-flit=on,hdm-db=on \
  -device cxl-accel,bus=dsp2,volatile-memdev=m2,id=acc2,x-256b-flit=on,hdm-db=on \
  -device cxl-type3,bus=dsp3,volatile-memdev=m3,id=mem3,x-256b-flit=on,hdm-db=on \
  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
if wait_for_guest 220; then
	ok "guest booted"
else
	if grep -qiE "not a valid device|invalid parameter|Property.*not found" \
			"$RUNDIR/qemu.log" "$CONSOLE_LOG" 2>/dev/null; then
		skip "qemu rejected the mixed topology - suite reserved"; exit 0
	fi
	fail "guest booted"; exit 1
fi

# Build a device table: for each memdev record type (2/3), switch group
# (middle cxl-port), endpoint decoder .0. Emitted as "memN type sw dec".
tbl=$(g '
for m in /sys/bus/cxl/devices/mem*; do
  mn=$(basename $m)
  bdf=$(readlink -f $m | awk -F/ "{print \$(NF-1)}")
  id=$(cat /sys/bus/pci/devices/$bdf/device)
  [ "$id" = 0x0d94 ] && ty=2 || ty=3
  for e in /sys/bus/cxl/devices/endpoint*; do
    [ "$(basename $(readlink -f $e/uport))" = "$mn" ] || continue
    sw=$(readlink -f $e | grep -o "port[0-9]*" | sed -n 2p)
    dec=$(basename $(ls -d $e/decoder*.0))
    echo "$mn $ty $sw $dec"
  done
done')
echo "$tbl" | sed 's/^/# /'
n2=$(echo "$tbl" | awk '$2==2' | wc -l)
n3=$(echo "$tbl" | awk '$2==3' | wc -l)
[ "$n2" = 2 ] && [ "$n3" = 2 ] &&
	ok "four devices bound: 2 Type 2, 2 Type 3" ||
	fail "device mix (type2=$n2 type3=$n3)"

bi_rd=$(g "for d in $CXL/decoder0.*; do
	[ \"\$(cat \$d/cap_back_invalidate 2>/dev/null)\" = 1 ] && basename \$d && break; done")
[ -n "$bi_rd" ] && ok "BI window present ($bi_rd)" || { fail "BI window present"; exit 1; }

# --- leg 1: each device commits its own HDM-DB region ---------------
g "dmesg -C" >/dev/null
declare -A REG
allbi=1; alltt=1
while read mn ty sw dec; do
	[ -z "$mn" ] && continue
	reg=$(g "cat $CXL/$bi_rd/create_ram_region")
	REG[$mn]=$reg
	g "sz=\$((256<<20)); R=$CXL/$reg
	   echo $reg > $CXL/$bi_rd/create_ram_region
	   echo 256 > \$R/interleave_granularity; echo 1 > \$R/interleave_ways
	   echo \$sz > \$R/size
	   echo ram > $CXL/$dec/mode; echo \$sz > $CXL/$dec/dpa_size
	   echo $dec > \$R/target0; echo 1 > \$R/commit" >/dev/null 2>&1
	[ "$(g cat $CXL/$reg/commit 2>/dev/null)" = 1 ] || { allbi=0; echo "# $mn($dec) commit failed"; }
	[ "$(g cat $CXL/$dec/back_invalidate 2>/dev/null)" = 1 ] || allbi=0
	[ "$(g cat $CXL/$dec/target_type 2>/dev/null)" = accelerator ] || alltt=0
done <<< "$tbl"
[ "$allbi" = 1 ] && ok "every device (type2 and type3) commits HDM-DB, bi=1" ||
	fail "every device commits HDM-DB, bi=1"
[ "$alltt" = 1 ] && ok "every HDM-DB decoder inherits target_type=accelerator" ||
	fail "target_type=accelerator on all"
g dmesg | grep -qE "WARNING:|BUG:" && fail "leg1: no splat" || ok "leg1: no splat"

# tear the singletons down before the interleave leg
while read mn ty sw dec; do
	[ -z "$mn" ] && continue
	g "echo 0 > $CXL/${REG[$mn]}/commit; echo $mn > /dev/null;
	   echo ${REG[$mn]} > $CXL/$bi_rd/delete_region" >/dev/null 2>&1
	g "echo 0 > $CXL/$dec/dpa_size" >/dev/null 2>&1
done <<< "$tbl"

# --- leg 2: mixed 2-way interleave, type2 + type3 under one switch ---
sw=$(echo "$tbl" | awk '{print $3}' | sort | uniq -d | head -1)
t3=$(echo "$tbl" | awk -v s="$sw" '$3==s && $2==3 {print $4; exit}')
t2=$(echo "$tbl" | awk -v s="$sw" '$3==s && $2==2 {print $4; exit}')
if [ -z "$t3" ] || [ -z "$t2" ]; then
	skip "mixed interleave (no type2+type3 sharing a switch)"
else
	g "dmesg -C" >/dev/null
	reg=$(g "cat $CXL/$bi_rd/create_ram_region")
	g "sz=\$((512<<20)); R=$CXL/$reg
	   echo $reg > $CXL/$bi_rd/create_ram_region
	   echo 256 > \$R/interleave_granularity; echo 2 > \$R/interleave_ways
	   echo \$sz > \$R/size
	   for d in $t3 $t2; do echo ram > $CXL/\$d/mode; echo \$((256<<20)) > $CXL/\$d/dpa_size; done
	   echo $t3 > \$R/target0; echo $t2 > \$R/target1; echo 1 > \$R/commit" >/dev/null 2>&1
	[ "$(g cat $CXL/$reg/commit 2>/dev/null)" = 1 ] &&
		ok "mixed 2-way HDM-DB region commits ($t3 + $t2)" ||
		fail "mixed 2-way HDM-DB region commits"
	[ "$(g cat $CXL/$t3/back_invalidate)" = 1 ] && [ "$(g cat $CXL/$t2/back_invalidate)" = 1 ] &&
		ok "both interleave targets bi=1 (type3 and type2)" ||
		fail "both interleave targets bi=1"
	g "echo 0 > $CXL/$reg/commit; echo $reg > $CXL/$bi_rd/delete_region" >/dev/null 2>&1
	g dmesg | grep -qE "WARNING:|BUG:" && fail "leg2: no splat" || ok "leg2: no splat"
fi

# --- teardown hygiene -----------------------------------------------
sleep 1
leaks=$(g "grep -l 1 $CXL/endpoint*/decoder*/back_invalidate 2>/dev/null" | wc -l)
[ "$leaks" = 0 ] && ok "all decoders reverted after teardown" ||
	fail "decoders still bi=1 after teardown ($leaks)"
if [ "$(grep -c "CXL BI oracle" "$RUNDIR/qemu.log" 2>/dev/null)" = 0 ]; then
	ok "qemu BI oracle silent"
else
	fail "qemu BI oracle silent"
fi
g dmesg > "$OUT/t29.dmesg" 2>/dev/null
exit $((FAIL != 0))
