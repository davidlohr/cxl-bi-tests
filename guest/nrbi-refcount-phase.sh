#!/bin/bash
# t5 phase 2: shared-RP nr_bi refcount, verified without two regions.
#
# The root port's BI Decoder Control state is refcounted via
# dport->nr_bi so BI stays enabled while any of its child endpoints
# has BI up. With two endpoints sharing an RP (t5's topology),
# unbinding one endpoint must NOT flip the RP's BI off; only the
# second unbind clears it.
#
# The verification does NOT try to build two independent regions - the
# single switch USP above the endpoints doesn't have enough decoders
# for two disjoint routings, and that limit is orthogonal to what we
# want to observe. Instead:
#
#  1. Commit a 1-way HDM-DB region on mem1 only. mem1 endpoint bi=1.
#  2. Unbind mem0 (bound but region-less). If the RP dropped BI
#     naively here, mem1's committed decoder would stop routing BI
#     and its bi would flip 0 (or dmesg would carry "BI dport disable
#     failed" from the dealloc walk hitting mem1's still-needed path).
#  3. Verify mem1 stays bi=1 and no BI errors landed in dmesg.
#  4. Rebind mem0 - a leaked dport BI Decoder mapping from the
#     previous bind would cause -EBUSY here on the region request.
#  5. Verify mem0 rebinds cleanly and no "BI setup failed" appeared.

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
# mems[0] will be unbound/rebound; mems[1] carries the region.
mem_unbind=${mems[0]}; mem_keep=${mems[1]}
bdf_unbind=$(bdf_for_mem "$mem_unbind")
dec_keep=$(ep_decoder_for_mem "$mem_keep")

# Build a 1-way HDM-DB region on mem_keep only. Release any prior DPA
# (t5 main body left dpa_size populated on both endpoints).
for m in "${mems[@]}"; do
	d=$(ep_decoder_for_mem "$m")
	echo 0 > "$CXL/$d/dpa_size" 2>/dev/null
done
sz=$((256 << 20))
region=$(cat "$CXL/$rd/create_ram_region")
echo "$region" > "$CXL/$rd/create_ram_region" || \
	{ echo "Bail out! create_ram_region"; exit 1; }
R=$CXL/$region
echo 256 > "$R/interleave_granularity"
echo 1 > "$R/interleave_ways"
echo "$sz" > "$R/size"
echo ram > "$CXL/$dec_keep/mode" 2>/dev/null
echo "$sz" > "$CXL/$dec_keep/dpa_size"
echo "$dec_keep" > "$R/target0"
echo 1 > "$R/commit" || { echo "Bail out! commit"; exit 1; }
expect_eq "mem_keep bi=1 pre-unbind" "$(cat "$CXL/$dec_keep/bi")" 1

# --- unbind mem_unbind (no region on it, BI still enabled on device)
dmesg -C
echo "$bdf_unbind" > /sys/bus/pci/drivers/cxl_pci/unbind 2>/dev/null || \
	echo "$mem_unbind" > /sys/bus/cxl/drivers/cxl_mem/unbind 2>/dev/null
# Wait for the endpoint decoder tree to disappear.
for i in $(seq 1 60); do
	[ -e "$CXL/$mem_unbind" ] || break
	sleep 0.2
done

# mem_keep must be unaffected: its endpoint bi stays 1, its region
# stays committed, and no BI dport-disable failure landed in dmesg.
expect_eq "mem_keep bi=1 after partial unbind" \
	"$(cat "$CXL/$dec_keep/bi")" 1
expect_eq "mem_keep region still committed" \
	"$(cat "$R/commit")" 1
if dmesg | grep -qE "BI dport disable failed|BI setup failed"; then
	fail "no BI errors on partial unbind"
	dmesg | grep -E "BI dport|BI setup" | sed 's/^/# /'
else
	ok "no BI errors on partial unbind"
fi

# --- rebind mem_unbind. A leaked dport BI Decoder region from the
# previous bind would surface here as -EBUSY on the request.
dmesg -C
echo "$bdf_unbind" > /sys/bus/pci/drivers/cxl_pci/bind 2>/dev/null || \
	echo "$mem_unbind" > /sys/bus/cxl/drivers/cxl_mem/bind 2>/dev/null
for i in $(seq 1 60); do
	[ -e "$CXL/$mem_unbind" ] && break
	sleep 0.5
done
if [ ! -e "$CXL/$mem_unbind" ]; then
	fail "mem_unbind memdev returned after rebind"
	echo "1..$N"; exit $((FAIL != 0))
fi
ok "mem_unbind memdev returned after rebind"

if dmesg | grep -q "BI setup failed"; then
	fail "no 'BI setup failed' on rebind"
	dmesg | grep "BI setup" | sed 's/^/# /'
else
	ok "no 'BI setup failed' on rebind"
fi
if dmesg | grep -qE "Failed to request region.*[Bb][iI]"; then
	fail "no 'Failed to request region' on BI mapping (dport leak)"
	dmesg | grep "Failed to request region" | sed 's/^/# /'
else
	ok "no 'Failed to request region' on BI mapping"
fi

# mem_keep must still be bi=1 and committed after the whole cycle.
expect_eq "mem_keep bi=1 after rebind cycle" \
	"$(cat "$CXL/$dec_keep/bi")" 1
expect_eq "mem_keep region still committed" \
	"$(cat "$R/commit")" 1

# --- clean up: mem_unbind has no region; just tear down mem_keep's.
echo 0 > "$R/commit" 2>/dev/null
echo "$region" > "$CXL/$rd/delete_region" 2>/dev/null

echo "1..$N"
echo "# passed: $PASS  failed: $FAIL"
exit $((FAIL != 0))
