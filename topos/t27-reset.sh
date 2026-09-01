#!/bin/bash
# t27-reset.sh - BI state across a device reset.
#
# BI is enabled at endpoint probe, independently of any region, while
# the kernel's only reset detection (cxl_reset_done() ->
# cxl_endpoint_decoder_reset_detected()) keys off a previously
# committed decoder. A reset that wipes the device's BI Decoder
# Control with no region committed is therefore invisible: cxlds->bi
# stays true against BI Enable=0 in hardware, and a later HDM-DB
# region attach passes the !cxlds->bi gate on a device that can no
# longer issue BISnp.
#
# Two boots make the asymmetry concrete:
#   1. no-region: reset with nothing committed. The hardware clears BI
#      Enable (qemu re-runs cxl_component_register_init_common() on
#      device reset) and nothing in the kernel says a word.
#   2. with-region: reset with an HDM-DB region committed. The
#      existing decoder-based detection fires ("SBR happened without
#      memory regions removal"), showing the kernel notices the
#      decoder loss but still says nothing about BI.
#
# The kernel compares cxlds->bi against the hardware in .reset_done
# (cxl_bi_reset_detected) and fails closed, and cxl_bi_dealloc()
# unwinds unconditionally so the invalidated flag cannot leak the
# dport refcounts. Both are asserted hard; only the wipe premise
# itself (does the emulated reset clear the register) still SKIPs.
# The reset is driven through the kernel's own sysfs reset so the
# pci_error_handlers .reset_prepare/.reset_done path runs; a raw
# setpci poke would bypass it entirely.
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
oracle_silent() {
	if [ "$(grep -c "CXL BI oracle" "$RUNDIR/qemu.log" 2>/dev/null)" = 0 ]
	then
		ok "$1: qemu BI oracle silent"
	else
		fail "$1: qemu BI oracle silent"
	fi
}

# bi_ctrl <bdf> -> BI Decoder Control (cap ID 0xC), empty on failure.
bi_ctrl() {
	g "python3 - <<'PYEOF'
import ctypes, mmap, os
base = int(open('/sys/bus/pci/devices/$1/resource')
           .readline().split()[0], 16)
fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 4096, offset=base + 0x1000)
u32 = lambda o: ctypes.c_uint32.from_buffer(m, o).value
off = None
for i in range((u32(0) >> 24) & 0xff):
    e = u32(4 + 4 * i)
    if (e & 0xffff) == 0xc:
        off = (e >> 20) & 0xfff
assert off is not None, 'BI Decoder capability not found'
print('%#x' % u32(off + 4))
m.close(); os.close(fd)
PYEOF"
}

launch_t27() {
	launch_qemu \
	  -object memory-backend-ram,id=m0,size=1G \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	  -device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
}

# do_reset <tag> <ep-bdf>: reset through the kernel so the
# pci_error_handlers path runs. Echo the method actually used.
do_reset() {
	local tag=$1 ep=$2 method
	method=$(g "cat /sys/bus/pci/devices/$ep/reset_method 2>/dev/null")
	echo "# $tag: reset_method='$method'"
	if g "test -w /sys/bus/pci/devices/$ep/reset"; then
		g "echo 1 > /sys/bus/pci/devices/$ep/reset" >/dev/null
		return 0
	fi
	return 1
}

echo "# CXL BI reset suite t27"

# --- scenario 1: reset with no region committed ----------------------
launch_t27 || { fail "no-region: launch"; exit 1; }
if wait_for_guest 180; then
	ok "no-region: guest booted"
else
	fail "no-region: guest booted"; exit 1
fi

dm=$(g dmesg)
if grep -q "BI requests enabled" <<<"$dm"; then
	ok "no-region: BI enabled at probe"
else
	fail "no-region: BI enabled at probe"
fi

path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
ep=$(awk -F/ '{print $(NF-1)}' <<<"$path")
rp=$(awk -F/ '{print $(NF-2)}' <<<"$path")
echo "# ep=$ep rp=$rp"

epctl=$(bi_ctrl "$ep")
rpctl=$(bi_ctrl "$rp")
if [ -z "$epctl" ] || [ -z "$rpctl" ]; then
	for i in 1 2; do
		skip "no-region: baseline registers (no /dev/mem)"
	done
	HAVE_MMIO=0
else
	HAVE_MMIO=1
	[ $(( epctl & 0x2 )) = 2 ] && ok "no-region: endpoint BI Enable set" ||
		fail "no-region: endpoint BI Enable set ($epctl)"
	# Direct attach: the RP is the device-adjacent dport (Table 8-157).
	[ $(( rpctl & 0x3 )) = 2 ] && ok "no-region: RP Enable (direct attach)" ||
		fail "no-region: RP Enable ($rpctl)"
fi

g "dmesg -C" >/dev/null
if do_reset "no-region" "$ep"; then
	ok "no-region: reset issued through the kernel"
else
	fail "no-region: reset issued through the kernel"; exit 1
fi

for i in $(seq 1 30); do
	g "test -e /sys/bus/cxl/devices/mem0" && break
done
if g "test -e /sys/bus/cxl/devices/mem0"; then
	ok "no-region: memdev survives the reset"
else
	fail "no-region: memdev survives the reset"
fi

dm=$(g dmesg)
if [ "$HAVE_MMIO" = 1 ]; then
	epctl2=$(bi_ctrl "$ep")
	rpctl2=$(bi_ctrl "$rp")
	echo "# post-reset ep=$epctl2 rp=$rpctl2"
	if [ -z "$epctl2" ]; then
		skip "no-region: hardware cleared endpoint BI (readback lost)"
		skip "no-region: RP programming untouched by the reset"
		WIPED=0
	else
		if [ $(( epctl2 & 0x2 )) = 0 ]; then
			ok "no-region: hardware cleared endpoint BI"
			WIPED=1
		else
			# Not a kernel bug: the emulation simply did not wipe
			# the BI Decoder, so the staleness premise is absent.
			skip "no-region: reset did not clear endpoint BI ($epctl2)"
			WIPED=0
		fi
		# The reset is below the RP, so the RP's own BI Decoder must
		# keep whatever the kernel programmed.
		if [ "$rpctl2" = "$rpctl" ]; then
			ok "no-region: RP programming untouched by the reset"
		else
			fail "no-region: RP programming changed ($rpctl -> $rpctl2)"
		fi
	fi
else
	skip "no-region: hardware cleared endpoint BI (no /dev/mem)"
	skip "no-region: RP programming untouched by the reset"
	WIPED=0
fi

# The BI invalidation: hardware lost BI Enable behind the driver's
# back, so .reset_done must notice and fail the software state closed.
if [ "$WIPED" != 1 ]; then
	skip "no-region: kernel invalidates cxlds->bi (premise absent)"
	skip "no-region: post-reset HDM-DB attach fails closed"
	skip "no-region: refusal names the device gate"
	skip "no-region: unbind quiet after invalidation"
	skip "no-region: post-reset unbind unwinds the RP"
	skip "rebind: endpoint re-probed"
	skip "rebind: BI re-enabled from scratch"
	skip "rebind: endpoint BI Enable back in hardware"
	skip "rebind: RP re-programmed Enable"
	skip "rebind: HDM-DB region commits again"
	skip "rebind: endpoint bi=1"
else
	if grep -q "BI disabled by reset" <<<"$dm"; then
		ok "no-region: kernel invalidates cxlds->bi"
	else
		fail "no-region: kernel invalidates cxlds->bi"
	fi
	# The fail-closed consequence, end to end: with cxlds->bi
	# invalidated, an HDM-DB region attach must refuse rather than
	# commit device-coherent memory over a device that can no
	# longer issue BISnp.
	rd=$(g 'for d in /sys/bus/cxl/devices/decoder0.*; do
			[ -e "$d/cap_back_invalidate" ] || continue
			[ "$(cat $d/cap_back_invalidate)" = 1 ] &&
				basename $d && break
		done')
	region=$(g "cat /sys/bus/cxl/devices/$rd/create_ram_region")
	dec=$(g 'basename $(ls -d /sys/bus/cxl/devices/endpoint*/decoder*.0 | head -1)')
	g "CXL=/sys/bus/cxl/devices; sz=\$((256 << 20));
	   echo $region > \$CXL/$rd/create_ram_region;
	   R=\$CXL/$region;
	   echo 256 > \$R/interleave_granularity;
	   echo 1 > \$R/interleave_ways;
	   echo \$sz > \$R/size;
	   echo 0 > \$CXL/$dec/dpa_size 2>/dev/null;
	   echo ram > \$CXL/$dec/mode 2>/dev/null;
	   echo \$sz > \$CXL/$dec/dpa_size" >/dev/null
	if g "echo $dec > /sys/bus/cxl/devices/$region/target0"; then
		fail "no-region: post-reset HDM-DB attach fails closed"
	else
		ok "no-region: post-reset HDM-DB attach fails closed"
	fi
	if g dmesg | grep -q "BI not enabled on device"; then
		ok "no-region: refusal names the device gate"
	else
		fail "no-region: refusal names the device gate"
	fi
	g "echo $region > /sys/bus/cxl/devices/$rd/delete_region" \
		>/dev/null 2>&1
	# The invalidated flag must not leak the dport refcounts:
	# dealloc always unwinds, so the unbind still clears the RP,
	# and quietly - the endpoint disable sees hardware and
	# software agreeing on off.
	g "echo $ep > /sys/bus/pci/drivers/cxl_pci/unbind" >/dev/null
	for i in $(seq 1 30); do
		g "test -e /sys/bus/pci/devices/$ep/driver" || break
	done
	dm=$(g dmesg)
	if grep -q "BI already disabled in hardware" <<<"$dm"; then
		fail "no-region: unbind quiet after invalidation"
	else
		ok "no-region: unbind quiet after invalidation"
	fi
	rp2=$(bi_ctrl "$rp")
	if [ -z "$rp2" ]; then
		skip "no-region: post-reset unbind unwinds the RP (no /dev/mem)"
	elif [ $(( rp2 & 0x3 )) = 0 ]; then
		ok "no-region: post-reset unbind unwinds the RP"
	else
		fail "no-region: post-reset unbind unwinds the RP ($rp2)"
	fi
	# Recovery is a rebind, per the reset policy the kernel already
	# follows for decoders: no reprogramming in the handler, the
	# enable path re-runs from scratch at probe. The attach the
	# invalidated flag refused above must now work end to end.
	g "echo $ep > /sys/bus/pci/drivers/cxl_pci/bind" >/dev/null
	mem2=""
	for i in $(seq 1 60); do
		mem2=$(g "ls /sys/bus/pci/devices/$ep 2>/dev/null" | \
			grep '^mem' | head -1)
		[ -n "$mem2" ] && break
	done
	if [ -n "$mem2" ]; then
		ok "rebind: endpoint re-probed ($mem2)"
	else
		fail "rebind: endpoint re-probed"
	fi
	# dmesg was cleared before the reset, so the only enable this
	# window can hold is the rebind's own; the register readback
	# does not depend on dyndbg being enabled in the guest.
	dm=$(g dmesg)
	if grep -q "BI requests enabled" <<<"$dm"; then
		ok "rebind: BI re-enabled from scratch"
	else
		fail "rebind: BI re-enabled from scratch"
	fi
	ec2=$(bi_ctrl "$ep")
	if [ -z "$ec2" ]; then
		skip "rebind: endpoint BI Enable back in hardware (no /dev/mem)"
	elif [ $(( ec2 & 0x2 )) != 0 ]; then
		ok "rebind: endpoint BI Enable back in hardware"
	else
		fail "rebind: endpoint BI Enable back in hardware ($ec2)"
	fi
	rp3=$(bi_ctrl "$rp")
	if [ -z "$rp3" ]; then
		skip "rebind: RP re-programmed Enable (no /dev/mem)"
	elif [ $(( rp3 & 0x3 )) = 2 ]; then
		ok "rebind: RP re-programmed Enable"
	else
		fail "rebind: RP re-programmed Enable ($rp3)"
	fi
	dec2=$(g "for e in /sys/bus/cxl/devices/endpoint*; do
			[ \"\$(basename \$(readlink -f \$e/uport))\" = $mem2 ] &&
				basename \$(ls -d \$e/decoder*.0) && break
		done")
	region2=$(g "cat /sys/bus/cxl/devices/$rd/create_ram_region")
	g "CXL=/sys/bus/cxl/devices; sz=\$((256 << 20));
	   echo $region2 > \$CXL/$rd/create_ram_region;
	   R=\$CXL/$region2;
	   echo 256 > \$R/interleave_granularity;
	   echo 1 > \$R/interleave_ways;
	   echo \$sz > \$R/size;
	   echo 0 > \$CXL/$dec2/dpa_size 2>/dev/null;
	   echo ram > \$CXL/$dec2/mode 2>/dev/null;
	   echo \$sz > \$CXL/$dec2/dpa_size;
	   echo $dec2 > \$R/target0;
	   echo 1 > \$R/commit" >/dev/null
	if [ "$(g "cat /sys/bus/cxl/devices/$region2/commit" 2>/dev/null)" = 1 ]
	then
		ok "rebind: HDM-DB region commits again"
	else
		fail "rebind: HDM-DB region commits again"
	fi
	if [ "$(g "cat /sys/bus/cxl/devices/$dec2/back_invalidate" 2>/dev/null)" = 1 ]
	then
		ok "rebind: endpoint bi=1"
	else
		fail "rebind: endpoint bi=1"
	fi
fi

if grep -qE "WARNING:|BUG:" <<<"$dm"; then
	fail "no-region: no splat across the reset"
else
	ok "no-region: no splat across the reset"
fi
oracle_silent "no-region"
g dmesg > "$OUT/t27-no-region.dmesg" 2>/dev/null

# --- scenario 2: reset with an HDM-DB region committed ---------------
# Contrast: here the kernel's decoder-based detection has something to
# see, so it warns and taints - while still saying nothing about BI.
launch_t27 || { fail "with-region: launch"; exit 1; }
if wait_for_guest 180; then
	ok "with-region: guest booted"
else
	fail "with-region: guest booted"; exit 1
fi

rd=$(g 'for d in /sys/bus/cxl/devices/decoder0.*; do
		[ -e "$d/cap_back_invalidate" ] || continue
		[ "$(cat $d/cap_back_invalidate)" = 1 ] && basename $d && break
	done')
region=$(g "cat /sys/bus/cxl/devices/$rd/create_ram_region")
if [ -z "$rd" ] || [ -z "$region" ]; then
	fail "with-region: BI root decoder present"; exit 1
fi
ok "with-region: BI root decoder present ($rd)"

dec=$(g 'basename $(ls -d /sys/bus/cxl/devices/endpoint*/decoder*.0 | head -1)')
# Same order the guest phase helpers use: geometry, then reserve DPA on
# the endpoint decoder, then attach it as target0, then commit.
g "CXL=/sys/bus/cxl/devices; sz=\$((256 << 20));
   echo $region > \$CXL/$rd/create_ram_region;
   R=\$CXL/$region;
   echo 256 > \$R/interleave_granularity;
   echo 1 > \$R/interleave_ways;
   echo \$sz > \$R/size;
   echo 0 > \$CXL/$dec/dpa_size 2>/dev/null;
   echo ram > \$CXL/$dec/mode 2>/dev/null;
   echo \$sz > \$CXL/$dec/dpa_size;
   echo $dec > \$R/target0;
   echo 1 > \$R/commit" >/dev/null
if [ "$(g "cat /sys/bus/cxl/devices/$region/commit" 2>/dev/null)" = 1 ]; then
	ok "with-region: HDM-DB region committed"
else
	fail "with-region: HDM-DB region committed"
fi
if [ "$(g "cat /sys/bus/cxl/devices/$dec/back_invalidate")" = 1 ]; then
	ok "with-region: endpoint bi=1 before the reset"
else
	fail "with-region: endpoint bi=1 before the reset"
fi

path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
ep=$(awk -F/ '{print $(NF-1)}' <<<"$path")
g "dmesg -C" >/dev/null
do_reset "with-region" "$ep" || { fail "with-region: reset issued"; exit 1; }
ok "with-region: reset issued through the kernel"

for i in $(seq 1 30); do
	g "dmesg | grep -q 'SBR happened'" && break
done
dm=$(g dmesg)
# The pre-existing decoder-based detection. If the emulated reset does
# not decommit the decoder there is nothing for it to see, so SKIP
# rather than fail - the BI gap is the point of this suite either way.
if grep -q "SBR happened without memory regions removal" <<<"$dm"; then
	ok "with-region: decoder-loss detection fired"
else
	skip "with-region: decoder-loss detection fired (decoder not decommitted by the emulated reset)"
fi
if grep -q "BI disabled by reset" <<<"$dm"; then
	ok "with-region: BI invalidation reported alongside"
else
	fail "with-region: BI invalidation reported alongside"
fi
if grep -qE "BUG:" <<<"$dm"; then
	fail "with-region: no BUG across the reset"
else
	ok "with-region: no BUG across the reset"
fi
oracle_silent "with-region"
g dmesg > "$OUT/t27-with-region.dmesg" 2>/dev/null

# --- scenario 3: FLR must not trip the invalidation ------------------
# An FLR leaves the CXL.cache/mem component registers alone, so
# .reset_done should find BI Enable still set and stay silent. qemu's
# cxl-type3 does not advertise DEVCAP FLR today, so this self-SKIPs;
# the assertion is written hardware-first (warn iff the register was
# actually wiped) so a model that wires FLR to a full device reset
# still passes for the right reason once FLR appears.
launch_t27 || { fail "flr: launch"; exit 1; }
if wait_for_guest 180; then
	ok "flr: guest booted"
else
	fail "flr: guest booted"; exit 1
fi
path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
ep=$(awk -F/ '{print $(NF-1)}' <<<"$path")
if ! g "echo flr > /sys/bus/pci/devices/$ep/reset_method"; then
	skip "flr: FLR issued (device does not advertise FLR)"
	skip "flr: invalidation tracks the hardware across FLR"
else
	g "dmesg -C" >/dev/null
	if g "echo 1 > /sys/bus/pci/devices/$ep/reset"; then
		ok "flr: FLR issued"
	else
		fail "flr: FLR issued"
	fi
	ec=$(bi_ctrl "$ep")
	dm=$(g dmesg)
	warned=0; grep -q "BI disabled by reset" <<<"$dm" && warned=1
	if [ -z "$ec" ]; then
		skip "flr: invalidation tracks the hardware across FLR (no /dev/mem)"
	else
		wiped=$(( (ec & 0x2) == 0 ))
		if [ "$wiped" = "$warned" ]; then
			ok "flr: invalidation tracks the hardware across FLR (wiped=$wiped)"
		else
			fail "flr: warn/wipe mismatch (ctrl=$ec warned=$warned)"
		fi
	fi
fi
g dmesg > "$OUT/t27-flr.dmesg" 2>/dev/null

# --- scenario 4: reset below a switch --------------------------------
# The bus reset lands on the endpoint's bus, so the DSP and RP above
# keep their programming and their nr_bi. Invalidation must still
# fire, and the later unbind must unwind BOTH levels despite the
# invalidated flag - the multi-level form of the leak the
# unconditional dealloc exists to prevent.
launch_qemu \
  -object memory-backend-ram,id=m0,size=1G \
  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
  -device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
if wait_for_guest 180; then
	ok "switch: guest booted"
else
	fail "switch: guest booted"; exit 1
fi
path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
ep=$(awk -F/ '{print $(NF-1)}' <<<"$path")
dsp=$(awk -F/ '{print $(NF-2)}' <<<"$path")
rp=$(awk -F/ '{print $(NF-4)}' <<<"$path")
echo "# switch: reset_method='$(g "cat /sys/bus/pci/devices/$ep/reset_method")'"
g "dmesg -C" >/dev/null
if g "echo 1 > /sys/bus/pci/devices/$ep/reset"; then
	ok "switch: reset issued through the kernel"
else
	fail "switch: reset issued through the kernel"; exit 1
fi
dm=$(g dmesg)
ec=$(bi_ctrl "$ep")
if [ -z "$ec" ] || [ $(( ec & 0x2 )) != 0 ]; then
	for i in 1 2 3 4 5 6; do
		skip "switch: post-reset state (premise absent: ctrl='$ec')"
	done
else
	ok "switch: hardware cleared endpoint BI"
	if grep -q "BI disabled by reset" <<<"$dm"; then
		ok "switch: kernel invalidates cxlds->bi"
	else
		fail "switch: kernel invalidates cxlds->bi"
	fi
	# levels above the reset boundary keep their programming
	dctl=$(bi_ctrl "$dsp"); rctl=$(bi_ctrl "$rp")
	[ $(( dctl & 0x3 )) = 2 ] && ok "switch: DSP keeps Enable" ||
		fail "switch: DSP keeps Enable ($dctl)"
	[ $(( rctl & 0x3 )) = 1 ] && ok "switch: RP keeps Forward" ||
		fail "switch: RP keeps Forward ($rctl)"
	# and the invalidated flag must not leak either level
	g "echo $ep > /sys/bus/pci/drivers/cxl_pci/unbind" >/dev/null
	for i in $(seq 1 30); do
		g "test -e /sys/bus/pci/devices/$ep/driver" || break
	done
	dctl2=$(bi_ctrl "$dsp"); rctl2=$(bi_ctrl "$rp")
	[ $(( dctl2 & 0x3 )) = 0 ] && ok "switch: unbind unwinds the DSP" ||
		fail "switch: unbind unwinds the DSP ($dctl2)"
	[ $(( rctl2 & 0x3 )) = 0 ] && ok "switch: unbind unwinds the RP" ||
		fail "switch: unbind unwinds the RP ($rctl2)"
fi
dm=$(g dmesg)
grep -qE "WARNING:|BUG:" <<<"$dm" &&
	fail "switch: no splat" || ok "switch: no splat"
if [ "$(grep -c 'CXL BI oracle' "$RUNDIR/qemu.log" 2>/dev/null)" = 0 ]; then
	ok "switch: qemu BI oracle silent"
else
	fail "switch: qemu BI oracle silent"
fi
g dmesg > "$OUT/t27-switch.dmesg" 2>/dev/null

exit $((FAIL != 0))
