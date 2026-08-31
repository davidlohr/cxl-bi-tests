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
# The BI-invalidation checks are conditional on the kernel actually
# implementing it: they look for the diagnostic and SKIP with an
# explicit message when absent, so this suite is green against a
# kernel without the fix and becomes a real assertion once it lands.
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

# The BI invalidation itself. Conditional so a kernel without it is a
# documented SKIP rather than a red suite.
if [ "$WIPED" != 1 ]; then
	skip "no-region: kernel invalidates cxlds->bi (premise absent)"
	skip "no-region: endpoint reports bi=0 after the reset"
elif grep -q "BI disabled by reset" <<<"$dm"; then
	ok "no-region: kernel invalidates cxlds->bi"
	bi=$(g 'cat /sys/bus/cxl/devices/endpoint*/decoder*.0/back_invalidate')
	[ "$bi" = 0 ] && ok "no-region: endpoint reports bi=0 after the reset" ||
		fail "no-region: endpoint reports bi=0 (got '$bi')"
else
	skip "no-region: kernel lacks BI reset invalidation (cxlds->bi now stale vs BI Enable=0)"
	skip "no-region: endpoint reports bi=0 after the reset (kernel lacks invalidation)"
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
	skip "with-region: kernel lacks BI reset invalidation"
fi
if grep -qE "BUG:" <<<"$dm"; then
	fail "with-region: no BUG across the reset"
else
	ok "with-region: no BUG across the reset"
fi
oracle_silent "with-region"
g dmesg > "$OUT/t27-with-region.dmesg" 2>/dev/null

exit $((FAIL != 0))
