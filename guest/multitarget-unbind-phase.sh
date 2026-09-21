#!/bin/bash
# t5 phase 3: unbind a member of a committed multi-target region.
#
# Phase 2 (nr_bi refcount) unbinds the region-LESS peer while a 1-way
# region sits on the other endpoint, so the teardown never walks a
# region the leaving endpoint belongs to. Here the leaving endpoint is
# a member of a committed 2-way HDM-DB region, which is the only shape
# that reaches the interesting branches:
#
#   cxld_unregister() -> cxl_decoder_detach(DETACH_INVALIDATE) ->
#   __cxl_decoder_detach() takes the p->state > CXL_CONFIG_ACTIVE arm,
#   so cxl_region_decode_reset() decommits EVERY target rather than
#   one, cxl_port_detach_region() walks a path the surviving peer
#   still holds, and each member decoder's target_type is reverted to
#   cxled_default_type().
#
# What must hold across the unbind:
#   - the region is decommitted, but only the LEAVER is detached: the
#     peer stays attached, keeps the inherited DEVMEM target_type, and
#     back_invalidate_show() still reads 1 because it keys off
#     attachment and cxlds->bi, not committed state
#   - the shared RP keeps BI Forward: dport->nr_bi goes 2->1, so the
#     register must NOT be cleared. This is the BI-specific claim -
#     everything above it would also hold with BI absent.
#   - the leaving endpoint's own DSP clears to 0
#   - the surviving peer's DSP keeps BI Enable
#   - no BI dport-disable failure, no splat
#
# Destroying the remnant region then detaches the peer, which is where
# its own cxled_default_type() revert is observable; the leaver's is
# not, its decoder went with the memdev. On rebind the DSP comes back
# and a fresh 2-way region re-inherits on both members.
#
# Output: TAP-ish, exit 0 iff all checks pass.
set -o pipefail
CXL=/sys/bus/cxl/devices
PASS=0; FAIL=0; N=0
ok()   { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - $1"; }
fail() { N=$((N+1)); FAIL=$((FAIL+1)); echo "not ok $N - $1"; }
# Always emit the TAP plan and summary, even on bail-out exits. An
# EXIT trap does not alter the script's exit status.
finish() { echo "1..$N"; echo "# passed: $PASS  failed: $FAIL"; }
trap finish EXIT
expect_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (got '$2' want '$3')"; fi
}

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
# t5's depth is pxb -> rp -> usp -> dsp -> type3 -> memN, so counting
# back from the memdev gives the RP and the endpoint's own DSP.
rp_bdf_for_mem()  { readlink -f "$CXL/$1" | awk -F/ '{print $(NF-4)}'; }
dsp_bdf_for_mem() { readlink -f "$CXL/$1" | awk -F/ '{print $(NF-2)}'; }

# BI Decoder Control (cap ID 0xC) at BAR0 + 0x1000, located through
# the capability array rather than a fixed offset. Bit 0 is BI Forward,
# bit 1 is BI Enable. Empty output means no /dev/mem MMIO (e.g.
# CONFIG_IO_STRICT_DEVMEM); callers SKIP on it.
bi_ctrl() {
	python3 - "$1" <<'PYEOF' 2>/dev/null
import ctypes, mmap, os, sys
base = int(open("/sys/bus/pci/devices/%s/resource" % sys.argv[1])
           .readline().split()[0], 16)
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 4096, offset=base + 0x1000)
u32 = lambda o: ctypes.c_uint32.from_buffer(m, o).value
off = None
for i in range((u32(0) >> 24) & 0xff):
    e = u32(4 + 4 * i)
    if (e & 0xffff) == 0xc:
        off = (e >> 20) & 0xfff
print("%#x" % u32(off + 4))
m.close(); os.close(fd)
PYEOF
}
# expect_ctrl <what> <bdf> <want>: compare BI Forward (bit 0) and BI
# Enable (bit 1) only. A downstream port also carries the commit bit,
# so the raw value is not the claim - the cascade checks in the main
# body mask the same way. SKIP rather than fail when the register is
# unreadable.
expect_ctrl() {
	local what=$1 v; v=$(bi_ctrl "$2")
	if [ -z "$v" ]; then
		ok "$what # SKIP no /dev/mem MMIO"
	else
		expect_eq "$what" "$((v & 0x3))" "$3"
	fi
}

# build_2way -> region name on stdout, empty on failure
build_2way() {
	local sz=$((256 << 20)) region R i=0 m d
	region=$(cat "$CXL/$rd/create_ram_region") || return 1
	echo "$region" > "$CXL/$rd/create_ram_region" 2>/dev/null || return 1
	R=$CXL/$region
	echo 256 > "$R/interleave_granularity" 2>/dev/null || return 1
	echo 2 > "$R/interleave_ways" 2>/dev/null || return 1
	echo $((sz * 2)) > "$R/size" 2>/dev/null || return 1
	for m in "${mems[@]}"; do
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

echo "# t5 phase 3: unbind a member of a committed 2-way region"

rd=$(root_decoder_bi)
[ -n "$rd" ] || { echo "Bail out! no BI root decoder"; exit 1; }
mems=( $(for m in $CXL/mem*; do basename "$m"; done | sort) )
[ "${#mems[@]}" = 2 ] || \
	{ echo "Bail out! need 2 memdevs, got ${#mems[@]}"; exit 1; }

# mems[0] leaves, mems[1] survives.
mem_go=${mems[0]}; mem_stay=${mems[1]}
bdf_go=$(bdf_for_mem "$mem_go")
# Capture the dport BDFs while both endpoints' sysfs paths still exist;
# mem_go's disappears with the unbind.
rpbdf=$(rp_bdf_for_mem "$mem_go")
dsp_go=$(dsp_bdf_for_mem "$mem_go")
dsp_stay=$(dsp_bdf_for_mem "$mem_stay")
[ -n "$bdf_go" ] && [ -n "$rpbdf" ] && [ -n "$dsp_go" ] && [ -n "$dsp_stay" ] || \
	{ echo "Bail out! could not resolve BDFs"; exit 1; }

dec_go=$(ep_decoder_for_mem "$mem_go")
dec_stay=$(ep_decoder_for_mem "$mem_stay")
[ -n "$dec_go" ] && [ -n "$dec_stay" ] || \
	{ echo "Bail out! could not resolve endpoint decoders"; exit 1; }

# The t5 main body leaves dpa_size populated on both endpoints.
for m in "${mems[@]}"; do
	d=$(ep_decoder_for_mem "$m")
	echo 0 > "$CXL/$d/dpa_size" 2>/dev/null
done

region=$(build_2way)
[ -n "$region" ] || { echo "Bail out! build_2way failed"; exit 1; }
R=$CXL/$region
echo 1 > "$R/commit" || { echo "Bail out! commit failed"; exit 1; }

expect_eq "pre-unbind: both endpoints bi=1" \
	"$(cat "$CXL/$dec_go/back_invalidate")$(cat "$CXL/$dec_stay/back_invalidate")" \
	"11"
expect_eq "pre-unbind: surviving peer target_type inherited" \
	"$(cat "$CXL/$dec_stay/target_type")" accelerator
# Both endpoints' adjacent DSPs take BI Enable; the shared RP above
# them is a transit dport and takes BI Forward with nr_bi == 2.
expect_ctrl "pre-unbind: leaving DSP BI Enable"   "$dsp_go"   2
expect_ctrl "pre-unbind: surviving DSP BI Enable" "$dsp_stay" 2
expect_ctrl "pre-unbind: shared RP BI Forward"    "$rpbdf"    1

# --- unbind a member of the committed region
dmesg -C
echo "$bdf_go" > /sys/bus/pci/drivers/cxl_pci/unbind 2>/dev/null || \
	echo "$mem_go" > /sys/bus/cxl/drivers/cxl_mem/unbind 2>/dev/null
for i in $(seq 1 60); do
	[ -e "$CXL/$mem_go" ] || break
	sleep 0.2
done
[ -e "$CXL/$mem_go" ] && { echo "Bail out! memdev did not go away"; exit 1; }
ok "leaving memdev gone"

# cxl_decoder_detach() releases the region driver, so the region may be
# reaped outright. Either way it must not still be committed.
if [ ! -e "$R" ]; then
	ok "region reaped with its member"
else
	expect_eq "region decommitted by the member's departure" \
		"$(cat "$R/commit" 2>/dev/null)" 0
fi

# cxl_region_decode_reset() unwinds the hardware for every target, but
# only the LEAVING decoder is detached: __cxl_decoder_detach() clears
# p->targets[] and reverts cxled_default_type() for @cxled alone. The
# peer stays attached to the now-uncommitted region, so it keeps the
# inherited DEVMEM type, and back_invalidate_show() - which reads
# attachment and cxlds->bi, not committed state - still reports 1.
expect_eq "surviving peer still attached to the region" \
	"$(cat "$CXL/$dec_stay/region" 2>/dev/null)" "$region"
expect_eq "surviving peer keeps inherited target_type" \
	"$(cat "$CXL/$dec_stay/target_type")" accelerator
expect_eq "surviving peer bi still 1 while attached" \
	"$(cat "$CXL/$dec_stay/back_invalidate")" 1

# The money assertions: the leaver's own level goes away, the shared
# level does not. A rollback that cleared instead of decrementing
# would kill BI routing under a still-bound peer.
expect_ctrl "post-unbind: leaving DSP cleared"        "$dsp_go"   0
expect_ctrl "post-unbind: surviving DSP still Enable" "$dsp_stay" 2
expect_ctrl "post-unbind: shared RP still Forward"    "$rpbdf"    1

if dmesg | grep -qE "BI dport disable failed|BI setup failed"; then
	fail "no BI errors on member unbind"
	dmesg | grep -E "BI dport|BI setup" | sed 's/^/# /'
else
	ok "no BI errors on member unbind"
fi
if dmesg | grep -qE "BUG:|WARNING:|KASAN|general protection|NULL pointer"; then
	fail "no splat on member unbind"
	dmesg | grep -E "BUG:|WARNING:|KASAN|general protection|NULL pointer" \
		| head -5 | sed 's/^/# /'
else
	ok "no splat on member unbind"
fi

# Destroying the remnant region detaches the peer, which is where its
# own cxled_default_type() revert happens. The leaver's revert is not
# observable - its decoder went with the memdev.
echo 0 > "$R/commit" 2>/dev/null
echo "$region" > "$CXL/$rd/delete_region" 2>/dev/null
expect_eq "peer target_type reverted on region destroy" \
	"$(cat "$CXL/$dec_stay/target_type")" expander
expect_eq "peer bi=0 after region destroy" \
	"$(cat "$CXL/$dec_stay/back_invalidate")" 0
# BI enablement follows the device bind, not the region: the peer is
# still bound, so its path stays up with the RP at nr_bi == 1.
expect_ctrl "post-destroy: shared RP still Forward" "$rpbdf" 1
expect_ctrl "post-destroy: peer DSP still Enable"   "$dsp_stay" 2

# --- rebind and prove nothing leaked
dmesg -C
echo "$bdf_go" > /sys/bus/pci/drivers/cxl_pci/bind 2>/dev/null || \
	echo "$mem_go" > /sys/bus/cxl/drivers/cxl_mem/bind 2>/dev/null
for i in $(seq 1 60); do
	[ -e "$CXL/$mem_go" ] && [ -n "$(ep_decoder_for_mem "$mem_go")" ] && break
	sleep 0.5
done
dec_go=$(ep_decoder_for_mem "$mem_go")
if [ -z "$dec_go" ]; then
	fail "leaving memdev returned after rebind"
	exit $((FAIL != 0))
fi
ok "leaving memdev returned after rebind"
expect_ctrl "post-rebind: DSP BI Enable restored" "$dsp_go" 2
expect_ctrl "post-rebind: shared RP still Forward" "$rpbdf" 1
if dmesg | grep -q "BI setup failed"; then
	fail "no 'BI setup failed' on rebind"
	dmesg | grep "BI setup" | sed 's/^/# /'
else
	ok "no 'BI setup failed' on rebind"
fi

# A fresh 2-way region must re-inherit on both members.
dec_stay=$(ep_decoder_for_mem "$mem_stay")
region2=$(build_2way)
if [ -z "$region2" ]; then
	fail "rebuild 2-way HDM-DB region after the cycle"
else
	ok "rebuild 2-way HDM-DB region after the cycle"
	R2=$CXL/$region2
	if echo 1 > "$R2/commit" 2>/dev/null; then
		ok "recommit 2-way HDM-DB region"
		expect_eq "both endpoints bi=1 after the cycle" \
			"$(cat "$CXL/$dec_go/back_invalidate")$(cat "$CXL/$dec_stay/back_invalidate")" \
			"11"
		expect_eq "target_type re-inherited after the cycle" \
			"$(cat "$CXL/$dec_stay/target_type")" accelerator
	else
		fail "recommit 2-way HDM-DB region"
	fi
	echo 0 > "$R2/commit" 2>/dev/null
	echo "$region2" > "$CXL/$rd/delete_region" 2>/dev/null
fi

# The first region was deleted above; tolerate it still being there if
# an assertion bailed before that point.
[ -e "$R" ] && {
	echo 0 > "$R/commit" 2>/dev/null
	echo "$region" > "$CXL/$rd/delete_region" 2>/dev/null
}

exit $((FAIL != 0))
