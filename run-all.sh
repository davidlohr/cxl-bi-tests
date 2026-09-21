#!/bin/bash
# Host-side CXL BI test orchestrator: boots each topology, pushes the
# guest driver, runs the suite, collects TAP + dmesg. Exit 0 iff all
# suites pass.
BI_TESTS_DIR="$(dirname "$(readlink -f "$0")")"
source "$BI_TESTS_DIR/topo-lib.sh"
OUT=${OUT:-$RUNDIR/results}
mkdir -p "$OUT"
TOTAL_FAIL=0

# tap_fold_fail <tapfile> <description> [diag-file]
# Merge a host-discovered failure into a TAP file the guest already
# closed: append the test, renumber the plan, and fix the summary so
# the file cannot claim "failed: 0" while the host found a problem.
# Left alone if the plan is missing or a SKIP (nothing ran).
tap_fold_fail() {
	local tap=$1 desc=$2 diag=$3

	[ -f "$tap" ] || return 0
	if ! grep -q '^1\.\.[0-9]\+$' "$tap"; then
		{ echo "not ok - $desc"
		  [ -n "$diag" ] && sed 's/^/# /' "$diag"; } >> "$tap"
		return 0
	fi
	awk -v desc="$desc" -v diag="$diag" '
		/^1\.\.[0-9]+$/    { n = substr($0, 4) + 0; next }
		/^# passed: .* failed: / { pass = $3; fail = $5; next }
		{ print }
		END {
			printf "not ok %d - %s\n", n + 1, desc
			while (diag != "" && (getline l < diag) > 0)
				printf "# %s\n", l
			printf "1..%d\n", n + 1
			printf "# passed: %d  failed: %d\n", pass, fail + 1
		}' "$tap" > "$tap.tmp" && mv "$tap.tmp" "$tap"
}

# kmemleak_scan <suite>
# kmemleak reports only objects older than its minimum age and only
# after a scan, so settle, scan twice (the first pass primes), and
# keep whatever it says as a diagnostic. Not a failure: a stock kernel
# reports leaks of its own, so the report is evidence to read rather
# than a verdict. Always says which of the three states it found -
# a silent no-op would be indistinguishable from a clean scan.
kmemleak_scan() {
	local suite=$1 n
	if ! guest_ssh "test -e /sys/kernel/debug/kmemleak ||
			mount -t debugfs none /sys/kernel/debug 2>/dev/null;
			test -e /sys/kernel/debug/kmemleak" 2>/dev/null; then
		echo "# kmemleak: unavailable (no debugfs entry in the guest)"
		return 0
	fi
	guest_ssh "sleep 7; echo scan > /sys/kernel/debug/kmemleak;
		   sleep 7; echo scan > /sys/kernel/debug/kmemleak" \
		>/dev/null 2>&1
	guest_ssh "cat /sys/kernel/debug/kmemleak" > "$OUT/$suite.kmemleak" \
		2>/dev/null
	n=$(grep -c 'unreferenced object' "$OUT/$suite.kmemleak" 2>/dev/null)
	if [ "${n:-0}" -eq 0 ]; then
		rm -f "$OUT/$suite.kmemleak"
		echo "# kmemleak: clean"
	else
		echo "# kmemleak: $n unreferenced object(s) -> $suite.kmemleak"
	fi
}

# tap_verdict <tapfile>
# Echo a suite's final plan and summary. Called once the host-side
# checks have been folded in: the guest writes its own trailer before
# any of them run, so streaming that live reports "failed: 0" for a
# suite the host is about to fail.
tap_verdict() {
	[ -f "$1" ] && grep -E '^1\.\.|^# passed: ' "$1" | tail -2
}

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
	# The guest's trailer is kept out of the live stream and replayed
	# by tap_verdict below, once host-side checks have been folded in.
	guest_ssh "bash /tmp/run-tests.sh $suite" | tee "$OUT/$suite.tap" \
		| grep --line-buffered -Ev '^1\.\.|^# passed: '
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
	# committed HDM-H region live: the devres cascade must tear the
	# child subtree down first, disable BI on the way out, reap the
	# emptied outer port, and rebuild the whole cascade on cxl_mem
	# rebind, re-enabling BI at the re-probe.
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

	# t5 phase 3 unbinds a member of the committed 2-way region, the
	# only shape that runs the teardown through cxl_region_decode_reset()
	# on every target and a dport the surviving peer still holds.
	if [ "$suite" = t5 ] && [ "$rc" -eq 0 ]; then
		echo "--- t5 phase 3: committed multi-target member unbind ---"
		guest_scp "$BI_TESTS_DIR/guest/multitarget-unbind-phase.sh" \
			  root@localhost:/tmp/ >/dev/null
		guest_ssh "dmesg -C; bash /tmp/multitarget-unbind-phase.sh" \
			| tee "$OUT/t5-mtunbind.tap"
		local rc3=${PIPESTATUS[0]}
		guest_ssh dmesg > "$OUT/t5-mtunbind.dmesg" 2>/dev/null
		[ "$rc3" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL+1))
	fi

	[ "$rc" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL+1))

	# The qemu BI oracle (-d guest_errors, "CXL BI oracle" messages)
	# must stay silent across the whole suite, phases included: it
	# flags any RP/DSP BI Decoder programming that contradicts the
	# topology.
	# The guest writes its plan and summary inside the guest, where
	# host-side findings are invisible, so the result is folded into
	# the suite's TAP - otherwise the file reads "failed: 0" while
	# the oracle is flagging a real mis-programming.
	if [ "$(grep -c "CXL BI oracle" "$RUNDIR/qemu.log" 2>/dev/null)" != 0 ]
	then
		echo "qemu BI oracle flagged mis-programming:"
		grep "CXL BI oracle" "$RUNDIR/qemu.log"
		grep "CXL BI oracle" "$RUNDIR/qemu.log" > "$RUNDIR/oracle.diag"
		tap_fold_fail "$OUT/$suite.tap" "qemu BI oracle silent" \
			      "$RUNDIR/oracle.diag"
		TOTAL_FAIL=$((TOTAL_FAIL+1))
	fi
	kmemleak_scan "$suite"
	tap_verdict "$OUT/$suite.tap"
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
	[t23]=t23-commit-fault.sh
	[t24]=t24-adopt.sh
	[t25]=t25-multiswitch.sh
	[t26]=t26-type2.sh
	[t27]=t27-reset.sh
	[t28]=t28-aer.sh
	[t29]=t29-mixed-type.sh
	[t30]=t30-hdmd-window.sh
	[t31]=t31-4way-switch.sh
	[t32]=t32-2switch-2hb.sh
	[t33]=t33-2switch-2rp.sh
	[t34]=t34-refused-attach.sh
)
# Host-driven suites: the topology script emits TAP directly instead
# of pushing run-tests.sh into a guest. t13 is a negative launch (no
# guest at all); t16 orchestrates its own multi-boot x-committed
# scenarios; t17 interleaves QMP hotplug with guest checks. run_suite
# handles them below.
HOST_ONLY_SUITES=" t13 t16 t17 t23 t24 t25 t26 t27 t28 t29 t30 "
# Default order: happy paths first, then mixed configs / fail-closed
# gates, then the deeper topologies, then the guest-less checks. Later
# suites depend on earlier invariants (region create, root cap_back_invalidate,
# endpoint bi) already passing.
ORDER="t1 t2 t5 t3 t4 t6 t7 t8 t9 t10 t11 t12 t14 t15 t19 t20 t31 t32 t33 t34 t21 t22 t18 t16 t17 t23 t24 t25 t26 t27 t28 t29 t30 t13"

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
