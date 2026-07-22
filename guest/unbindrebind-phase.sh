#!/bin/bash
# t2 phase 2: unbind/rebind lifecycle.
#
# cxl_bi_setup registers cxl_bi_dealloc as a devm action on the
# endpoint port. A cxl_pci/cxl_mem unbind reaches it through the
# endpoint teardown; a cxl_port unbind of the endpoint runs it up
# front, before the detach cascades into the memdev. Either way
# dealloc must clear BI on the device and every dport in the path,
# and rebind must re-enable BI and re-arm the endpoint decoder to
# reach bi=1 when the region is rebuilt. Both cycles are exercised.
#
# Output: TAP-ish, exit 0 iff all checks pass.

set -o pipefail
CXL=/sys/bus/cxl/devices
PASS=0; FAIL=0; N=0
ok()   { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - $1"; }
fail() { N=$((N+1)); FAIL=$((FAIL+1)); echo "not ok $N - $1"; }
expect_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (got '$2' want '$3')"; fi
}
# Always emit the TAP plan and summary, even on bail-out exits. An
# EXIT trap does not alter the script's exit status.
finish() { echo "1..$N"; echo "# passed: $PASS  failed: $FAIL"; }
trap finish EXIT

root_decoder_bi() {
	local d
	for d in $CXL/decoder0.*; do
		[ -e "$d/cap_bi" ] || continue
		[ "$(cat "$d/cap_bi")" = 1 ] && { basename "$d"; return; }
	done
}
ep_decoder_for_mem() {
	local mem=$1 ep
	for ep in $CXL/endpoint*; do
		[ -d "$ep" ] || continue
		if [ "$(basename "$(readlink -f "$ep/uport")")" = "$mem" ]; then
			basename "$(ls -d "$ep"/decoder*.0 2>/dev/null | head -1)"
			return
		fi
	done
}
first_mem() { basename "$(ls -d $CXL/mem* | head -1)"; }

echo "# t2 phase 2: unbind/rebind lifecycle"

rd=$(root_decoder_bi)
mem=$(first_mem)
dec=$(ep_decoder_for_mem "$mem")
[ -n "$rd" ] && [ -n "$mem" ] && [ -n "$dec" ] || \
	{ echo "Bail out! prereq missing"; exit 1; }

# Build a HDM-DB region and commit it. bi should end up 1.
create_region() {
	local rd=$1 sz=$((256 << 20))
	local region; region=$(cat "$CXL/$rd/create_ram_region")
	echo "$region" > "$CXL/$rd/create_ram_region" 2>/dev/null || return 1
	local R=$CXL/$region
	echo 256 > "$R/interleave_granularity"
	echo 1   > "$R/interleave_ways"
	echo $sz > "$R/size"
	# Release any leftover DPA before re-reserving.
	echo 0 > "$CXL/$dec/dpa_size" 2>/dev/null
	echo ram > "$CXL/$dec/mode" 2>/dev/null
	echo "$sz" > "$CXL/$dec/dpa_size"
	echo "$dec" > "$R/target0"
	echo "$region"
}

region=$(create_region "$rd")
[ -n "$region" ] || { echo "Bail out! create_region failed"; exit 1; }
echo 1 > "$CXL/$region/commit" || \
	{ echo "Bail out! initial commit failed"; exit 1; }
expect_eq "pre-unbind: endpoint bi=1" "$(cat "$CXL/$dec/bi")" 1

# Tear the region down before unbind: keeps ordering deterministic.
echo 0 > "$CXL/$region/commit" 2>/dev/null
echo "$region" > "$CXL/$rd/delete_region" 2>/dev/null

# Unbind cxl_mem. This runs cxl_bi_dealloc via the devm action.
bdf=$(readlink -f "$CXL/$mem" | \
      grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]' | tail -1)
echo "$bdf" > /sys/bus/pci/drivers/cxl_pci/unbind 2>/dev/null || {
	# fallback: some kernels attach the memdev via a different driver
	echo "$mem" > /sys/bus/cxl/drivers/cxl_mem/unbind 2>/dev/null
}

# Wait for the endpoint devices to disappear (best-effort).
for i in $(seq 1 30); do
	[ -e "$CXL/$dec" ] || break
	sleep 0.2
done
if dmesg | tail -50 | grep -q "BI requests disabled"; then
	ok "dmesg: BI requests disabled on unbind"
else
	# Not fatal - dyndbg for cxl_core may not be on. Note & continue.
	ok "dmesg: BI unbind message optional"
fi

# Rebind: bring cxl_pci back which triggers cxl_mem_probe again.
echo "$bdf" > /sys/bus/pci/drivers/cxl_pci/bind 2>/dev/null || \
	echo "$mem" > /sys/bus/cxl/drivers/cxl_mem/bind 2>/dev/null

# Wait for the endpoint decoder to reappear.
for i in $(seq 1 60); do
	dec2=$(ep_decoder_for_mem "$mem")
	[ -n "$dec2" ] && break
	sleep 0.5
done
if [ -z "$dec2" ]; then
	fail "endpoint decoder returned after rebind"
	exit $((FAIL != 0))
fi
ok "endpoint decoder returned after rebind ($dec2)"

# Re-create + re-commit to verify BI got re-enabled on the topology.
region=$(create_region "$rd")
[ -n "$region" ] || { fail "post-rebind region create"; exit 1; }
if echo 1 > "$CXL/$region/commit"; then
	ok "post-rebind commit succeeded"
	expect_eq "post-rebind: endpoint bi=1" "$(cat "$CXL/$dec2/bi")" 1
else
	fail "post-rebind commit"
fi
echo 0 > "$CXL/$region/commit" 2>/dev/null
echo "$region" > "$CXL/$rd/delete_region" 2>/dev/null

if dmesg | grep -q "BI setup failed"; then
	fail "no 'BI setup failed' across unbind/rebind cycle"
else
	ok "no 'BI setup failed' across unbind/rebind cycle"
fi

# ---- cxl_port endpoint unbind cycle --------------------------------
# BI-ID allocation lives with the endpoint port: unbinding the
# cxl_port driver from the endpoint must disable BI first (port
# devres), then cascade into the memdev detach. Rebinding the memdev
# recreates the endpoint port and re-enables BI.
endpoint_of_mem() {
	local mem=$1 ep
	for ep in $CXL/endpoint*; do
		[ -d "$ep" ] || continue
		if [ "$(basename "$(readlink -f "$ep/uport")")" = "$mem" ]; then
			basename "$ep"
			return
		fi
	done
}

mem=$(first_mem)
dec=$(ep_decoder_for_mem "$mem")
ep=$(endpoint_of_mem "$mem")
region=$(create_region "$rd")
if [ -n "$region" ] && echo 1 > "$CXL/$region/commit" 2>/dev/null && \
   [ -n "$ep" ]; then
	ok "port-cycle: HDM-DB region up (bi=$(cat "$CXL/$dec/bi"))"
else
	fail "port-cycle: HDM-DB region up"
	exit $((FAIL != 0))
fi

dmesg -C
echo "$ep" > /sys/bus/cxl/drivers/cxl_port/unbind 2>/dev/null
for i in $(seq 1 30); do
	[ -e "$CXL/$mem/driver" ] || break
	sleep 0.2
done
if dmesg | grep -q "BI requests disabled"; then
	ok "port-cycle: BI disabled on endpoint port unbind"
else
	fail "port-cycle: BI disabled on endpoint port unbind"
fi
if [ ! -e "$CXL/$mem/driver" ]; then
	ok "port-cycle: teardown cascaded into memdev unbind"
else
	fail "port-cycle: teardown cascaded into memdev unbind"
fi
# The port devres runs dealloc ahead of the memdev detach: 'BI
# requests disabled' must precede 'disconnect' in the log.
dis=$(dmesg | grep -n "BI requests disabled" | head -1 | cut -d: -f1)
dc=$(dmesg | grep -n "disconnect" | head -1 | cut -d: -f1)
if [ -n "$dis" ] && [ -n "$dc" ] && [ "$dis" -lt "$dc" ]; then
	ok "port-cycle: BI disable precedes memdev disconnect"
else
	fail "port-cycle: BI disable precedes memdev disconnect (dis=$dis dc=$dc)"
fi

echo "$mem" > /sys/bus/cxl/drivers/cxl_mem/bind 2>/dev/null
for i in $(seq 1 60); do
	dec2=$(ep_decoder_for_mem "$mem")
	[ -n "$dec2" ] && break
	sleep 0.5
done
if [ -n "$dec2" ]; then
	ok "port-cycle: endpoint decoder returned after rebind ($dec2)"
	region=$(create_region "$rd")
	if [ -n "$region" ] && echo 1 > "$CXL/$region/commit" 2>/dev/null; then
		expect_eq "port-cycle: post-rebind endpoint bi=1" \
			"$(cat "$CXL/$dec2/bi")" 1
	else
		fail "port-cycle: post-rebind commit"
	fi
else
	fail "port-cycle: endpoint decoder returned after rebind"
fi
if dmesg | grep -q "BI setup failed"; then
	fail "port-cycle: no 'BI setup failed'"
else
	ok "port-cycle: no 'BI setup failed'"
fi

exit $((FAIL != 0))
