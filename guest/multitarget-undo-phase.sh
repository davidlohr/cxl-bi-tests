#!/bin/bash
# t5 phase 4: the commit-time BI re-check on a multi-target region.
#
# cxl_region_decode_commit() programs targets in position order, and
# after each one re-reads that device's BI Enable, since a reset may
# have wiped it without .reset_done having run yet. t34 arm 4 covers
# this with a single target, where the undo resets only the decoder
# that just failed. Here BI Enable is cleared behind the driver on the
# SECOND member of a 2-way HDM-DB region, between attach and commit,
# so the first member commits and passes its re-check before the
# second fails. The undo (cxl_region_decode_reset() over i + 1
# targets) must then reset both, including the shared switch decoder.
#
# What must hold after the refused commit:
#   - the refusal names the second member, and only it
#   - the region reads commit=0
#   - neither endpoint, nor the USP, is left with a committed HDM
#     decoder, by register readback
#   - the first member's cxlds->bi is untouched (bi=1 while attached);
#     the second member's fails closed (bi=0), as .reset_done would
#     leave it
# Recovery: the first member commits an HDM-DB region on its own, and
# a rebind of the second re-enables its BI so a fresh 2-way region
# commits on both.
#
# Output: TAP-ish, exit 0 iff all checks pass.
set -o pipefail
CXL=/sys/bus/cxl/devices
PASS=0; FAIL=0; N=0
ok()   { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - $1"; }
fail() { N=$((N+1)); FAIL=$((FAIL+1)); echo "not ok $N - $1"; }
skip() { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - # SKIP $1"; }
# Always emit the TAP plan and summary, even on bail-out exits. An
# EXIT trap does not alter the script's exit status.
finish() { echo "1..$N"; echo "# passed: $PASS  failed: $FAIL"; }
trap finish EXIT
expect_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (got '$2' want '$3')"; fi
}
# the suite-wide definition, as in run-tests.sh
SPLAT_RE='BUG:|Oops|WARNING:|UBSAN:|kernel BUG at|Unable to handle|general protection|Kernel panic|INFO: trying to register non-static key|kmemleak: Kernel memory leak detector disabled|kmemleak: Cannot allocate|INFO: task .* blocked.* for more than|INFO: .*detected stall|detected hard LOCKUP'

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
bdf_for_mem() {
	readlink -f "$CXL/$1" | \
		grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]' | tail -1
}
# t5's depth is pxb -> rp -> usp -> dsp -> type3 -> memN.
usp_bdf_for_mem() { readlink -f "$CXL/$1" | awk -F/ '{print $(NF-3)}'; }

# reg <bdf> <mode>: component registers at BAR0 + 0x1000 via /dev/mem,
# located through the capability array. Empty output means no
# /dev/mem MMIO; callers SKIP.
#   bictrl   - BI Decoder Control (cap ID 0xC); bit 1 is BI Enable
#   biclear  - clear BI Enable behind the driver (a reset whose
#              .reset_done has not run)
#   committed - number of committed HDM decoders (cap ID 5, bit 10)
reg() {
	python3 - "$1" "$2" <<'PYEOF' 2>/dev/null
import ctypes, mmap, os, sys
bdf, mode = sys.argv[1], sys.argv[2]
base = int(open('/sys/bus/pci/devices/%s/resource' % bdf)
           .readline().split()[0], 16)
fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 8192, offset=base + 0x1000)
u32 = lambda o: ctypes.c_uint32.from_buffer(m, o).value
caps = {}
for i in range((u32(0) >> 24) & 0xff):
    e = u32(4 + 4 * i)
    caps[e & 0xffff] = (e >> 20) & 0xfff
if mode == 'bictrl':
    print('%#x' % u32(caps[0xc] + 4))
elif mode == 'biclear':
    o = caps[0xc] + 4
    ctypes.c_uint32.from_buffer(m, o).value = u32(o) & ~2
    print('%#x' % u32(o))
else:
    h = caps[0x5]
    ndec = [1, 2, 4, 6, 8, 10, 12, 14][u32(h) & 0xf]
    print(sum((u32(h + 0x20 * i + 0x20) >> 10) & 1 for i in range(ndec)))
m.close(); os.close(fd)
PYEOF
}

# build_region <ways> <mems...> -> region name on stdout, empty on failure
build_region() {
	local ways=$1 sz=$((256 << 20)) region R i=0 m d; shift
	region=$(cat "$CXL/$rd/create_ram_region") || return 1
	echo "$region" > "$CXL/$rd/create_ram_region" 2>/dev/null || return 1
	R=$CXL/$region
	echo 256 > "$R/interleave_granularity" 2>/dev/null || return 1
	echo "$ways" > "$R/interleave_ways" 2>/dev/null || return 1
	echo $((sz * ways)) > "$R/size" 2>/dev/null || return 1
	for m in "$@"; do
		d=$(ep_decoder_for_mem "$m")
		[ -n "$d" ] || return 1
		# Release any leftover DPA before re-reserving; the kernel
		# rejects dpa_size with -EBUSY on a stale allocation.
		echo 0 > "$CXL/$d/dpa_size" 2>/dev/null
		echo ram > "$CXL/$d/mode" 2>/dev/null
		echo "$sz" > "$CXL/$d/dpa_size" 2>/dev/null || return 1
		echo "$d" > "$R/target$i" 2>/dev/null || return 1
		i=$((i+1))
	done
	echo "$region"
}
# enable_bit <bdf>: BI Enable (bit 1) of BI Decoder Control, empty if
# unreadable so expect_eq fails rather than the arithmetic aborting
enable_bit() { local v; v=$(reg "$1" bictrl); [ -n "$v" ] && echo $((v & 2)); }
destroy_region() {
	echo 0 > "$CXL/$1/commit" 2>/dev/null
	echo "$1" > "$CXL/$rd/delete_region" 2>/dev/null
}

echo "# t5 phase 4: commit-time BI re-check undoes every target"

rd=$(root_decoder_bi)
[ -n "$rd" ] || { echo "Bail out! no BI root decoder"; exit 1; }
mems=( $(for m in $CXL/mem*; do basename "$m"; done | sort) )
[ "${#mems[@]}" = 2 ] || \
	{ echo "Bail out! need 2 memdevs, got ${#mems[@]}"; exit 1; }
# Positions follow the target order: mems[0] is target0, mems[1] target1.
mem_first=${mems[0]}; mem_second=${mems[1]}
bdf_first=$(bdf_for_mem "$mem_first")
bdf_second=$(bdf_for_mem "$mem_second")
usp=$(usp_bdf_for_mem "$mem_first")
[ -n "$bdf_first" ] && [ -n "$bdf_second" ] && [ -n "$usp" ] || \
	{ echo "Bail out! could not resolve BDFs"; exit 1; }

# Earlier phases may have left a region behind on a bail-out.
for r in "$CXL/$rd"/region*; do
	[ -e "$r" ] && destroy_region "$(basename "$r")"
done

if [ -z "$(reg "$bdf_second" bictrl)" ]; then
	for i in $(seq 1 22); do skip "no /dev/mem MMIO for BI Decoder Control"; done
	exit 0
fi

region=$(build_region 2 "$mem_first" "$mem_second")
[ -n "$region" ] || { echo "Bail out! 2-way region build failed"; exit 1; }
dec_first=$(ep_decoder_for_mem "$mem_first")
dec_second=$(ep_decoder_for_mem "$mem_second")

expect_eq "both members bi=1 while attached" \
	"$(cat "$CXL/$dec_first/back_invalidate")$(cat "$CXL/$dec_second/back_invalidate")" 11
reg "$bdf_second" biclear >/dev/null
expect_eq "BI Enable cleared behind the driver on the second member" \
	"$(enable_bit "$bdf_second")" 0
expect_eq "second member still reads bi=1 (cxlds->bi stale)" \
	"$(cat "$CXL/$dec_second/back_invalidate")" 1

dmesg -C
if echo 1 > "$CXL/$region/commit" 2>/dev/null; then
	fail "commit refused when the second member lost BI Enable"
else
	ok "commit refused when the second member lost BI Enable"
fi
if grep -q "$mem_second:$dec_second BI disabled by reset during commit" <<<"$(dmesg)"; then
	ok "refusal names the second member"
else
	fail "refusal names the second member"
	dmesg | grep "BI disabled by reset during commit" | sed 's/^/# /'
fi
expect_eq "only the second member refused" \
	"$(dmesg | grep -c 'BI disabled by reset during commit')" 1
expect_eq "region left uncommitted" "$(cat "$CXL/$region/commit")" 0
# The first member committed and passed its re-check before the second
# failed, so only the undo can have reset it.
expect_eq "first member's endpoint decoder undone" "$(reg "$bdf_first" committed)" 0
expect_eq "second member's endpoint decoder undone" "$(reg "$bdf_second" committed)" 0
expect_eq "shared USP decoder undone" "$(reg "$usp" committed)" 0
expect_eq "first member keeps bi=1 (its BI untouched)" \
	"$(cat "$CXL/$dec_first/back_invalidate")" 1
# back_invalidate also reads 0 for a detached or re-typed decoder, so
# pin those first: only cxlds->bi may account for the 0
expect_eq "second member still attached to the region" \
	"$(cat "$CXL/$dec_second/region" 2>/dev/null)" "$region"
expect_eq "second member keeps the inherited target_type" \
	"$(cat "$CXL/$dec_second/target_type")" accelerator
expect_eq "second member fails closed (bi=0)" \
	"$(cat "$CXL/$dec_second/back_invalidate")" 0
if grep -qE "$SPLAT_RE" <<<"$(dmesg)"; then
	fail "no splat across the refused commit"
	dmesg | grep -E "$SPLAT_RE" | head -5 | sed 's/^/# /'
else
	ok "no splat across the refused commit"
fi
destroy_region "$region"

# With cxlds->bi cleared, a fresh HDM-DB attach of the second member is
# refused at attach, not accepted and refused again at commit.
dmesg -C
r=$(build_region 1 "$mem_second")
if [ -n "$r" ]; then
	fail "fresh HDM-DB attach of the second member refused"
	destroy_region "$r"
elif grep -q "BI not enabled on device" <<<"$(dmesg)"; then
	ok "fresh HDM-DB attach of the second member refused"
else
	fail "fresh HDM-DB attach of the second member refused (no 'BI not enabled on device')"
fi
# build_region leaves the region behind when the attach is refused
for r in "$CXL/$rd"/region*; do
	[ -e "$r/target0" ] && [ -z "$(cat "$r/target0" 2>/dev/null)" ] && \
		destroy_region "$(basename "$r")"
done

# --- recovery: the first member was never affected
r1=$(build_region 1 "$mem_first")
if [ -n "$r1" ] && echo 1 > "$CXL/$r1/commit" 2>/dev/null; then
	ok "first member commits an HDM-DB region on its own"
	expect_eq "first member bi=1 in its own region" \
		"$(cat "$CXL/$(ep_decoder_for_mem "$mem_first")/back_invalidate")" 1
else
	fail "first member commits an HDM-DB region on its own"
	fail "first member bi=1 in its own region"
fi
[ -n "$r1" ] && destroy_region "$r1"

# The second member recovers by rebind. Let the endpoint teardown's
# deferred detach_memdev() drain first, or it releases the new binding.
dmesg -C
echo "$mem_second" > /sys/bus/cxl/drivers/cxl_mem/unbind 2>/dev/null
sleep 0.5
echo "$mem_second" > /sys/bus/cxl/drivers/cxl_mem/bind 2>/dev/null
for i in $(seq 1 60); do
	[ -n "$(ep_decoder_for_mem "$mem_second")" ] && break
	sleep 0.5
done
if [ -z "$(ep_decoder_for_mem "$mem_second")" ]; then
	fail "second member back after rebind"
	exit $((FAIL != 0))
fi
ok "second member back after rebind"
expect_eq "second member BI Enable restored" \
	"$(enable_bit "$bdf_second")" 2

region2=$(build_region 2 "$mem_first" "$mem_second")
if [ -n "$region2" ] && echo 1 > "$CXL/$region2/commit" 2>/dev/null; then
	ok "2-way HDM-DB region commits after recovery"
	expect_eq "both members bi=1 after recovery" \
		"$(cat "$CXL/$(ep_decoder_for_mem "$mem_first")/back_invalidate")$(cat "$CXL/$(ep_decoder_for_mem "$mem_second")/back_invalidate")" 11
else
	fail "2-way HDM-DB region commits after recovery"
	fail "both members bi=1 after recovery"
fi
[ -n "$region2" ] && destroy_region "$region2"

exit $((FAIL != 0))
