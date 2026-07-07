#!/bin/bash
# t5 phase 2: shared-RP nr_bi refcount.
#
# Invariant (patch 2, __cxl_bi_ctrl_dport ROOT_PORT branch): the root
# port's BI Decoder Control register carries a refcount so that BI
# stays enabled while any of its child endpoints have committed BI.
# With two endpoints sharing an RP (t5's topology), unbinding one
# endpoint must NOT flip the RP's BI off; unbinding the second must.
#
# Direct visibility of dport->nr_bi from userspace is not exposed.
# What we CAN observe: rebinding after a partial unbind must not
# report "BI setup failed" (would mean the RP got into a bad state)
# and endpoint bi must go back to 1 once its region is rebuilt.

set -o pipefail
CXL=/sys/bus/cxl/devices
PASS=0; FAIL=0; N=0
ok()   { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - $1"; }
fail() { N=$((N+1)); FAIL=$((FAIL+1)); echo "not ok $N - $1"; }
expect_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (got '$2' want '$3')"; fi
}

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
bdf_for_mem() {
	readlink -f "$CXL/$1" | \
		grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]' | tail -1
}

echo "# t5 phase 2: shared-RP nr_bi refcount"

rd=$(root_decoder_bi)
mems=( $(for m in $CXL/mem*; do basename "$m"; done | sort) )
[ "${#mems[@]}" = 2 ] || \
	{ echo "Bail out! need 2 memdevs, got ${#mems[@]}"; exit 1; }
dec0=$(ep_decoder_for_mem "${mems[0]}")
dec1=$(ep_decoder_for_mem "${mems[1]}")
bdf0=$(bdf_for_mem "${mems[0]}")
bdf1=$(bdf_for_mem "${mems[1]}")

# Build two independent 1-way HDM-DB regions (one per endpoint) so
# unbinding one does not tear the other down.
make_region() {
	local dec=$1 sz=$((256 << 20))
	local region; region=$(cat "$CXL/$rd/create_ram_region")
	echo "$region" > "$CXL/$rd/create_ram_region" 2>/dev/null || return 1
	local R=$CXL/$region
	echo 256 > "$R/interleave_granularity"
	echo 1 > "$R/interleave_ways"
	echo "$sz" > "$R/size"
	echo ram > "$CXL/$dec/mode" 2>/dev/null
	echo "$sz" > "$CXL/$dec/dpa_size"
	echo "$dec" > "$R/target0"
	echo 1 > "$R/commit" || return 1
	echo "$region"
}

r0=$(make_region "$dec0")
r1=$(make_region "$dec1")
[ -n "$r0" ] && [ -n "$r1" ] || \
	{ echo "Bail out! initial region setup failed"; exit 1; }
expect_eq "both endpoints bi=1 before partial unbind" \
	"$(cat "$CXL/$dec0/bi")$(cat "$CXL/$dec1/bi")" "11"

# Tear down mem0's region and unbind it. mem1's region stays committed
# and must remain BI-enabled - so the shared RP must NOT drop BI.
echo 0 > "$CXL/$r0/commit" 2>/dev/null
echo "$r0" > "$CXL/$rd/delete_region" 2>/dev/null
echo "$bdf0" > /sys/bus/pci/drivers/cxl_pci/unbind 2>/dev/null || \
	echo "${mems[0]}" > /sys/bus/cxl/drivers/cxl_mem/unbind 2>/dev/null
for i in $(seq 1 30); do
	[ -e "$CXL/$dec0" ] || break
	sleep 0.2
done

expect_eq "mem1 still bi=1 after mem0 unbind" \
	"$(cat "$CXL/$dec1/bi")" 1
if dmesg | grep -qE "BI setup failed|BI dport disable failed"; then
	fail "no BI setup/disable errors on partial unbind"
else
	ok "no BI setup/disable errors on partial unbind"
fi

# Rebind mem0 and verify it rearms.
echo "$bdf0" > /sys/bus/pci/drivers/cxl_pci/bind 2>/dev/null || \
	echo "${mems[0]}" > /sys/bus/cxl/drivers/cxl_mem/bind 2>/dev/null
for i in $(seq 1 60); do
	dec0r=$(ep_decoder_for_mem "${mems[0]}")
	[ -n "$dec0r" ] && break
	sleep 0.5
done
if [ -z "$dec0r" ]; then
	fail "mem0 endpoint decoder returned after rebind"
	echo "1..$N"; exit $((FAIL != 0))
fi
ok "mem0 endpoint decoder returned after rebind"

r0=$(make_region "$dec0r")
if [ -n "$r0" ]; then
	ok "mem0 region recommitted after partial cycle"
	expect_eq "mem0 endpoint bi=1 after rebind" \
		"$(cat "$CXL/$dec0r/bi")" 1
	expect_eq "mem1 still bi=1 (unaffected)" \
		"$(cat "$CXL/$dec1/bi")" 1
	echo 0 > "$CXL/$r0/commit" 2>/dev/null
	echo "$r0" > "$CXL/$rd/delete_region" 2>/dev/null
else
	fail "mem0 region recommit after rebind"
fi

# Clean up mem1's region so the guest ends idle.
echo 0 > "$CXL/$r1/commit" 2>/dev/null
echo "$r1" > "$CXL/$rd/delete_region" 2>/dev/null

echo "1..$N"
echo "# passed: $PASS  failed: $FAIL"
exit $((FAIL != 0))
