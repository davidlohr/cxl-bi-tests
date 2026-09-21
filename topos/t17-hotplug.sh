#!/bin/bash
# t17-hotplug.sh - QMP runtime hotplug of cxl-type3 endpoints.
#
#   pxb-cxl (cxl.1)
#     cxl-rp (rp0, flit)
#       cxl-upstream (us0, flit)
#         cxl-downstream (dsp0) - mem sn=0x171 (cold-plugged)
#         cxl-downstream (dsp1) - empty at boot, hot-add target
#         cxl-downstream (dsp2) - empty at boot, re-add target
#
# What t17 exercises that the bind/unbind phases (t2/t5) cannot: the
# dport/endpoint BI setup driven by real pciehp events rather than a
# driver rebind on an already-enumerated device.
#
#   1. Hot-add into an empty DSP: pciehp Link Up -> cxl_pci probe ->
#      devm_cxl_dport_bi_setup at dport-add time -> BI requests
#      enabled; an HDM-DB region commits on the hot-added endpoint.
#   2. Hot-remove (attention button) with a committed HDM-DB region:
#      teardown runs BI disable + decoder reap with no WARN, the
#      region decommits (its device persists target-less for
#      userspace to delete), and the surviving endpoint's path stays
#      BI-enabled (nr_bi on the shared USP/RP): a post-removal commit
#      on the survivor succeeds.
#   3. Add-after-remove into a spare slot completes the lifecycle on
#      a topology that has already seen a removal.
#
# QEMU gap (v11.1.0-rc0): the guest completes the unplug (slot powers
# off, device torn down) but QEMU never finalizes it - the cxl-type3
# stays in the QOM tree and the slot reads occupied forever, so
# re-adding into the SAME slot fails. Scenario 3 therefore uses the
# spare dsp2. If QEMU learns to finalize, s3 can move back to dsp0.
#
# Host-driven suite (like t16): QMP is interleaved with guest checks,
# so this script launches the guest itself and emits TAP directly.

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

echo "# CXL BI QMP hotplug suite t17"

launch_qemu \
  -object memory-backend-ram,id=m0,size=1G \
  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2,x-256b-flit=on \
  -device cxl-upstream,bus=rp0,id=us0,x-256b-flit=on \
  -device cxl-downstream,port=0,bus=us0,id=dsp0,chassis=0,slot=4,x-256b-flit=on \
  -device cxl-downstream,port=1,bus=us0,id=dsp1,chassis=0,slot=5,x-256b-flit=on \
  -device cxl-downstream,port=2,bus=us0,id=dsp2,chassis=0,slot=6,x-256b-flit=on \
  -device cxl-type3,bus=dsp0,volatile-memdev=m0,id=ep0,sn=0x171,x-256b-flit=on,hdm-db=on \
  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k,cxl-fmw.0.back-invalidate=on \
  || { fail "qemu launch"; exit 1; }
if wait_for_guest 180; then
	ok "guest booted (1 endpoint, 2 empty DSPs)"
else
	fail "guest booted (1 endpoint, 2 empty DSPs)"; exit 1
fi
guest_scp "$BI_TESTS_DIR/guest/hotplug-helpers.sh" root@localhost:/tmp/ \
	>/dev/null
g() { guest_ssh "$@" 2>/dev/null; }
gh() { guest_ssh "source /tmp/hotplug-helpers.sh; $*" 2>/dev/null; }
dmesg_count() { g dmesg | grep -c "$1"; }

# hot_add <sn-hex> <dsp> <backend-id>: returns 0 iff qemu accepted it.
# QMP device_add wants integer properties as JSON numbers (a quoted
# "0x171" is rejected), while the guest's serial sysfs prints %#llx;
# the hex form stays the guest-side key, decimal goes on the wire.
hot_add() {
	local r snd=$(( $1 ))
	qmp_cmd '{"execute":"object-add","arguments":{"qom-type":"memory-backend-ram","id":"'"$3"'","size":1073741824}}' >/dev/null
	r=$(qmp_cmd '{"execute":"device_add","arguments":{"driver":"cxl-type3","bus":"'"$2"'","volatile-memdev":"'"$3"'","id":"hp-'"$3"'","sn":'"$snd"',"x-256b-flit":true,"hdm-db":true}}')
	echo "$r" | grep -q '"return"' && return 0
	echo "# device_add: $r"
	return 1
}
# wait_sn_state <sn> <present|absent> [timeout_s]
# "present" waits for the endpoint DECODER, not just the memdev: the
# QMP add is done when cxl_pci probes, but the memdev -> endpoint port
# -> decoders chain (cxl_mem/cxl_port probes) completes after it.
wait_sn_state() {
	local i=0 t=${3:-30}
	while [ $i -lt "$t" ]; do
		case $2 in
		present) [ -n "$(gh dec_of_sn "$1")" ] && return 0 ;;
		absent)  [ -z "$(gh mem_of_sn "$1")" ] && return 0 ;;
		esac
		sleep 1; i=$((i + 1))
	done
	return 1
}

# --- scenario 1: baseline on the cold-plugged endpoint ----------------
out=$(gh mkreg_sn 0x171)
case $out in
*"bi=1") ok "baseline: HDM-DB region commits on cold-plugged endpoint" ;;
*)	 fail "baseline: HDM-DB region commits (got '$out')" ;;
esac
gh rmreg_all

# --- scenario 2: hot-add into empty dsp1 ------------------------------
g "dmesg -C"
if ! hot_add 0x172 dsp1 m1; then
	skip "hot-add accepted by QEMU (no cxl-type3 hotplug support)"
	skip "hot-added endpoint enumerated"
	skip "BI enabled on hot-added path"
	skip "region commits on hot-added endpoint"
	skip "hot-remove with committed region"
	skip "survivor path stays BI-enabled"
	skip "add-after-remove into spare slot"
	exit 0
fi
ok "hot-add accepted by QEMU (dsp1)"
if wait_sn_state 0x172 present 30; then
	ok "hot-added endpoint enumerated (pciehp)"
else
	fail "hot-added endpoint enumerated (pciehp)"; exit 1
fi
# The decoder wait above lands between decoder registration and
# cxl_bi_setup() in the endpoint probe on rare timing; give the
# enable message a few seconds rather than one shot.
for i in 1 2 3 4 5; do
	[ "$(dmesg_count 'BI requests enabled')" -ge 1 ] && break
	sleep 1
done
if [ "$(dmesg_count 'BI requests enabled')" -ge 1 ]; then
	ok "BI enabled through hot-added dport path"
else
	fail "BI enabled through hot-added dport path"
fi
out=$(gh mkreg_sn 0x172)
case $out in
*"bi=1") ok "HDM-DB region commits on hot-added endpoint" ;;
*)	 fail "HDM-DB region commits on hot-added endpoint (got '$out')" ;;
esac
gh rmreg_all

# --- scenario 3: hot-remove with a committed HDM-DB region ------------
out=$(gh mkreg_sn 0x171)
case $out in
*"bi=1") ok "removal setup: region re-committed on sn=0x171" ;;
*)	 fail "removal setup: region re-committed (got '$out')" ;;
esac
reg=${out%% *}
g "dmesg -C"
qmp_cmd '{"execute":"device_del","arguments":{"id":"ep0"}}' >/dev/null
t0=$(date +%s)
if wait_sn_state 0x171 absent 30; then
	ok "hot-remove completed guest-side ($(($(date +%s) - t0))s incl. 5s attn-button)"
else
	fail "hot-remove completed guest-side (timeout)"
fi
# Hot-remove does not delete the region: it is a child of the root
# decoder and survives losing its only target. The detach work
# decommits it (the decoder reap) and leaves the shell for userspace
# to delete. Poll for the decommit, then clean it up.
deco=""
for i in $(seq 1 20); do
	deco=$(g cat "/sys/bus/cxl/devices/$reg/commit")
	[ "$deco" = 0 ] && break
	sleep 0.5
done
if [ "$deco" = 0 ]; then
	ok "region decommitted by hot-remove ($reg persists, commit=0)"
else
	fail "region decommitted by hot-remove (commit='$deco')"
fi
gh rmreg_all
if [ "$(dmesg_count 'BI requests disabled')" -ge 1 ]; then
	ok "BI disabled during hot-remove teardown"
else
	fail "BI disabled during hot-remove teardown"
fi
if [ "$(g dmesg | grep -cE "$SPLAT_RE")" = 0 ]; then
	ok "no WARN/BUG/lockdep splat across hot-remove"
else
	fail "no WARN/BUG/lockdep splat across hot-remove"
	g dmesg | grep -E "$SPLAT_RE" | head -3 | \
		sed 's/^/# /'
fi
# Survivor: the USP/RP must still be BI-enabled for sn=0x172 (nr_bi),
# proven end-to-end by a fresh commit on it.
out=$(gh mkreg_sn 0x172)
case $out in
*"bi=1") ok "survivor path stays BI-enabled (post-removal commit)" ;;
*)	 fail "survivor path stays BI-enabled (got '$out')" ;;
esac
gh rmreg_all

# --- scenario 4: add-after-remove (spare slot dsp2) --------------------
# dsp0's slot is not reusable: QEMU never finalizes the cxl-type3
# unplug (see header), so the third device goes into dsp2.
g "dmesg -C"
if ! hot_add 0x173 dsp2 m2; then
	fail "add-after-remove accepted by QEMU (dsp2)"
	exit 1
fi
if wait_sn_state 0x173 present 30; then
	ok "add-after-remove endpoint enumerated (dsp2)"
else
	fail "add-after-remove endpoint enumerated (dsp2)"; exit 1
fi
out=$(gh mkreg_sn 0x173)
case $out in
*"bi=1") ok "HDM-DB region commits after a prior hot-remove" ;;
*)	 fail "HDM-DB region commits after a prior hot-remove (got '$out')" ;;
esac
gh rmreg_all
if [ "$(g dmesg | grep -c 'BI setup failed')" = 0 ]; then
	ok "no 'BI setup failed' across the hotplug lifecycle"
else
	fail "no 'BI setup failed' across the hotplug lifecycle"
fi
# Host-driven suites return before run-all's generic oracle fold, so
# check it here: no BI programming across the whole hotplug lifecycle
# (adds included) may contradict the topology.
if [ "$(grep -c "CXL BI oracle" "$RUNDIR/qemu.log" 2>/dev/null)" = 0 ]; then
	ok "qemu BI oracle silent across the hotplug lifecycle"
else
	fail "qemu BI oracle silent across the hotplug lifecycle"
	grep "CXL BI oracle" "$RUNDIR/qemu.log" | sed 's/^/# /'
fi
g dmesg > "$OUT/t17.dmesg" 2>/dev/null

exit $((FAIL != 0))
