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

# splat_t28_known <console>
# The one known upstream lockdep t28 surfaces, tolerated as t28's own
# splat_check does: every splat line is that circular locking report
# and the chain runs through cxl_error_detected(). AER recovery takes
# pci_bus_sem then the memdev lock, inverting the probe order; no BI
# code in any chain.
splat_t28_known() {
	local c=$1 n k
	n=$(grep -cE -- "$SPLAT_RE" <<<"$c")
	k=$(grep -c "WARNING: possible circular locking" <<<"$c")
	[ "$n" = "$k" ] && grep -q "cxl_error_detected" <<<"$c"
}

# console_scan <suite>
# Scan every boot's serial console, kept by launch_qemu, for kernel
# splats. It is the only record of the boot window and of what a
# suite's dmesg -C calls discarded, which the in-guest checks and
# $suite.dmesg never see. Kernel records only, wherever the timestamp
# starts: userspace writes to the console too, without a newline after
# a login prompt or a partial status line.
console_scan() {
	local suite=$1 f c hits nb=0
	local diag=$OUT/$suite.splats
	: > "$diag"
	for f in "$CONSOLE_ARCHIVE"/boot.*.log; do
		[ -f "$f" ] || continue
		nb=$((nb+1))
		c=$(grep -aoE '\[ *[0-9]+\.[0-9]+\] .*' "$f")
		hits=$(grep -E -- "$SPLAT_RE" <<<"$c")
		[ -n "$hits" ] || continue
		if [ "$suite" = t28 ] && splat_t28_known "$c"; then
			echo "# console $(basename "$f"): known upstream AER lockdep only"
			continue
		fi
		{ echo "$(basename "$f"):"; head -20 <<<"$hits"; } >> "$diag"
	done
	if [ -s "$diag" ]; then
		echo "serial console splat(s):"; sed 's/^/  /' "$diag"
		tap_fold_fail "$OUT/$suite.tap" "no splat on the serial console" "$diag"
		TOTAL_FAIL=$((TOTAL_FAIL+1))
	else
		rm -f "$diag"
		echo "# console: no splat across $nb boot(s)"
	fi
}

# devmem_guard <suite>
# Register checks SKIP when /dev/mem is unusable (CONFIG_IO_STRICT_DEVMEM,
# lockdown), and a SKIP counts as a pass, so a config change would turn
# every register check into a pass unnoticed. Fail the suite instead,
# unless the run has no /dev/mem by design (ALLOW_DEVMEM_SKIP=1).
devmem_guard() {
	local suite=$1 d=$RUNDIR/devmem.diag
	[ "${ALLOW_DEVMEM_SKIP:-0}" = 1 ] && return 0
	grep -hE '^ok [0-9]+ - .*# SKIP .*/dev/mem' "$OUT/$suite.tap" \
		"$OUT/$suite"-*.tap > "$d" 2>/dev/null
	[ -s "$d" ] || return 0
	echo "$(wc -l < "$d") register check(s) skipped for lack of /dev/mem"
	tap_fold_fail "$OUT/$suite.tap" "register checks ran (/dev/mem usable)" "$d"
	TOTAL_FAIL=$((TOTAL_FAIL+1))
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
	# every boot of this suite keeps its serial console here
	export CONSOLE_ARCHIVE=$OUT/$suite.console
	rm -rf "$CONSOLE_ARCHIVE"
	rm -f "$CONSOLE_LOG"
	# a previous run's phase results would otherwise be read as this
	# run's when the phases do not run
	rm -f "$OUT/$suite"-*.tap "$OUT/$suite"-*.dmesg "$OUT/$suite.splats" \
	      "$OUT/$suite.kmemleak"

	# Host-only suites (t13 etc.) run the topology script directly on
	# the host and emit TAP without booting a guest.
	if [[ "$HOST_ONLY_SUITES" == *" $suite "* ]]; then
		# the trailer is replayed by tap_verdict once the host-side
		# checks are folded in, as for guest suites below
		"$topo" | tee "$OUT/$suite.tap" \
			| grep --line-buffered -Ev '^1\.\.|^# passed: '
		local rc=${PIPESTATUS[0]}
		[ "$rc" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL+1))
		stop_qemu
		console_archive
		console_scan "$suite"
		devmem_guard "$suite"
		tap_verdict "$OUT/$suite.tap"
		return
	fi

	# a boot that never came up is the one most likely to hold a panic:
	# keep and scan its console too
	if ! "$topo"; then
		echo "launch failed"; TOTAL_FAIL=$((TOTAL_FAIL+1))
		stop_qemu; console_archive; console_scan "$suite"; return
	fi
	if ! wait_for_guest 180; then
		echo "guest boot failed"; TOTAL_FAIL=$((TOTAL_FAIL+1))
		stop_qemu; console_archive; console_scan "$suite"; return
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

	# t5 phase 4 clears BI Enable on the second member of a 2-way
	# HDM-DB region between attach and commit: the commit re-check
	# must undo BOTH targets, including the one that already passed.
	if [ "$suite" = t5 ] && [ "$rc" -eq 0 ]; then
		echo "--- t5 phase 4: multi-target commit undo ---"
		guest_scp "$BI_TESTS_DIR/guest/multitarget-undo-phase.sh" \
			  root@localhost:/tmp/ >/dev/null
		guest_ssh "dmesg -C; bash /tmp/multitarget-undo-phase.sh" \
			| tee "$OUT/t5-mtundo.tap"
		local rc4=${PIPESTATUS[0]}
		guest_ssh dmesg > "$OUT/t5-mtundo.dmesg" 2>/dev/null
		[ "$rc4" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL+1))
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
	devmem_guard "$suite"
	kmemleak_scan "$suite"
	stop_qemu
	console_archive
	console_scan "$suite"
	tap_verdict "$OUT/$suite.tap"
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
	[t35]=t35-noflit-usp.sh
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
ORDER="t1 t2 t5 t3 t4 t6 t7 t8 t35 t9 t10 t11 t12 t14 t15 t19 t20 t31 t32 t33 t34 t21 t22 t18 t16 t17 t23 t24 t25 t26 t27 t28 t29 t30 t13"

# No args: run everything. Otherwise run only the named suites, e.g.
#   ./run-all.sh t2          # one suite (incl. its unbind/rebind phase)
#   ./run-all.sh t4 t8       # a subset
SUITES="${*:-$ORDER}"
FAILED=
for s in $SUITES; do
	topo=${TOPO[$s]}
	if [ -z "$topo" ]; then
		echo "unknown suite '$s' (choices: $ORDER)" >&2
		exit 2
	fi
	# run_suite counts every finding; a suite fails once
	before=$TOTAL_FAIL
	run_suite "$BI_TESTS_DIR/topos/$topo" "$s"
	if [ "$TOTAL_FAIL" -gt "$before" ]; then
		TOTAL_FAIL=$((before + 1))
		FAILED="$FAILED $s"
	fi
done

echo "==================================================="
echo "suites failed: $TOTAL_FAIL${FAILED:+ (${FAILED# })} (results in $OUT)"
exit $((TOTAL_FAIL != 0))
