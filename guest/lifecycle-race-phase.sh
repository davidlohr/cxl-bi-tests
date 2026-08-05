#!/bin/bash
# t2 phase 3: endpoint-vs-cxlds lifecycle under sysfs reader fire.
#
# cxl_memdev_unregister() tears the endpoint down (delete_endpoint ->
# endpoint devres -> cxl_bi_dealloc) BEFORE nulling cxlmd->cxlds, and
# decoder attributes like bi_show rely on that ordering (they carry no
# NULL check). Exercise the ordering with the richest state: a
# committed HDM-DB region live at every unbind, while a reader loop
# hammers the decoder attributes through the whole teardown/rebuild
# cycle. A regression in any of the orderings (teardown-before-null,
# unregister-before-endpoint-clear, dealloc-before-unmap) surfaces as
# a NULL deref / fault in dmesg.
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
		[ -e "$d/cap_back_invalidate" ] || continue
		[ "$(cat "$d/cap_back_invalidate")" = 1 ] && { basename "$d"; return; }
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

CYCLES=${CYCLES:-8}
rd=$(root_decoder_bi)
mem=$(first_mem)
bdf=$(readlink -f "$CXL/$mem" | \
      grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]' | tail -1)
[ -n "$rd" ] && [ -n "$mem" ] && [ -n "$bdf" ] || \
	{ echo "Bail out! prereq missing"; exit 1; }

echo "# t2 phase 3: lifecycle reader race ($CYCLES cycles)"
dmesg -C

# Reader: hammer decoder attributes (back_invalidate, target_type) and
# the root's cap_back_invalidate through every teardown/rebuild. Globs
# transiently match nothing mid-teardown; errors are expected and
# swallowed.
readflag=/tmp/lcr-reader.$$
touch "$readflag"
( while [ -e "$readflag" ]; do
	cat $CXL/decoder*/back_invalidate $CXL/decoder*/target_type \
	    $CXL/decoder0.*/cap_back_invalidate >/dev/null 2>&1
  done ) &
reader=$!

cycfail=0
for i in $(seq 1 "$CYCLES"); do
	# fresh region on the current decoder incarnation
	for r in $(ls $CXL | grep '^region'); do
		echo 0 > "$CXL/$r/commit" 2>/dev/null
		echo "$r" > "$CXL/$rd/delete_region" 2>/dev/null
	done
	dec=$(ep_decoder_for_mem "$mem")
	[ -n "$dec" ] || { cycfail=$((cycfail+1)); continue; }
	sz=$((256 << 20))
	region=$(cat "$CXL/$rd/create_ram_region")
	echo "$region" > "$CXL/$rd/create_ram_region" 2>/dev/null
	R=$CXL/$region
	echo 256 > "$R/interleave_granularity" 2>/dev/null
	echo 1 > "$R/interleave_ways" 2>/dev/null
	echo $sz > "$R/size" 2>/dev/null
	echo 0 > "$CXL/$dec/dpa_size" 2>/dev/null
	echo ram > "$CXL/$dec/mode" 2>/dev/null
	echo $sz > "$CXL/$dec/dpa_size" 2>/dev/null
	echo "$dec" > "$R/target0" 2>/dev/null
	echo 1 > "$R/commit" 2>/dev/null || cycfail=$((cycfail+1))

	# memdev-driven teardown with the region committed, reader live
	echo "$bdf" > /sys/bus/pci/drivers/cxl_pci/unbind 2>/dev/null
	for j in $(seq 1 50); do
		[ -d "$CXL/$mem" ] || break
		sleep 0.1
	done
	echo "$bdf" > /sys/bus/pci/drivers/cxl_pci/bind 2>/dev/null
	for j in $(seq 1 100); do
		[ -n "$(ep_decoder_for_mem "$mem")" ] && break
		sleep 0.2
	done
	[ -n "$(ep_decoder_for_mem "$mem")" ] || cycfail=$((cycfail+1))
done
rm -f "$readflag"
wait "$reader" 2>/dev/null

expect_eq "committed-region unbind cycles clean" "$cycfail" 0

# function proof after the churn
for r in $(ls $CXL | grep '^region'); do
	echo 0 > "$CXL/$r/commit" 2>/dev/null
	echo "$r" > "$CXL/$rd/delete_region" 2>/dev/null
done
dec=$(ep_decoder_for_mem "$mem")
region=$(cat "$CXL/$rd/create_ram_region")
echo "$region" > "$CXL/$rd/create_ram_region" 2>/dev/null
R=$CXL/$region
echo 256 > "$R/interleave_granularity"; echo 1 > "$R/interleave_ways"
echo $((256 << 20)) > "$R/size"
echo 0 > "$CXL/$dec/dpa_size" 2>/dev/null
echo ram > "$CXL/$dec/mode" 2>/dev/null
echo $((256 << 20)) > "$CXL/$dec/dpa_size"
echo "$dec" > "$R/target0" && echo 1 > "$R/commit" && \
	ok "post-churn HDM-DB commit" || fail "post-churn HDM-DB commit"
expect_eq "post-churn endpoint bi=1" "$(cat "$CXL/$dec/back_invalidate" 2>/dev/null)" 1
echo 0 > "$R/commit" 2>/dev/null
echo "$region" > "$CXL/$rd/delete_region" 2>/dev/null

# lifecycle hygiene: any ordering regression shows up here
for pat in "BUG:" "Oops" "kernel NULL pointer" "WARNING:" \
	   "possible circular" "inconsistent lock"; do
	if dmesg | grep -q "$pat"; then
		fail "dmesg clean of '$pat'"
		dmesg | grep "$pat" | head -2 | sed 's/^/# /'
	else
		ok "dmesg clean of '$pat'"
	fi
done

exit $((FAIL != 0))
