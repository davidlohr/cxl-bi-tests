#!/bin/bash
# t24-adopt.sh - firmware adoption (auto-commit) of the BI path.
#
# Adoption is a path property: only a device firmware itself enabled
# (endpoint BI Enable=1) may have its dports adopted as-is, since only
# then does each level's committed state cover this device's BI-ID.
# Any other device is new below every level and owes the DSP decoder
# and USP RT commits regardless of register values (Table 8-152,
# Table 8-156: "whenever a new BI device is enabled anywhere below
# this port"), and firmware programming that contradicts the
# topology-derived role (Enable adjacent to the device, Forward on
# every level above, Table 9-13/7-97) must be corrected, not adopted.
#
# Host-driven multi-boot suite (t16/t23 style), one boot per scenario:
#   1. full-adopt: x-committed=hdm-db stages a firmware-enabled
#      direct-attach device. Zero commit cycles, no endpoint write,
#      registers untouched; only the unstageable RP is programmed.
#   2. fresh-dev: DSP (x-bi-committed) and USP RT (x-bi-rt-committed)
#      staged committed but the endpoint is NOT firmware-enabled.
#      Adoption must be declined: both commits run even though the
#      register values do not change.
#   3. wrong-role: a cascade's TRANSIT DSP staged Enable+committed.
#      The kernel must reprogram it to Forward and commit, and give
#      the adjacent DSP the Enable.
# Each scenario ends with the qemu BI oracle silent, and 1-2 verify
# teardown through the adopted/programmed bookkeeping on unbind.
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
dmesg_has() { [ "$(g dmesg | grep -c "$1")" -gt 0 ]; }
oracle_silent() { # oracle_silent <tag> - qemu.log is per-launch
	if [ "$(grep -c "CXL BI oracle" "$RUNDIR/qemu.log" 2>/dev/null)" = 0 ]
	then
		ok "$1: qemu BI oracle silent"
	else
		fail "$1: qemu BI oracle silent"
	fi
}

# bi_regs <bdf> <capid> -> "caps ctrl sts" from the component block
# capability array (BI RT=0xB, BI Decoder=0xC), empty on any failure.
bi_regs() {
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
    if (e & 0xffff) == $2:
        off = (e >> 20) & 0xfff
assert off is not None, 'cap $2 not found'
print('%#x %#x %#x' % (u32(off), u32(off + 4), u32(off + 8)))
m.close(); os.close(fd)
PYEOF"
}

echo "# CXL BI firmware-adoption suite t24"

# --- scenario 1: full adopt, direct attach ---------------------------
# QEMU stages committed state for directly attached devices only
# (ct3d_committed_decoder_init), so this is the one stageable
# whole-path adoption. The RP cannot be staged and takes the Enable
# write (no commit exists at an RP, Table 8-156).
if ! "$QEMU" -device cxl-type3,help 2>/dev/null | grep -q "x-committed"
then
	for i in $(seq 1 11); do
		skip "adopt: qemu cxl-type3 lacks x-committed"
	done
else
	launch_qemu \
	  -object memory-backend-ram,id=m0,size=1G \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	  -device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on,x-committed=hdm-db \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
	if wait_for_guest 180; then
		ok "adopt: guest booted"
	else
		fail "adopt: guest booted"; exit 1
	fi
	dm=$(g dmesg)
	if [ "$(grep -c 'BI-ID commit wait took' <<<"$dm")" = 0 ]; then
		ok "adopt: zero commit cycles"
	else
		fail "adopt: zero commit cycles"
	fi
	if grep -q "adopting firmware-enabled BI" <<<"$dm"; then
		ok "adopt: endpoint adopted"
	else
		fail "adopt: endpoint adopted"
	fi
	if grep -q "BI requests enabled" <<<"$dm"; then
		fail "adopt: endpoint register untouched"
	else
		ok "adopt: endpoint register untouched"
	fi
	if grep -q "BI setup failed" <<<"$dm"; then
		fail "adopt: no setup failure"
	else
		ok "adopt: no setup failure"
	fi
	path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
	rp=$(awk -F/ '{print $(NF-2)}' <<<"$path")
	ep=$(awk -F/ '{print $(NF-1)}' <<<"$path")
	read -r _ rctrl _ <<<"$(bi_regs "$rp" 0xC)"
	read -r _ ectrl _ <<<"$(bi_regs "$ep" 0xC)"
	if [ -z "$rctrl" ] || [ -z "$ectrl" ]; then
		skip "adopt: RP programmed Enable (no /dev/mem)"
		skip "adopt: endpoint Enable staged (no /dev/mem)"
	else
		if [ $(( rctrl & 0x3 )) = 2 ]; then
			ok "adopt: RP programmed Enable (direct attach)"
		else
			fail "adopt: RP programmed Enable ($rctrl)"
		fi
		if [ $(( ectrl & 0x2 )) = 2 ]; then
			ok "adopt: endpoint Enable staged"
		else
			fail "adopt: endpoint Enable staged ($ectrl)"
		fi
	fi
	g "echo $ep > /sys/bus/pci/drivers/cxl_pci/unbind" >/dev/null
	for i in $(seq 1 30); do
		dm=$(g dmesg)
		grep -q "BI requests disabled" <<<"$dm" && break
	done
	if grep -q "BI requests disabled" <<<"$dm"; then
		ok "adopt: endpoint disabled on unbind"
	else
		fail "adopt: endpoint disabled on unbind"
	fi
	if grep -qE "$SPLAT_RE" <<<"$dm"; then
		fail "adopt: no splat across teardown"
	else
		ok "adopt: no splat across teardown"
	fi
	read -r _ rctrl2 _ <<<"$(bi_regs "$rp" 0xC)"
	if [ -z "$rctrl2" ]; then
		skip "adopt: RP cleared post-teardown (no /dev/mem)"
	elif [ $(( rctrl2 & 0x3 )) = 0 ]; then
		ok "adopt: RP cleared post-teardown"
	else
		fail "adopt: RP cleared post-teardown ($rctrl2)"
	fi
	oracle_silent "adopt"
	g dmesg > "$OUT/t24-adopt.dmesg" 2>/dev/null
fi

# --- scenario 2: fresh device through staged dports ------------------
# The endpoint is not firmware-enabled, so the staged DSP/RT committed
# state covers somebody else's BI-ID at best: adoption must be
# declined and both commits run with unchanged register values.
if ! "$QEMU" -device cxl-downstream,help 2>/dev/null | \
		grep -q "x-bi-committed" || \
   ! "$QEMU" -device cxl-upstream,help 2>/dev/null | \
		grep -q "x-bi-rt-committed"; then
	for i in $(seq 1 15); do
		skip "fresh-dev: qemu lacks x-bi-committed/x-bi-rt-committed"
	done
else
	launch_qemu \
	  -object memory-backend-ram,id=m0,size=1G \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on,x-bi-rt-committed=on \
	  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on,x-bi-committed=on \
	  -device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
	if wait_for_guest 180; then
		ok "fresh-dev: guest booted"
	else
		fail "fresh-dev: guest booted"; exit 1
	fi
	dm=$(g dmesg)
	n1=$(grep -c 'BI-ID commit wait took' <<<"$dm")
	if [ "$n1" -ge 2 ]; then
		ok "fresh-dev: commits ran for the new device ($n1)"
	else
		fail "fresh-dev: staged dports wrongly adopted ($n1 commits)"
	fi
	if grep -q "BI requests enabled" <<<"$dm"; then
		ok "fresh-dev: endpoint enabled by the kernel"
	else
		fail "fresh-dev: endpoint enabled by the kernel"
	fi
	if grep -q "BI setup failed" <<<"$dm"; then
		fail "fresh-dev: no setup failure"
	else
		ok "fresh-dev: no setup failure"
	fi
	path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
	dsp=$(awk -F/ '{print $(NF-2)}' <<<"$path")
	usp=$(awk -F/ '{print $(NF-3)}' <<<"$path")
	rp=$(awk -F/ '{print $(NF-4)}' <<<"$path")
	ep=$(awk -F/ '{print $(NF-1)}' <<<"$path")
	read -r _ dctrl dsts <<<"$(bi_regs "$dsp" 0xC)"
	read -r _ rtctrl rtsts <<<"$(bi_regs "$usp" 0xB)"
	read -r _ rpctrl _ <<<"$(bi_regs "$rp" 0xC)"
	if [ -z "$dsts" ] || [ -z "$rtsts" ] || [ -z "$rpctrl" ]; then
		for i in $(seq 1 6); do
			skip "fresh-dev: register readback (no /dev/mem)"
		done
	else
		if [ $(( rpctrl & 0x3 )) = 1 ]; then
			ok "fresh-dev: RP programmed Forward (switch below)"
		else
			fail "fresh-dev: RP role bits wrong ($rpctrl)"
		fi
		if [ $(( dctrl & 0x3 )) = 2 ]; then
			ok "fresh-dev: DSP keeps the adjacent Enable"
		else
			fail "fresh-dev: DSP role bits wrong ($dctrl)"
		fi
		# The staged Commit bit cannot witness this: firmware
		# presents it already set (Table 8-158 ties Committed to
		# the last 0->1 of it). The kernel names the dport it
		# commits, so use that instead.
		if grep -q "pcieport $dsp: BI-ID commit wait" <<<"$dm"; then
			ok "fresh-dev: DSP commit sequence ran"
		else
			fail "fresh-dev: DSP commit skipped"
		fi
		if [ $(( dsts & 0x1 )) = 1 ]; then
			ok "fresh-dev: DSP committed"
		else
			fail "fresh-dev: DSP not committed ($dsts)"
		fi
		if grep -q "cxl_port port.*: BI-ID commit wait" <<<"$dm"; then
			ok "fresh-dev: RT commit sequence ran"
		else
			fail "fresh-dev: RT commit skipped"
		fi
		if [ $(( rtsts & 0x1 )) = 1 ]; then
			ok "fresh-dev: RT committed"
		else
			fail "fresh-dev: RT not committed ($rtsts)"
		fi
	fi
	g "echo $ep > /sys/bus/pci/drivers/cxl_pci/unbind" >/dev/null
	for i in $(seq 1 30); do
		dm=$(g dmesg)
		grep -q "BI requests disabled" <<<"$dm" && break
	done
	if grep -q "BI requests disabled" <<<"$dm"; then
		ok "fresh-dev: endpoint disabled on unbind"
	else
		fail "fresh-dev: endpoint disabled on unbind"
	fi
	n2=$(grep -c 'BI-ID commit wait took' <<<"$dm")
	if [ "$n2" -gt "$n1" ]; then
		ok "fresh-dev: dealloc commit ran ($n1 -> $n2)"
	else
		fail "fresh-dev: dealloc commit ran ($n1 -> $n2)"
	fi
	if grep -qE "$SPLAT_RE" <<<"$dm"; then
		fail "fresh-dev: no splat across teardown"
	else
		ok "fresh-dev: no splat across teardown"
	fi
	read -r _ dctrl2 _ <<<"$(bi_regs "$dsp" 0xC)"
	if [ -z "$dctrl2" ]; then
		skip "fresh-dev: DSP cleared post-teardown (no /dev/mem)"
	elif [ $(( dctrl2 & 0x3 )) = 0 ]; then
		ok "fresh-dev: DSP cleared post-teardown"
	else
		fail "fresh-dev: DSP cleared post-teardown ($dctrl2)"
	fi
	oracle_silent "fresh-dev"
	g dmesg > "$OUT/t24-fresh-dev.dmesg" 2>/dev/null
fi

# --- scenario 3: wrong-role staging on a transit DSP -----------------
# A cascade with x-bi-committed on the OUTER (transit) DSP: firmware
# claims Enable+committed on a level whose role is Forward. Wrong
# programming must be corrected and committed, never adopted.
if ! "$QEMU" -device cxl-downstream,help 2>/dev/null | \
		grep -q "x-bi-committed"; then
	for i in $(seq 1 10); do
		skip "wrong-role: qemu lacks x-bi-committed"
	done
else
	launch_qemu \
	  -object memory-backend-ram,id=m0,size=1G \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on,x-bi-committed=on \
	  -device cxl-upstream,bus=dsp0,id=us1,x-256b-flit=on \
	  -device cxl-downstream,port=0,bus=us1,id=dsp1,chassis=0,slot=6,x-256b-flit=on \
	  -device cxl-type3,bus=dsp1,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
	if wait_for_guest 180; then
		ok "wrong-role: guest booted"
	else
		fail "wrong-role: guest booted"; exit 1
	fi
	dm=$(g dmesg)
	if grep -q "BI requests enabled" <<<"$dm"; then
		ok "wrong-role: BI enabled end-to-end"
	else
		fail "wrong-role: BI enabled end-to-end"
	fi
	if grep -q "BI setup failed" <<<"$dm"; then
		fail "wrong-role: no setup failure"
	else
		ok "wrong-role: no setup failure"
	fi
	if [ "$(grep -c 'BI-ID commit wait took' <<<"$dm")" -ge 2 ]; then
		ok "wrong-role: commits ran (correction + adjacent)"
	else
		fail "wrong-role: expected commit cycles missing"
	fi
	path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
	dsp1=$(awk -F/ '{print $(NF-2)}' <<<"$path")
	dsp0=$(awk -F/ '{print $(NF-4)}' <<<"$path")
	read -r _ c0 s0 <<<"$(bi_regs "$dsp0" 0xC)"
	read -r _ c1 s1 <<<"$(bi_regs "$dsp1" 0xC)"
	if [ -z "$s0" ] || [ -z "$s1" ]; then
		for i in $(seq 1 5); do
			skip "wrong-role: register readback (no /dev/mem)"
		done
	else
		if [ $(( c0 & 0x3 )) = 1 ]; then
			ok "wrong-role: transit corrected to Forward"
		else
			fail "wrong-role: transit role bits wrong ($c0)"
		fi
		if grep -q "pcieport $dsp0: BI-ID commit wait" <<<"$dm"; then
			ok "wrong-role: transit correction committed"
		else
			fail "wrong-role: transit correction not committed"
		fi
		if [ $(( s0 & 0x1 )) = 1 ]; then
			ok "wrong-role: transit committed status"
		else
			fail "wrong-role: transit committed status ($s0)"
		fi
		if [ $(( c1 & 0x3 )) = 2 ]; then
			ok "wrong-role: adjacent DSP programmed Enable"
		else
			fail "wrong-role: adjacent role bits wrong ($c1)"
		fi
		if [ $(( s1 & 0x1 )) = 1 ]; then
			ok "wrong-role: adjacent committed"
		else
			fail "wrong-role: adjacent committed ($s1)"
		fi
	fi
	oracle_silent "wrong-role"
	g dmesg > "$OUT/t24-wrong-role.dmesg" 2>/dev/null
fi

# --- scenarios 4-5: a path firmware brought up behind switches -------
# x-bi-enabled sets only the endpoint's BI Enable, so unlike
# x-committed it composes with any topology. With the ports above
# staged for the role their position calls for, this is a cascade
# firmware enabled end to end - the one shape that seeds adoption
# true deeper than a single dport.
#
#   4. fw-path: every level correct and committed. Adoption runs the
#      whole way up: no commit anywhere, at either switch level.
#   5. fw-partial: identical but the INNER route table is left
#      uncommitted. Adoption dies at the adjacent DSP, and the transit
#      DSP above it - staged perfectly, and adoptable on its own
#      terms - must still program and commit, because from a failed
#      level upward the driver is enabling something new (Table 8-152,
#      Table 8-156). Without that rule this boot commits twice instead
#      of four times.
#   6. fw-shared-rp: TWO firmware-enabled endpoints under one switch.
#      Each has its own DSP; the only level they share is the root
#      port, which the first endpoint programmed (qemu cannot stage an
#      RP). nr_bi refuses adoption there for the second endpoint, but
#      the value is already in place and a root port never commits
#      (Table 8-156): zero commit cycles, both endpoints adopt.
#   7. fw-shared-dsp: the same two endpoints under an INNER switch, so
#      they share the outer transit DSP. The first endpoint adopts it;
#      the second is refused there by nr_bi and, from that level up,
#      programs and commits as for a new device: exactly two commit
#      cycles, the transit decoder and the outer route table, none on
#      the adjacent DSPs, and both endpoints still adopt.
launch_fw() { # launch_fw <inner-usp-extra>
	launch_qemu \
	  -object memory-backend-ram,id=m0,size=1G \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on,x-bi-rt-committed=on \
	  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on,x-bi-fw-committed=on \
	  -device cxl-upstream,bus=dsp0,id=us1,x-256b-flit=on$1 \
	  -device cxl-downstream,port=0,bus=us1,id=dsp1,chassis=0,slot=6,x-256b-flit=on,x-bi-committed=on \
	  -device cxl-type3,bus=dsp1,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on,x-bi-enabled=on \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
}

if ! "$QEMU" -device cxl-type3,help 2>/dev/null | grep -q "x-bi-enabled" ||
   ! "$QEMU" -device cxl-downstream,help 2>/dev/null | \
		grep -q "x-bi-fw-committed"; then
	for i in $(seq 1 9); do
		skip "fw-path: qemu lacks x-bi-enabled/x-bi-fw-committed"
	done
else
	launch_fw ",x-bi-rt-committed=on" || { fail "fw-path: launch"; exit 1; }
	if wait_for_guest 180; then
		ok "fw-path: guest booted"
	else
		fail "fw-path: guest booted"; exit 1
	fi
	dm=$(g dmesg)
	if grep -q "adopting firmware-enabled BI" <<<"$dm"; then
		ok "fw-path: endpoint adopted"
	else
		fail "fw-path: endpoint adopted"
	fi
	nfw=$(grep -c 'BI-ID commit wait took' <<<"$dm")
	if [ "$nfw" = 0 ]; then
		ok "fw-path: zero commit cycles behind two switches"
	else
		fail "fw-path: zero commit cycles (got $nfw)"
	fi
	if grep -q "BI setup failed" <<<"$dm"; then
		fail "fw-path: no setup failure"
	else
		ok "fw-path: no setup failure"
	fi
	path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
	adj=$(awk -F/ '{print $(NF-2)}' <<<"$path")
	transit=$(awk -F/ '{print $(NF-4)}' <<<"$path")
	read -r _ actl _ <<<"$(bi_regs "$adj" 0xC)"
	read -r _ tctl _ <<<"$(bi_regs "$transit" 0xC)"
	if [ -z "$actl" ] || [ -z "$tctl" ]; then
		skip "fw-path: adjacent kept Enable (no /dev/mem)"
		skip "fw-path: transit kept Forward (no /dev/mem)"
	else
		[ $(( actl & 0x3 )) = 2 ] && ok "fw-path: adjacent kept Enable" ||
			fail "fw-path: adjacent role changed ($actl)"
		[ $(( tctl & 0x3 )) = 1 ] && ok "fw-path: transit kept Forward" ||
			fail "fw-path: transit role changed ($tctl)"
	fi
	oracle_silent "fw-path"
	g dmesg > "$OUT/t24-fw-path.dmesg" 2>/dev/null

	launch_fw "" || { fail "fw-partial: launch"; exit 1; }
	if wait_for_guest 180; then
		ok "fw-partial: guest booted"
	else
		fail "fw-partial: guest booted"; exit 1
	fi
	dm=$(g dmesg)
	npart=$(grep -c 'BI-ID commit wait took' <<<"$dm")
	# adjacent decoder + inner RT, then transit decoder + outer RT
	if [ "$npart" -ge 4 ]; then
		ok "fw-partial: failed level forces commits above it ($npart)"
	else
		fail "fw-partial: transit adopted despite a failed level below ($npart)"
	fi
	path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
	transit=$(awk -F/ '{print $(NF-4)}' <<<"$path")
	if grep -q "pcieport $transit: BI-ID commit wait" <<<"$dm"; then
		ok "fw-partial: the transit level itself committed"
	else
		fail "fw-partial: the transit level itself committed"
	fi
	oracle_silent "fw-partial"
	g dmesg > "$OUT/t24-fw-partial.dmesg" 2>/dev/null
fi

# --- scenarios 6-7: two firmware-enabled endpoints sharing a level --
# nr_bi counts every endpoint routed through a level, adopted or
# programmed alike, so the SECOND firmware-enabled endpoint is always
# refused adoption at a level the first one already holds. What that
# refusal costs depends on what the shared level is.
launch_shared_rp() {
	launch_qemu \
	  -object memory-backend-ram,id=m0,size=1G \
	  -object memory-backend-ram,id=m1,size=1G \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on,x-bi-rt-committed=on \
	  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on,x-bi-committed=on \
	  -device cxl-downstream,port=1,bus=us0,id=dsp1,chassis=0,slot=5,x-256b-flit=on,x-bi-committed=on \
	  -device cxl-type3,bus=dsp0,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on,x-bi-enabled=on \
	  -device cxl-type3,bus=dsp1,volatile-memdev=m1,id=mem1,x-256b-flit=on,hdm-db=on,x-bi-enabled=on \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
}

launch_shared_dsp() {
	launch_qemu \
	  -object memory-backend-ram,id=m0,size=1G \
	  -object memory-backend-ram,id=m1,size=1G \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on,x-bi-rt-committed=on \
	  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on,x-bi-fw-committed=on \
	  -device cxl-upstream,bus=dsp0,id=us1,x-256b-flit=on,x-bi-rt-committed=on \
	  -device cxl-downstream,port=0,bus=us1,id=dsp1,chassis=0,slot=6,x-256b-flit=on,x-bi-committed=on \
	  -device cxl-downstream,port=1,bus=us1,id=dsp2,chassis=0,slot=7,x-256b-flit=on,x-bi-committed=on \
	  -device cxl-type3,bus=dsp1,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on,x-bi-enabled=on \
	  -device cxl-type3,bus=dsp2,volatile-memdev=m1,id=mem1,x-256b-flit=on,hdm-db=on,x-bi-enabled=on \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
}

# adjacent_kept_enable <tag> <memdev>: the DSP right above <memdev>
# still has Enable (ctrl & 3 == 2), SKIP without /dev/mem.
adjacent_kept_enable() {
	local path adj actl
	path=$(g "readlink -f /sys/bus/cxl/devices/$2")
	adj=$(awk -F/ '{print $(NF-2)}' <<<"$path")
	read -r _ actl _ <<<"$(bi_regs "$adj" 0xC)"
	if [ -z "$actl" ]; then
		skip "$1: $2 adjacent kept Enable (no /dev/mem)"
	elif [ $(( actl & 0x3 )) = 2 ]; then
		ok "$1: $2 adjacent kept Enable"
	else
		fail "$1: $2 adjacent role changed ($actl)"
	fi
}

if ! "$QEMU" -device cxl-type3,help 2>/dev/null | grep -q "x-bi-enabled" ||
   ! "$QEMU" -device cxl-downstream,help 2>/dev/null | \
		grep -q "x-bi-committed"; then
	for i in $(seq 1 8); do
		skip "fw-shared-rp: qemu lacks x-bi-enabled/x-bi-committed"
	done
else
	launch_shared_rp || { fail "fw-shared-rp: launch"; exit 1; }
	if wait_for_guest 180; then
		ok "fw-shared-rp: guest booted"
	else
		fail "fw-shared-rp: guest booted"; exit 1
	fi
	dm=$(g dmesg)
	nad=$(grep -c 'adopting firmware-enabled BI' <<<"$dm")
	if [ "$nad" = 2 ]; then
		ok "fw-shared-rp: both endpoints adopted"
	else
		fail "fw-shared-rp: both endpoints adopted (got $nad)"
	fi
	nc=$(grep -c 'BI-ID commit wait took' <<<"$dm")
	if [ "$nc" = 0 ]; then
		ok "fw-shared-rp: zero commit cycles, shared level is the RP"
	else
		fail "fw-shared-rp: zero commit cycles (got $nc)"
	fi
	if grep -q "BI setup failed" <<<"$dm"; then
		fail "fw-shared-rp: no setup failure"
	else
		ok "fw-shared-rp: no setup failure"
	fi
	nmem=$(g 'ls /sys/bus/cxl/devices/ | grep -c ^mem')
	if [ "$nmem" = 2 ]; then
		ok "fw-shared-rp: both endpoints enumerated"
	else
		fail "fw-shared-rp: both endpoints enumerated (got $nmem)"
	fi
	adjacent_kept_enable "fw-shared-rp" mem0
	adjacent_kept_enable "fw-shared-rp" mem1
	oracle_silent "fw-shared-rp"
	g dmesg > "$OUT/t24-fw-shared-rp.dmesg" 2>/dev/null
fi

if ! "$QEMU" -device cxl-type3,help 2>/dev/null | grep -q "x-bi-enabled" ||
   ! "$QEMU" -device cxl-downstream,help 2>/dev/null | \
		grep -q "x-bi-fw-committed"; then
	for i in $(seq 1 11); do
		skip "fw-shared-dsp: qemu lacks x-bi-enabled/x-bi-fw-committed"
	done
else
	launch_shared_dsp || { fail "fw-shared-dsp: launch"; exit 1; }
	if wait_for_guest 180; then
		ok "fw-shared-dsp: guest booted"
	else
		fail "fw-shared-dsp: guest booted"; exit 1
	fi
	dm=$(g dmesg)
	nad=$(grep -c 'adopting firmware-enabled BI' <<<"$dm")
	if [ "$nad" = 2 ]; then
		ok "fw-shared-dsp: both endpoints adopted"
	else
		fail "fw-shared-dsp: both endpoints adopted (got $nad)"
	fi
	nc=$(grep -c 'BI-ID commit wait took' <<<"$dm")
	if [ "$nc" = 2 ]; then
		ok "fw-shared-dsp: exactly two commit cycles for the second endpoint"
	else
		fail "fw-shared-dsp: exactly two commit cycles (got $nc)"
	fi
	path=$(g 'readlink -f /sys/bus/cxl/devices/mem1')
	transit=$(awk -F/ '{print $(NF-4)}' <<<"$path")
	outer=$(awk -F/ '{print $(NF-5)}' <<<"$path")
	oport=$(grep -o "pcieport $outer: port[0-9]* added" <<<"$dm" | \
		awk '{print $3}')
	if grep -q "pcieport $transit: BI-ID commit wait" <<<"$dm"; then
		ok "fw-shared-dsp: the shared transit decoder committed"
	else
		fail "fw-shared-dsp: the shared transit decoder committed"
	fi
	if [ -n "$oport" ] && \
	   grep -q "cxl_port $oport: BI-ID commit wait" <<<"$dm"; then
		ok "fw-shared-dsp: the outer route table committed"
	else
		fail "fw-shared-dsp: the outer route table committed ($oport)"
	fi
	nadj=$(grep 'BI-ID commit wait' <<<"$dm" | \
		grep -vc "pcieport $transit\|cxl_port $oport")
	if [ "$nadj" = 0 ]; then
		ok "fw-shared-dsp: nothing below the shared level committed"
	else
		fail "fw-shared-dsp: nothing below the shared level committed ($nadj)"
	fi
	if grep -q "BI setup failed" <<<"$dm"; then
		fail "fw-shared-dsp: no setup failure"
	else
		ok "fw-shared-dsp: no setup failure"
	fi
	read -r _ tctl _ <<<"$(bi_regs "$transit" 0xC)"
	if [ -z "$tctl" ]; then
		skip "fw-shared-dsp: transit kept Forward (no /dev/mem)"
	elif [ $(( tctl & 0x3 )) = 1 ]; then
		ok "fw-shared-dsp: transit kept Forward"
	else
		fail "fw-shared-dsp: transit role changed ($tctl)"
	fi
	adjacent_kept_enable "fw-shared-dsp" mem0
	adjacent_kept_enable "fw-shared-dsp" mem1
	oracle_silent "fw-shared-dsp"
	g dmesg > "$OUT/t24-fw-shared-dsp.dmesg" 2>/dev/null
fi

exit $((FAIL != 0))
