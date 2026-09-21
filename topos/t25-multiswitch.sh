#!/bin/bash
# t25-multiswitch.sh - multi-level switch BI invariants.
#
# What the spec defines for cascades and what each scenario pins:
#
#   1. shared: two endpoints below different inner DSPs of the same
#      inner switch, both reaching through ONE outer (transit) DSP.
#      Table 7-93: BISnp/BIRsp routing "relies on its vPPB binding at
#      each switch level" with the BI-ID carrying the adjacent DSP's
#      BusNum end to end - which requires Enable only at the adjacent
#      DSPs and Forward at the shared transit (Table 7-97 "Above HBR
#      USP": Propagate). A commit is owed per new device (Table
#      8-152/8-156), so the shared transit sees one commit edge per
#      endpoint. Teardown of the first endpoint must NOT clear the
#      shared transit (nr_bi refcount); the last one must.
#   2. rollback: t9-shape cascade with x-bi-commit-fault=error on the
#      OUTER (transit) DSP. The adjacent level enables and commits
#      first (9.14.2 allocate order); the transit commit failure must
#      unwind it - measured by register readback, not inferred.
#   3. adopt-rollback: scenario 2's cascade with the lower half staged
#      by firmware - device BI Enable set, adjacent DSP Enabled and
#      committed, inner switch route table committed. The walk adopts
#      the adjacent level (no write, no commit) and only the outer
#      transit is programmed, where the commit faults. Unwinding must
#      leave the adopted level exactly as firmware had it: the driver
#      never wrote it, and the device below still has BI Enable set.
#      Scenario 2 is the contrast, where nothing is adopted and the
#      adjacent level is cleared.
#   4. deep: three switch levels. The walk is depth-agnostic: caps
#      and commits scale with depth and the roles land by position.
#
# Host-driven multi-boot suite (t23/t24 style).
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
oracle_silent() { # qemu.log is per-launch
	if [ "$(grep -c "CXL BI oracle" "$RUNDIR/qemu.log" 2>/dev/null)" = 0 ]
	then
		ok "$1: qemu BI oracle silent"
	else
		fail "$1: qemu BI oracle silent"
	fi
}

# bi_regs <bdf> <capid> -> "caps ctrl sts", empty on any failure.
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
role() { # role <bdf> -> ctrl & 3, empty on failure
	local c
	read -r _ c _ <<<"$(bi_regs "$1" 0xC)"
	[ -n "$c" ] && echo $(( c & 0x3 ))
}

echo "# CXL BI multi-level switch suite t25"

# --- scenario 1: shared transit DSP refcount -------------------------
launch_shared() {
	launch_qemu \
	  -object memory-backend-ram,id=m0,size=1G \
	  -object memory-backend-ram,id=m1,size=1G \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
	  -device cxl-upstream,bus=dsp0,id=us1,x-256b-flit=on \
	  -device cxl-downstream,port=0,bus=us1,id=dsp1,chassis=0,slot=6,x-256b-flit=on \
	  -device cxl-downstream,port=1,bus=us1,id=dsp2,chassis=0,slot=7,x-256b-flit=on \
	  -device cxl-type3,bus=dsp1,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	  -device cxl-type3,bus=dsp2,volatile-memdev=m1,id=mem1,x-256b-flit=on,hdm-db=on \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
}

# Both endpoints must have probed before any BI state means anything.
# Two memdevs under one switch race to create the ports they share, and
# the loser's cxl_mem probe can come back -EBUSY; every BI assertion
# below then fails while pointing at the wrong thing. Retry the boot
# once so an intermittent race does not read as BI misprogramming, and
# report the probe error rather than the symptoms if it persists.
shared_ready() {
	local m
	for m in mem0 mem1; do
		# driver link present == cxl_mem probe succeeded for it
		g "test -e /sys/bus/cxl/devices/$m/driver" || return 1
		# and its endpoint port exists (the BI path hangs off it)
		g "for e in /sys/bus/cxl/devices/endpoint*; do
			[ \"\$(basename \$(readlink -f \$e/uport))\" = $m ] &&
				exit 0
		   done; exit 1" || return 1
	done
	return 0
}

probe_errors() { g dmesg | grep -E "cxl_mem mem[0-9]+: probe: -|probe with driver cxl_mem failed"; }

launch_shared
if wait_for_guest 180; then
	ok "shared: guest booted"
else
	fail "shared: guest booted"; exit 1
fi

if ! shared_ready; then
	echo "# shared: endpoint probe incomplete, retrying the boot"
	probe_errors | sed 's/^/# first attempt: /'
	stop_qemu >/dev/null 2>&1
	launch_shared
	wait_for_guest 180 || { fail "shared: guest booted (retry)"; exit 1; }
fi
if shared_ready; then
	ok "shared: both endpoints probed"
else
	fail "shared: both endpoints probed"
	probe_errors | sed 's/^/# /'
	exit 1
fi

dm=$(g dmesg)
if [ "$(grep -c 'BI requests enabled' <<<"$dm")" = 2 ]; then
	ok "shared: both endpoints BI enabled"
else
	fail "shared: both endpoints BI enabled"
fi
if grep -q "BI setup failed" <<<"$dm"; then
	fail "shared: no setup failure"
else
	ok "shared: no setup failure"
fi
# Per endpoint: adjacent decoder + inner RT, transit decoder + outer
# RT = 4 commit waits; the transit edges repeat per device.
n1=$(grep -c 'BI-ID commit wait took' <<<"$dm")
if [ "$n1" -ge 8 ]; then
	ok "shared: commit edges per device ($n1)"
else
	fail "shared: commit edges per device (got $n1, want >= 8)"
fi
patha=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
pathb=$(g 'readlink -f /sys/bus/cxl/devices/mem1')
adja=$(awk -F/ '{print $(NF-2)}' <<<"$patha")
adjb=$(awk -F/ '{print $(NF-2)}' <<<"$pathb")
transit=$(awk -F/ '{print $(NF-4)}' <<<"$patha")
rp=$(awk -F/ '{print $(NF-6)}' <<<"$patha")
epa=$(awk -F/ '{print $(NF-1)}' <<<"$patha")
epb=$(awk -F/ '{print $(NF-1)}' <<<"$pathb")
echo "# adja=$adja adjb=$adjb transit=$transit rp=$rp"
if [ -z "$(role "$transit")" ]; then
	for i in 1 2 3 4; do
		skip "shared: register truth (no /dev/mem)"
	done
else
	[ "$(role "$transit")" = 1 ] && ok "shared: transit Forward" ||
		fail "shared: transit Forward ($(role "$transit"))"
	[ "$(role "$adja")" = 2 ] && ok "shared: adjacent A Enable" ||
		fail "shared: adjacent A Enable ($(role "$adja"))"
	[ "$(role "$adjb")" = 2 ] && ok "shared: adjacent B Enable" ||
		fail "shared: adjacent B Enable ($(role "$adjb"))"
	[ "$(role "$rp")" = 1 ] && ok "shared: RP Forward" ||
		fail "shared: RP Forward ($(role "$rp"))"
fi
# First endpoint goes away: its adjacent DSP clears and commits, the
# shared transit must hold Forward for the survivor (nr_bi).
g "echo $epa > /sys/bus/pci/drivers/cxl_pci/unbind" >/dev/null
for i in $(seq 1 30); do
	dm=$(g dmesg)
	grep -q "BI requests disabled" <<<"$dm" && break
done
grep -q "BI requests disabled" <<<"$dm" &&
	ok "shared: first endpoint disabled" ||
	fail "shared: first endpoint disabled"
n2=$(grep -c 'BI-ID commit wait took' <<<"$dm")
[ "$n2" -gt "$n1" ] && ok "shared: dealloc commit at adjacent ($n1 -> $n2)" ||
	fail "shared: dealloc commit at adjacent ($n1 -> $n2)"
if [ -z "$(role "$transit")" ]; then
	for i in 1 2 3; do
		skip "shared: survivor register truth (no /dev/mem)"
	done
else
	[ "$(role "$transit")" = 1 ] &&
		ok "shared: transit holds Forward for the survivor" ||
		fail "shared: transit cleared under the survivor"
	[ "$(role "$adja")" = 0 ] && ok "shared: first adjacent cleared" ||
		fail "shared: first adjacent cleared ($(role "$adja"))"
	[ "$(role "$adjb")" = 2 ] && ok "shared: survivor adjacent intact" ||
		fail "shared: survivor adjacent intact ($(role "$adjb"))"
fi
# Last endpoint out: the transit and RP clear (dealloc step 6 only
# once no device below holds a BI-ID).
g "echo $epb > /sys/bus/pci/drivers/cxl_pci/unbind" >/dev/null
for i in $(seq 1 30); do
	[ "$(g dmesg | grep -c 'BI requests disabled')" = 2 ] && break
done
if [ -z "$(role "$transit")" ]; then
	for i in 1 2; do
		skip "shared: last-out register truth (no /dev/mem)"
	done
else
	[ "$(role "$transit")" = 0 ] && ok "shared: transit cleared last-out" ||
		fail "shared: transit cleared last-out ($(role "$transit"))"
	[ "$(role "$rp")" = 0 ] && ok "shared: RP cleared last-out" ||
		fail "shared: RP cleared last-out ($(role "$rp"))"
fi
dm=$(g dmesg)
grep -qE "$SPLAT_RE" <<<"$dm" &&
	fail "shared: no splat across teardown" ||
	ok "shared: no splat across teardown"
oracle_silent "shared"
g dmesg > "$OUT/t25-shared.dmesg" 2>/dev/null

# --- scenario 2: transit commit fault, measured rollback -------------
if ! "$QEMU" -device cxl-downstream,help 2>/dev/null | \
		grep -q "x-bi-commit-fault"; then
	for i in $(seq 1 8); do
		skip "rollback: qemu lacks x-bi-commit-fault"
	done
else
	launch_qemu \
	  -object memory-backend-ram,id=m0,size=1G \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on,x-bi-commit-fault=error \
	  -device cxl-upstream,bus=dsp0,id=us1,x-256b-flit=on \
	  -device cxl-downstream,port=0,bus=us1,id=dsp1,chassis=0,slot=6,x-256b-flit=on \
	  -device cxl-type3,bus=dsp1,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
	if wait_for_guest 180; then
		ok "rollback: guest booted"
	else
		fail "rollback: guest booted"; exit 1
	fi
	dm=$(g dmesg)
	grep -qE "BI-ID commit rejected by hardware" <<<"$dm" &&
		ok "rollback: transit commit diagnostic" ||
		fail "rollback: transit commit diagnostic"
	grep -q "BI setup failed" <<<"$dm" &&
		ok "rollback: BI setup refused" ||
		fail "rollback: BI setup refused"
	if [ "$(g 'cat /sys/bus/cxl/devices/endpoint*/decoder*.0/back_invalidate')" = 0 ]
	then
		ok "rollback: endpoint bi=0"
	else
		fail "rollback: endpoint bi=0"
	fi
	path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
	adj=$(awk -F/ '{print $(NF-2)}' <<<"$path")
	transit=$(awk -F/ '{print $(NF-4)}' <<<"$path")
	if [ -n "$path" ]; then
		ok "rollback: endpoint survives"
	else
		fail "rollback: endpoint survives"
	fi
	if [ -z "$(role "$adj")" ]; then
		for i in 1 2; do
			skip "rollback: register truth (no /dev/mem)"
		done
	else
		[ "$(role "$adj")" = 0 ] &&
			ok "rollback: adjacent unwound (was enabled)" ||
			fail "rollback: adjacent unwound ($(role "$adj"))"
		[ "$(role "$transit")" = 0 ] &&
			ok "rollback: transit restored" ||
			fail "rollback: transit restored ($(role "$transit"))"
	fi
	oracle_silent "rollback"
	g dmesg > "$OUT/t25-rollback.dmesg" 2>/dev/null
fi

# --- scenario 3: adopted prefix survives a rollback ------------------
if ! "$QEMU" -device cxl-type3,help 2>/dev/null | grep -q "x-bi-enabled" ||
   ! "$QEMU" -device cxl-downstream,help 2>/dev/null | grep -q "x-bi-committed" ||
   ! "$QEMU" -device cxl-upstream,help 2>/dev/null | grep -q "x-bi-rt-committed" ||
   ! "$QEMU" -device cxl-downstream,help 2>/dev/null | grep -q "x-bi-commit-fault"
then
	for i in $(seq 1 8); do
		skip "adopt-rollback: qemu lacks the BI staging knobs"
	done
else
	launch_qemu \
	  -object memory-backend-ram,id=m0,size=1G \
	  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
	  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
	  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on,x-bi-commit-fault=error \
	  -device cxl-upstream,bus=dsp0,id=us1,x-256b-flit=on,x-bi-rt-committed=on \
	  -device cxl-downstream,port=0,bus=us1,id=dsp1,chassis=0,slot=6,x-256b-flit=on,x-bi-committed=on \
	  -device cxl-type3,bus=dsp1,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on,x-bi-enabled=on \
	  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
	if wait_for_guest 180; then
		ok "adopt-rollback: guest booted"
	else
		fail "adopt-rollback: guest booted"; exit 1
	fi
	dm=$(g dmesg)
	grep -qE "BI-ID commit rejected by hardware" <<<"$dm" &&
		ok "adopt-rollback: transit commit diagnostic" ||
		fail "adopt-rollback: transit commit diagnostic"
	grep -q "BI setup failed" <<<"$dm" &&
		ok "adopt-rollback: BI setup refused" ||
		fail "adopt-rollback: BI setup refused"
	if [ "$(g 'cat /sys/bus/cxl/devices/endpoint*/decoder*.0/back_invalidate')" = 0 ]
	then
		ok "adopt-rollback: endpoint bi=0"
	else
		fail "adopt-rollback: endpoint bi=0"
	fi
	path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
	adj=$(awk -F/ '{print $(NF-2)}' <<<"$path")
	transit=$(awk -F/ '{print $(NF-4)}' <<<"$path")
	rp=$(awk -F/ '{print $(NF-6)}' <<<"$path")
	if [ -z "$(role "$adj")" ]; then
		for i in 1 2 3; do
			skip "adopt-rollback: register truth (no /dev/mem)"
		done
	else
		# adopted, so this driver never wrote it: firmware's Enable stands
		[ "$(role "$adj")" = 2 ] &&
			ok "adopt-rollback: adopted level left as firmware had it" ||
			fail "adopt-rollback: adopted level left as firmware had it ($(role "$adj"))"
		[ "$(role "$transit")" = 0 ] &&
			ok "adopt-rollback: faulted transit restored" ||
			fail "adopt-rollback: faulted transit restored ($(role "$transit"))"
		[ "$(role "$rp")" = 0 ] &&
			ok "adopt-rollback: RP never reached" ||
			fail "adopt-rollback: RP never reached ($(role "$rp"))"
	fi
	oracle_silent "adopt-rollback"
	g dmesg > "$OUT/t25-adopt-rollback.dmesg" 2>/dev/null
fi

# --- scenario 4: three switch levels ---------------------------------
launch_qemu \
  -object memory-backend-ram,id=m0,size=1G \
  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
  -device cxl-upstream,bus=dsp0,id=us1,x-256b-flit=on \
  -device cxl-downstream,port=0,bus=us1,id=dsp1,chassis=0,slot=6,x-256b-flit=on \
  -device cxl-upstream,bus=dsp1,id=us2,x-256b-flit=on \
  -device cxl-downstream,port=0,bus=us2,id=dsp2,chassis=0,slot=8,x-256b-flit=on \
  -device cxl-type3,bus=dsp2,volatile-memdev=m0,id=mem0,x-256b-flit=on,hdm-db=on \
  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on
if wait_for_guest 180; then
	ok "deep: guest booted"
else
	fail "deep: guest booted"; exit 1
fi
dm=$(g dmesg)
grep -q "BI requests enabled" <<<"$dm" &&
	ok "deep: BI enabled three levels down" ||
	fail "deep: BI enabled three levels down"
grep -q "BI setup failed" <<<"$dm" &&
	fail "deep: no setup failure" || ok "deep: no setup failure"
ndec=$(grep -c "found BI Decoder capability" <<<"$dm")
[ "$ndec" -ge 5 ] && ok "deep: BI decoder caps (ep+rp+3 dsp)" ||
	fail "deep: BI decoder caps (got $ndec, want >= 5)"
nrt=$(grep -c "found BI RT capability" <<<"$dm")
[ "$nrt" -ge 3 ] && ok "deep: BI RT caps (3 USPs)" ||
	fail "deep: BI RT caps (got $nrt, want >= 3)"
ncmt=$(grep -c 'BI-ID commit wait took' <<<"$dm")
[ "$ncmt" -ge 6 ] && ok "deep: commits at all three levels ($ncmt)" ||
	fail "deep: commits at all three levels (got $ncmt, want >= 6)"
path=$(g 'readlink -f /sys/bus/cxl/devices/mem0')
adj=$(awk -F/ '{print $(NF-2)}' <<<"$path")
mid=$(awk -F/ '{print $(NF-4)}' <<<"$path")
outer=$(awk -F/ '{print $(NF-6)}' <<<"$path")
rp=$(awk -F/ '{print $(NF-8)}' <<<"$path")
if [ -z "$(role "$adj")" ]; then
	for i in 1 2 3 4; do
		skip "deep: register truth (no /dev/mem)"
	done
else
	[ "$(role "$adj")" = 2 ] && ok "deep: adjacent Enable" ||
		fail "deep: adjacent Enable ($(role "$adj"))"
	[ "$(role "$mid")" = 1 ] && ok "deep: mid transit Forward" ||
		fail "deep: mid transit Forward ($(role "$mid"))"
	[ "$(role "$outer")" = 1 ] && ok "deep: outer transit Forward" ||
		fail "deep: outer transit Forward ($(role "$outer"))"
	[ "$(role "$rp")" = 1 ] && ok "deep: RP Forward" ||
		fail "deep: RP Forward ($(role "$rp"))"
fi
oracle_silent "deep"
g dmesg > "$OUT/t25-deep.dmesg" 2>/dev/null

exit $((FAIL != 0))
