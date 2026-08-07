#!/bin/bash
# Host-side CXL BI test orchestrator: boots each topology, pushes the
# guest driver, runs the suite, collects TAP + dmesg. Exit 0 iff all
# suites pass.
BI_TESTS_DIR="$(dirname "$(readlink -f "$0")")"
source "$BI_TESTS_DIR/topo-lib.sh"
OUT=${OUT:-$RUNDIR/results}
mkdir -p "$OUT"
TOTAL_FAIL=0

run_suite() { # run_suite <topo-script> <suite>
	local topo=$1 suite=$2
	echo "=== $suite ($(basename "$topo")) ==="

	# Host-only suites (t13 etc.) run the topology script directly on
	# the host and emit TAP without booting a guest.
	if [[ "$HOST_ONLY_SUITES" == *" $suite "* ]]; then
		"$topo" | tee "$OUT/$suite.tap"
		local rc=${PIPESTATUS[0]}
		[ "$rc" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL+1))
		return
	fi

	"$topo" || { echo "launch failed"; TOTAL_FAIL=$((TOTAL_FAIL+1)); return; }
	if ! wait_for_guest 180; then
		echo "guest boot failed"; TOTAL_FAIL=$((TOTAL_FAIL+1)); return
	fi
	guest_scp "$BI_TESTS_DIR/guest/run-tests.sh" root@localhost:/tmp/ \
		>/dev/null
	# Do NOT dmesg -C here: the driver's bi_setup_succeeded / boot-state
	# checks want the cxl_bi_setup traces from the initial cxl_mem probe.
	# Phase-2 scripts clear dmesg themselves when they need a fresh view.
	guest_ssh "bash /tmp/run-tests.sh $suite" \
		| tee "$OUT/$suite.tap"
	local rc=${PIPESTATUS[0]}
	guest_ssh "dmesg" > "$OUT/$suite.dmesg" 2>/dev/null

	# t2 phase 2 exercises the unbind/rebind lifecycle. The BI enable
	# is registered as a devm action on cxlmd->dev; unbind must clear
	# BI on the device and every dport; rebind must re-enable.
	if [ "$suite" = t2 ] && [ "$rc" -eq 0 ]; then
		echo "--- t2 phase 2: unbind/rebind lifecycle ---"
		guest_scp "$BI_TESTS_DIR/guest/unbindrebind-phase.sh" \
			  root@localhost:/tmp/ >/dev/null
		guest_ssh "dmesg -C; bash /tmp/unbindrebind-phase.sh" \
			| tee "$OUT/t2-unbindrebind.tap"
		local rc2=${PIPESTATUS[0]}
		guest_ssh dmesg > "$OUT/t2-unbindrebind.dmesg" 2>/dev/null
		[ "$rc2" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL+1))
	fi

	# t2 phase 3 races a decoder-attribute reader against repeated
	# memdev-driven teardown with a committed HDM-DB region live at
	# each unbind: covers the endpoint-vs-cxlds lifecycle orderings
	# (teardown-before-null, unregister-before-endpoint-clear,
	# dealloc-before-unmap).
	if [ "$suite" = t2 ] && [ "$rc" -eq 0 ]; then
		echo "--- t2 phase 3: lifecycle reader race ---"
		guest_scp "$BI_TESTS_DIR/guest/lifecycle-race-phase.sh" \
			  root@localhost:/tmp/ >/dev/null
		guest_ssh "bash /tmp/lifecycle-race-phase.sh" \
			| tee "$OUT/t2-lifecycle.tap"
		local rc3=${PIPESTATUS[0]}
		guest_ssh dmesg > "$OUT/t2-lifecycle.dmesg" 2>/dev/null
		[ "$rc3" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL+1))
	fi

	# t9 phase 2 unbinds the outer switch port's driver with a
	# committed HDM-H region live (BI is refused on cascades): the
	# devres cascade must tear the child subtree down first, reap
	# the emptied outer port, and rebuild the whole cascade on
	# cxl_mem rebind, refusing BI again at the re-probe.
	if [ "$suite" = t9 ] && [ "$rc" -eq 0 ]; then
		echo "--- t9 phase 2: switch-unbind cascade ---"
		guest_scp "$BI_TESTS_DIR/guest/switch-cascade-phase.sh" \
			  root@localhost:/tmp/ >/dev/null
		guest_ssh "dmesg -C; bash /tmp/switch-cascade-phase.sh" \
			| tee "$OUT/t9-cascade.tap"
		local rc2=${PIPESTATUS[0]}
		guest_ssh dmesg > "$OUT/t9-cascade.dmesg" 2>/dev/null
		[ "$rc2" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL+1))
	fi

	# t5 (2-way interleave) phase 2 exercises nr_bi refcount on the
	# shared root port when one endpoint's memdev is hot-removed.
	if [ "$suite" = t5 ] && [ "$rc" -eq 0 ]; then
		echo "--- t5 phase 2: shared RP nr_bi refcount ---"
		guest_scp "$BI_TESTS_DIR/guest/nrbi-refcount-phase.sh" \
			  root@localhost:/tmp/ >/dev/null
		guest_ssh "dmesg -C; bash /tmp/nrbi-refcount-phase.sh" \
			| tee "$OUT/t5-nrbi.tap"
		local rc2=${PIPESTATUS[0]}
		guest_ssh dmesg > "$OUT/t5-nrbi.dmesg" 2>/dev/null
		[ "$rc2" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL+1))
	fi

	[ "$rc" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL+1))

	# The qemu BI oracle (-d guest_errors, Table 8-157 messages) must
	# stay silent across the whole suite, phases included: it flags
	# any RP/DSP BI Decoder programming that contradicts the topology.
	if [ "$(grep -c "Table 8-157" "$RUNDIR/qemu.log" 2>/dev/null)" != 0 ]
	then
		echo "qemu BI oracle flagged mis-programming:"
		grep "Table 8-157" "$RUNDIR/qemu.log"
		TOTAL_FAIL=$((TOTAL_FAIL+1))
	fi
	stop_qemu
}

# suite -> topology script
declare -A TOPO=(
	[t1]=t1-direct.sh
	[t2]=t2-switch.sh
	[t3]=t3-hdmh-cfmws.sh
	[t4]=t4-nobi-dev.sh
	[t5]=t5-2way.sh
	[t6]=t6-usp-nort.sh
	[t7]=t7-noflit-uplink.sh
	[t8]=t8-noflit-dsp.sh
	[t9]=t9-cascade.sh
	[t10]=t10-cross-rp.sh
	[t11]=t11-pmem.sh
	[t12]=t12-mixed-iw.sh
	[t13]=t13-hostonly-bi.sh
	[t14]=t14-mixed-cfmws.sh
	[t15]=t15-decoder-reuse.sh
	[t16]=t16-autodiscover.sh
	[t17]=t17-hotplug.sh
	[t18]=t18-storm.sh
	[t19]=t19-manual-2way.sh
	[t20]=t20-manual-mixed.sh
	[t21]=t21-bi-fail-fallback.sh
	[t22]=t22-unknown-coherency.sh
)
# Host-driven suites: the topology script emits TAP directly instead
# of pushing run-tests.sh into a guest. t13 is a negative launch (no
# guest at all); t16 orchestrates its own multi-boot x-committed
# scenarios; t17 interleaves QMP hotplug with guest checks. run_suite
# handles them below.
HOST_ONLY_SUITES=" t13 t16 t17 "
# Default order: happy paths first, then mixed configs / fail-closed
# gates, then the deeper topologies, then the guest-less checks. Later
# suites depend on earlier invariants (region create, root cap_back_invalidate,
# endpoint bi) already passing.
ORDER="t1 t2 t5 t3 t4 t6 t7 t8 t9 t10 t11 t12 t14 t15 t19 t20 t21 t22 t18 t16 t17 t13"

# No args: run everything. Otherwise run only the named suites, e.g.
#   ./run-all.sh t2          # one suite (incl. its unbind/rebind phase)
#   ./run-all.sh t4 t8       # a subset
SUITES="${*:-$ORDER}"
for s in $SUITES; do
	topo=${TOPO[$s]}
	if [ -z "$topo" ]; then
		echo "unknown suite '$s' (choices: $ORDER)" >&2
		exit 2
	fi
	run_suite "$BI_TESTS_DIR/topos/$topo" "$s"
done

echo "==================================================="
echo "suites failed: $TOTAL_FAIL (results in $OUT)"
exit $((TOTAL_FAIL != 0))
