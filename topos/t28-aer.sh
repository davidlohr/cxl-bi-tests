#!/bin/bash
# t28-aer.sh - BI across AER fatal-error recovery (bounce -> wipe -> rebind).
#
# A sysfs reset (t27) runs the pci_error_handlers .reset_done path; an
# AER Uncorrectable Fatal takes an entirely different one. The chain,
# end to end: the endpoint reports the error, the root port's AER irq
# thread runs pcie_do_recovery(io_frozen), cxl_error_detected() bounces
# the memdev driver (device_release_driver) BEFORE the link reset -
# tearing region, decoders and BI down through the normal devres
# cascade - then aer_root_reset() pulses a secondary bus reset with
# PCI_RESET_NO_RESTORE, so .reset_prepare/.reset_done NEVER run and
# cxl_bi_reset_detected() has no role by construction: the unbind
# precedes the wipe. cxl_slot_reset() then restores config space and
# device_attach() rebinds the memdev synchronously, re-running the BI
# enable path from scratch.
#
# Scenario A (no region): inject MALF_TLP (fatal by default
# Uncorrectable Error Severity) into the endpoint and follow the whole
# chain by its always-on printks; assert .reset_done stayed silent and
# BI is back up - registers reprogrammed, a fresh HDM-DB region
# commits - after the automatic rebind.
# Scenario B (committed HDM-DB region): the bounce must tear the live
# region down cleanly before the link reset, and recovery must still
# come back to a working BI path.
#
# Premises (SKIP, not fail): the guest kernel must have CONFIG_PCIEAER
# (aer_rootport_* sysfs attrs on the RP) and CONFIG_CXL_RAS (else
# cxl_error_detected is a stub returning PCI_ERS_RESULT_NONE and the
# bounce never happens - visible as cxl_error_detected missing from
# kallsyms), and qemu must accept the HMP injection. The guest boots
# with pcie_ports=native so the OS claims AER regardless of _OSC.
set -o pipefail
EXTRA_APPEND="pcie_ports=native${EXTRA_APPEND:+ $EXTRA_APPEND}"
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

# splat_check <tag> <dmesg>: any WARNING/BUG fails, except the one
# known upstream lockdep this suite itself surfaced - AER recovery
# takes pci_bus_sem (pci_walk_bus) then the memdev lock
# (cxl_error_detected), inverting the probe-side memdev -> port ->
# pci_bus_sem order. Pre-existing in v7.2-rc6, no BI code in any
# chain; diagnosed, not failed.
splat_check() {
	local tag=$1 dm=$2 w c
	w=$(grep -c "WARNING" <<<"$dm")
	c=$(grep -c "WARNING: possible circular locking" <<<"$dm")
	if grep -qE "BUG:" <<<"$dm"; then
		fail "$tag: no splat"
	elif [ "$w" = 0 ]; then
		ok "$tag: no splat"
	elif [ "$w" = "$c" ] && grep -q "cxl_error_detected" <<<"$dm"; then
		echo "# known upstream lockdep: AER recovery (pci_bus_sem ->"
		echo "# cxl_memdev_key) vs cxl probe (memdev -> port -> pci_bus_sem)"
		ok "$tag: no splat beyond the known upstream lockdep"
	else
		fail "$tag: no splat"
	fi
}
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
PYEOF" 2>/dev/null
}

launch_t28() {
	launch_qemu \
	  -object memory-backend-ram,id=m0,size=1G \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	  -device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
}

# inject_fatal: MALF_TLP is fatal by the device's default Uncorrectable
# Error Severity register; INTN would be masked by default and never
# reach the guest. Echoes qemu's HMP response.
inject_fatal() {
	qmp_cmd '{"execute":"human-monitor-command","arguments":{"command-line":"pcie_aer_inject_error mem0 MALF_TLP"}}'
}

# wait_recovery: the whole flow runs in the AER irq thread, async to
# the injection; poll for the terminal verdict from pcie/err.c.
wait_recovery() {
	local i
	for i in $(seq 1 90); do
		dm=$(g dmesg)
		grep -qE "device recovery (successful|failed)" <<<"$dm" &&
			return 0
		g "sleep 1"
	done
	return 1
}

# create_region <tag>: fresh HDM-DB region on the current endpoint,
# committed, bi=1. Sets $region.
create_region() {
	local tag=$1 rd dec
	rd=$(g 'for d in /sys/bus/cxl/devices/decoder0.*; do
			[ -e "$d/cap_back_invalidate" ] || continue
			[ "$(cat $d/cap_back_invalidate)" = 1 ] &&
				basename $d && break
		done')
	region=$(g "cat /sys/bus/cxl/devices/$rd/create_ram_region")
	dec=$(g 'basename $(ls -d /sys/bus/cxl/devices/endpoint*/decoder*.0 | head -1)')
	if [ -z "$rd" ] || [ -z "$region" ] || [ -z "$dec" ]; then
		fail "$tag: HDM-DB region commits (no decoder)"
		return 1
	fi
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
	if [ "$(g "cat /sys/bus/cxl/devices/$region/commit" 2>/dev/null)" = 1 ] &&
	   [ "$(g "cat /sys/bus/cxl/devices/$dec/back_invalidate" 2>/dev/null)" = 1 ]
	then
		ok "$tag: HDM-DB region commits, bi=1 ($region)"
	else
		fail "$tag: HDM-DB region commits, bi=1"
	fi
}

echo "# CXL BI AER recovery suite t28"

# --- scenario A: fatal error with no region --------------------------
launch_t28 || { fail "aer: launch"; exit 1; }
if wait_for_guest 180; then
	ok "aer: guest booted"
else
	fail "aer: guest booted"; exit 1
fi
path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
ep=$(awk -F/ '{print $(NF-1)}' <<<"$path")
rp=$(awk -F/ '{print $(NF-2)}' <<<"$path")
echo "# ep=$ep rp=$rp"

if ! g "ls /sys/bus/pci/devices/$rp/" | grep -q aer_rootport; then
	skip "aer: premise absent (guest kernel lacks CONFIG_PCIEAER)"
	exit 0
fi
if ! g "grep -qw cxl_error_detected /proc/kallsyms"; then
	skip "aer: premise absent (guest kernel lacks CONFIG_CXL_RAS)"
	exit 0
fi
ok "aer: kernel AER + CXL_RAS present"

ec=$(bi_ctrl "$ep")
if [ -n "$ec" ] && [ $(( ec & 0x2 )) != 0 ]; then
	ok "aer: BI enabled at probe"
else
	skip "aer: BI enabled at probe (no /dev/mem readback: '$ec')"
fi

g "dmesg -C" >/dev/null
r=$(inject_fatal)
if grep -q "OK id: mem0" <<<"$r"; then
	ok "aer: MALF_TLP injected"
else
	skip "aer: qemu rejected AER injection: $r"
	exit 0
fi

if ! wait_recovery; then
	fail "aer: recovery reached a verdict"
	echo "$dm" | tail -30 | sed 's/^/# /'
	exit 1
fi

grep -qi "Uncorrectable (Fatal) error message received" <<<"$dm" &&
	ok "aer: root port saw the fatal error" ||
	fail "aer: root port saw the fatal error"
grep -q "frozen state error detected, disable CXL.mem" <<<"$dm" &&
	ok "aer: cxl_error_detected bounced the memdev" ||
	fail "aer: cxl_error_detected bounced the memdev"
grep -q "BI requests disabled" <<<"$dm" &&
	ok "aer: bounce brought BI down orderly (devres)" ||
	fail "aer: bounce brought BI down orderly (devres)"
grep -q "Root Port link has been reset (0)" <<<"$dm" &&
	ok "aer: link reset pulsed" ||
	fail "aer: link reset pulsed"
grep -q "restart CXL.mem after slot reset" <<<"$dm" &&
	ok "aer: cxl_slot_reset re-attached the memdev" ||
	fail "aer: cxl_slot_reset re-attached the memdev"
grep -q "error resume successful" <<<"$dm" &&
	ok "aer: error resume successful" ||
	fail "aer: error resume successful"
grep -q "device recovery successful" <<<"$dm" &&
	ok "aer: device recovery successful" ||
	fail "aer: device recovery successful"
# PCI_RESET_NO_RESTORE: reset_prepare/reset_done are not part of AER
# recovery, so neither invalidation nor the decoder-loss taint may
# fire - the unbind preceded the wipe and there was nothing to detect.
if grep -qE "BI disabled by reset|SBR happened without" <<<"$dm"; then
	fail "aer: .reset_done correctly absent from the AER path"
else
	ok "aer: .reset_done correctly absent from the AER path"
fi
grep -q "BI requests enabled" <<<"$dm" &&
	ok "aer: rebind re-ran the BI enable path" ||
	fail "aer: rebind re-ran the BI enable path"

ec2=$(bi_ctrl "$ep"); rc2=$(bi_ctrl "$rp")
if [ -z "$ec2" ]; then
	skip "aer: endpoint BI Enable back in hardware (no /dev/mem)"
elif [ $(( ec2 & 0x2 )) != 0 ]; then
	ok "aer: endpoint BI Enable back in hardware"
else
	fail "aer: endpoint BI Enable back in hardware ($ec2)"
fi
if [ -z "$rc2" ]; then
	skip "aer: RP re-programmed Enable (no /dev/mem)"
elif [ $(( rc2 & 0x3 )) = 2 ]; then
	ok "aer: RP re-programmed Enable"
else
	fail "aer: RP re-programmed Enable ($rc2)"
fi

create_region "aer"
splat_check "aer" "$(g dmesg)"
oracle_silent "aer"
g dmesg > "$OUT/t28-aer.dmesg" 2>/dev/null

# --- scenario B: fatal error with a committed HDM-DB region ----------
launch_t28 || { fail "region: launch"; exit 1; }
if wait_for_guest 180; then
	ok "region: guest booted"
else
	fail "region: guest booted"; exit 1
fi
create_region "region"
live=$region
g "dmesg -C" >/dev/null
r=$(inject_fatal)
if ! grep -q "OK id: mem0" <<<"$r"; then
	skip "region: qemu rejected AER injection"
	exit 0
fi
if ! wait_recovery; then
	fail "region: recovery reached a verdict"
	echo "$dm" | tail -30 | sed 's/^/# /'
	exit 1
fi
grep -q "frozen state error detected, disable CXL.mem" <<<"$dm" &&
	ok "region: bounce fired with a live region" ||
	fail "region: bounce fired with a live region"
grep -q "device recovery successful" <<<"$dm" &&
	ok "region: device recovery successful" ||
	fail "region: device recovery successful"
# A user-created region is not deleted by the bounce: the devres
# cascade detaches its endpoint decoder and the region decommits,
# but the region object is left for userspace to delete.
if g "test -e /sys/bus/cxl/devices/$live"; then
	c=$(g "cat /sys/bus/cxl/devices/$live/commit")
	if [ "$c" = 0 ]; then
		ok "region: bounce detached and decommitted the live region"
	else
		fail "region: bounce left the live region committed ($c)"
	fi
else
	ok "region: bounce detached and decommitted the live region (deleted)"
fi
splat_check "region" "$dm"
create_region "region: post-recovery"
oracle_silent "region"
g dmesg > "$OUT/t28-region.dmesg" 2>/dev/null

exit $((FAIL != 0))
