#!/bin/bash
# In-guest CXL BI test driver. TAP-ish output on stdout.
# Usage: run-tests.sh <suite>   (see topos/ for the suite list)
#
# BI invariants exercised across the suites:
#  - Register probing: BI Decoder / BI Route Table caps map inside the
#    dport devres group so a hot-remove/hot-add cycle is clean.
#  - Topology walk: cxl_bi_setup enables BI on every dport in the path
#    device -> DSP -> USP -> RP (Enable on the device-adjacent dport,
#    Forward on every dport above it, at any switch depth); failure
#    rolls back only the dports that fully enabled, skipping the
#    failed one.
#  - HDM decoder init: cxl_hdm_decoder->supported_coherency drives the
#    endpoint decoder's default target_type; a decoder already
#    committed with the HDM BI bit set is rejected (-ENXIO).
#  - Root decoder ABI: cap_back_invalidate tracks the CFMWS BI restriction; a
#    region created under a BI root inherits DEVMEM (HDM-DB), otherwise
#    HOSTONLYMEM (HDM-H).
#  - Endpoint decoder ABI: back_invalidate reads 1 iff the decoder is
#    committed in an HDM-DB region with the device in BI.

SUITE=${1:-t2}
CXL=/sys/bus/cxl/devices
PASS=0; FAIL=0; N=0

ok()   { N=$((N+1)); PASS=$((PASS+1)); echo "ok $N - $1"; }
fail() { N=$((N+1)); FAIL=$((FAIL+1)); echo "not ok $N - $1"; }
check() { # check <desc> <cmd...>
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}
expect_eq() { # expect_eq <desc> <actual> <expected>
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (got '$2' want '$3')"; fi
}
# Always emit the TAP plan and summary, even on bail-out exits. An
# EXIT trap does not alter the script's exit status.
finish() { echo "1..$N"; echo "# passed: $PASS  failed: $FAIL"; }
trap finish EXIT

# ---------- enumeration helpers ------------------------------------
root_decoder_bi() { # first root decoder whose cap_back_invalidate = 1
	local d
	for d in $CXL/decoder0.*; do
		[ -e "$d/cap_back_invalidate" ] || continue
		[ "$(cat "$d/cap_back_invalidate")" = 1 ] && { basename "$d"; return; }
	done
}
root_decoder_nobi() { # first root decoder whose cap_back_invalidate = 0
	local d
	for d in $CXL/decoder0.*; do
		[ -e "$d/cap_back_invalidate" ] || continue
		[ "$(cat "$d/cap_back_invalidate")" = 0 ] && { basename "$d"; return; }
	done
}
root_decoder_any() { # any root decoder that can create ram regions
	local d
	for d in $CXL/decoder0.*; do
		[ -e "$d/create_ram_region" ] && { basename "$d"; return; }
	done
}
ep_decoder_for_mem() { # memN -> first endpoint decoder decoderX.0
	local mem=$1 ep
	for ep in $CXL/endpoint*; do
		[ -d "$ep" ] || continue
		if [ "$(basename "$(readlink -f "$ep/uport")")" = "$mem" ]; then
			basename "$(ls -d "$ep"/decoder*.0 2>/dev/null | head -1)"
			return
		fi
	done
}
bdf_for_mem() { # memN -> 0000:bb:dd.f
	readlink -f "$CXL/$1" | \
		grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]' | tail -1
}
mem_for_bdf() { # 0000:bb:dd.f -> memN
	local m
	for m in $CXL/mem*; do
		[ "$(bdf_for_mem "$(basename "$m")")" = "$1" ] &&
			{ basename "$m"; return; }
	done
}
all_mems() { # list of memN sorted by BDF for reproducibility
	local m
	for m in $CXL/mem*; do basename "$m"; done | sort
}
# A committed HDM-DB region propagates its type into every attached
# endpoint decoder's target_type via cxl_rr_assign_decoder(). The
# region itself has no target_type sysfs file - use the endpoint
# decoder's target_type_show: "accelerator" for DEVMEM, "expander" for
# HOSTONLYMEM.
endpoint_decoder_target_type() { # <endpoint decoder name> -> string
	cat "$CXL/$1/target_type" 2>/dev/null
}

# ---------- region provisioning -----------------------------------
# create_region <root_decoder> <ways> <mem_size_MB> <memdevs...>
# Prints the region name on stdout or empty string on failure.
create_region() {
	local rd=$1 ways=$2 sz_mb=$3; shift 3
	local sz=$((sz_mb << 20))
	local region
	region=$(cat "$CXL/$rd/create_ram_region") || return 1
	echo "$region" > "$CXL/$rd/create_ram_region" 2>/dev/null || return 1
	local R=$CXL/$region
	# Window-level interleave suites must match the CFMWS granularity.
	echo "${CR_IG:-256}" > "$R/interleave_granularity" 2>/dev/null || \
		{ echo ""; return 1; }
	echo "$ways" > "$R/interleave_ways" 2>/dev/null || { echo ""; return 1; }
	echo $((sz * ways)) > "$R/size" 2>/dev/null || { echo ""; return 1; }
	local i=0 mem dec
	for mem in "$@"; do
		dec=$(ep_decoder_for_mem "$mem")
		[ -n "$dec" ] || { echo ""; return 1; }
		# Release any leftover DPA (previous region on this decoder)
		# before re-reserving; the kernel rejects dpa_size writes with
		# -EBUSY when the endpoint has a stale allocation.
		echo 0 > "$CXL/$dec/dpa_size" 2>/dev/null
		echo ram > "$CXL/$dec/mode" 2>/dev/null
		echo "$sz" > "$CXL/$dec/dpa_size" 2>/dev/null || { echo ""; return 1; }
		# Expected to fail with -ENXIO in the negative-attach suites
		# (t12 mixed pair, t14 cross-assignment): the reject IS the
		# behavior under test, keep it off stderr.
		echo "$dec" > "$R/target$i" 2>/dev/null || { echo ""; return 1; }
		i=$((i+1))
	done
	echo "$region"
}
commit_region()  { echo 1 > "$CXL/$1/commit"; }
reset_region()   { echo 0 > "$CXL/$1/commit" 2>/dev/null; }
# destroy_region <region> [root_decoder]
# delete_region only acts on children of the given root decoder, so
# suites with multiple creatable roots must name the right one.
destroy_region() {
	local rd=${2:-$(root_decoder_any)}
	reset_region "$1"
	echo "$1" > "$CXL/$rd/delete_region" 2>/dev/null
}

# ---------- generic invariants -----------------------------------
# Every root decoder must expose cap_back_invalidate whether it is set or not.
# Verify presence + a valid 0/1 value.
check_cap_back_invalidate_present() {
	local d v n=0
	for d in $CXL/decoder0.*; do
		[ -e "$d/cap_back_invalidate" ] || { fail "$d/cap_back_invalidate missing"; return; }
		v=$(cat "$d/cap_back_invalidate")
		case $v in 0|1) n=$((n+1)) ;; *)
			fail "$d/cap_back_invalidate has bogus value '$v'"; return ;;
		esac
	done
	ok "cap_back_invalidate present on all root decoders ($n found)"
}

# The `back_invalidate` file is present on every endpoint decoder and
# reads 0 or 1.
check_endpoint_bi_present() {
	local ep d v n=0
	for ep in $CXL/endpoint*; do
		[ -d "$ep" ] || continue
		# Skip decoders_committed (a leaf file, not a decoder dir).
		for d in "$ep"/decoder*.*; do
			[ -d "$d" ] || continue
			[ -e "$d/back_invalidate" ] || { fail "$d/back_invalidate missing"; return; }
			v=$(cat "$d/back_invalidate")
			case $v in 0|1) n=$((n+1)) ;; *)
				fail "$d/back_invalidate has bogus value '$v'"; return ;;
			esac
		done
	done
	# No decoders at all means enumeration failed (e.g. the endpoint
	# was lost to an init_hdm_decoder() reject), not a pass.
	if [ "$n" -gt 0 ]; then
		ok "back_invalidate present on all endpoint decoders ($n found)"
	else
		fail "no endpoint decoders enumerated"
	fi
}

# Switch decoders must NOT expose cap_back_invalidate or back_invalidate -
# those files live only on root decoders and endpoint decoders respectively.
check_no_switch_bi_files() {
	local d bad=0
	for d in $CXL/decoder*; do
		[ -d "$d" ] || continue
		local nm; nm=$(basename "$d")
		# skip root (decoder0.*) and endpoint decoders
		case $nm in decoder0.*) continue ;; esac
		local par; par=$(readlink -f "$d/..")
		basename "$par" | grep -q '^endpoint' && continue
		if [ -e "$d/cap_back_invalidate" ] || [ -e "$d/back_invalidate" ]; then
			bad=$((bad+1))
		fi
	done
	expect_eq "no cap_back_invalidate/back_invalidate on switch decoders" "$bad" 0
}

# Read-only ABI: writes to back_invalidate/cap_back_invalidate must be
# rejected. Any bash error on the write goes to /dev/null; we care only
# about the exit code.
check_bi_ro() {
	local ep=$1 rd; rd=$(root_decoder_bi)
	if [ -z "$rd" ]; then ok "cap_back_invalidate RO (no BI root decoder)"; else
		if ( echo 0 > "$CXL/$rd/cap_back_invalidate" ) 2>/dev/null; then
			fail "cap_back_invalidate writable (should be RO)"
		else
			ok "cap_back_invalidate read-only"
		fi
	fi
	if [ -n "$ep" ]; then
		if ( echo 0 > "$CXL/$ep/back_invalidate" ) 2>/dev/null; then
			fail "endpoint back_invalidate writable (should be RO)"
		else
			ok "endpoint back_invalidate read-only"
		fi
	fi
}

# ---------- dmesg pattern helpers --------------------------------
dmesg_saw() { dmesg | grep -q -- "$1"; }
no_setup_failure() {
	if dmesg | grep -q "BI setup failed"; then
		fail "no 'BI setup failed' in dmesg"
	else
		ok "no 'BI setup failed' in dmesg"
	fi
}
saw_setup_failure() {
	if dmesg | grep -q "BI setup failed\|BI not supported by topology\|BI not supported by USP"; then
		ok "dmesg reflects BI-disabled topology"
	else
		fail "dmesg reflects BI-disabled topology"
	fi
}
# cxl_rr_free_decoder's WARN_ONCE("region mismatch") must not fire
# across BI attach/detach cycling: the decoder-to-region association
# made by cxl_rr_assign_decoder must unwind symmetrically.
no_region_mismatch_warn() {
	if dmesg | grep -q "region mismatch"; then
		fail "no 'region mismatch' WARN across BI attach"
	else
		ok "no 'region mismatch' WARN across BI attach"
	fi
}

# creg <bdf> <mode>: component-block register truth via /dev/mem.
#   bictrl - BI Decoder Control (cap ID 0xC)
#   hdmbi  - 1 iff every committed HDM decoder (cap ID 5) has BI=1,
#            0 if a committed decoder lacks it, empty if none
# Empty output = no /dev/mem MMIO; callers SKIP.
creg() {
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
else:
    h = caps[0x5]
    ndec = [1, 2, 4, 6, 8, 10, 12, 14][u32(h) & 0xf]
    bi = [(u32(h + 0x20 * i + 0x20) >> 13) & 1
          for i in range(ndec)
          if (u32(h + 0x20 * i + 0x20) >> 10) & 1]
    print('' if not bi else min(bi))
m.close(); os.close(fd)
PYEOF
}

# check_create_visibility <root_decoder>
# Returns 0 if the given root decoder exposes create_ram_region or
# create_pmem_region files matching its cap_ram / cap_pmem flags. The
# kernel's can_create_ram/can_create_pmem accept either HDM-H
# (F_HOSTONLY|F_RAM) or HDM-DB (F_DEVMEM|F_BI|F_RAM); we verify the
# visibility algebra matches the flags.
check_create_visibility() { # <root_decoder>
	local rd=$1 have_cap_back_invalidate have_cap_ram have_cap_pmem
	have_cap_back_invalidate=$(cat "$CXL/$rd/cap_back_invalidate" 2>/dev/null || echo 0)
	have_cap_ram=$(cat "$CXL/$rd/cap_ram" 2>/dev/null || echo 0)
	have_cap_pmem=$(cat "$CXL/$rd/cap_pmem" 2>/dev/null || echo 0)
	# On an HDM-DB CFMWS: cap_back_invalidate=1, exactly one of ram/pmem is 1, and
	# the corresponding create_*_region attr must be present.
	# On an HDM-H CFMWS: cap_back_invalidate=0, same rule for ram/pmem visibility.
	if [ "$have_cap_ram" = 1 ]; then
		if [ -e "$CXL/$rd/create_ram_region" ]; then
			ok "$rd: create_ram_region present (cap_ram=1, cap_back_invalidate=$have_cap_back_invalidate)"
		else
			fail "$rd: create_ram_region missing despite cap_ram=1"
		fi
	fi
	if [ "$have_cap_pmem" = 1 ]; then
		if [ -e "$CXL/$rd/create_pmem_region" ]; then
			ok "$rd: create_pmem_region present (cap_pmem=1, cap_back_invalidate=$have_cap_back_invalidate)"
		else
			fail "$rd: create_pmem_region missing despite cap_pmem=1"
		fi
	fi
}

# decoders_committed on the endpoint port bumps up by 1 per committed
# decoder. Used to backstop the "commit succeeded" check.
port_committed_count() { # <cxl_port_name>
	cat "$CXL/$1/decoders_committed" 2>/dev/null || echo 0
}
# Returns 0 (true) if cxl_bi_setup on this boot succeeded end-to-end.
# The invariant proxy is a "BI requests enabled" dmesg line from
# __cxl_bi_ctrl_endpoint; its presence means cxlds->bi is 1. Used by
# fail-closed suites (t7/t8) to skip cleanly when upstream QEMU's
# `x-256b-flit=off` on ports doesn't reach LnkCtl2's Flit Mode Enable
# bit and the kernel's cxl_pci_flit_256() therefore still returns true.
bi_setup_succeeded() { dmesg | grep -q "BI requests enabled"; }
skip_qemu_gap() { # <count> <msg>
	local n=$1; shift
	for i in $(seq 1 "$n"); do
		N=$((N+1)); PASS=$((PASS+1))
		echo "ok $N - # SKIP $*"
	done
}
endpoint_of_mem() { # memN -> endpointX
	local mem=$1 ep
	for ep in $CXL/endpoint*; do
		[ -d "$ep" ] || continue
		[ "$(basename "$(readlink -f "$ep/uport")")" = "$mem" ] && \
			{ basename "$ep"; return; }
	done
}

# =====================================================================
echo "# CXL BI guest tests, suite $SUITE, kernel $(uname -r)"

case $SUITE in
# ---------------------------------------------------------------- t1
t1)	# minimal happy path: one endpoint directly under an RP.
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	check_no_switch_bi_files

	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	ok "found BI root decoder $rd"

	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")
	[ -n "$dec" ] || { fail "no endpoint decoder for $mem"; exit 1; }
	expect_eq "endpoint bi=0 pre-region" "$(cat "$CXL/$dec/back_invalidate")" 0
	check_bi_ro "$dec"

	# create + attach + commit HDM-DB region
	region=$(create_region "$rd" 1 256 "$mem")
	[ -n "$region" ] || { fail "create HDM-DB region"; exit 1; }
	ok "create HDM-DB region"
	check "commit HDM-DB region" commit_region "$region"
	expect_eq "endpoint decoder target_type=accelerator (DEVMEM)" \
		"$(endpoint_decoder_target_type "$dec")" accelerator
	expect_eq "endpoint bi=1 post-commit" "$(cat "$CXL/$dec/back_invalidate")" 1
	no_setup_failure
	destroy_region "$region"
	expect_eq "endpoint bi=0 post-destroy" "$(cat "$CXL/$dec/back_invalidate")" 0
	;;

# ---------------------------------------------------------------- t2
t2)	# switched happy path: DSP + USP + RP + endpoint.
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	check_no_switch_bi_files
	# Expect at least one non-root cxl_port between memdev and root:
	# proves the switch layer showed up in the topology.
	nports=$(ls -d $CXL/port* 2>/dev/null | wc -l)
	[ "$nports" -ge 1 ] && ok "switch cxl_port present ($nports)" \
		|| fail "no switch cxl_port"

	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	check_create_visibility "$rd"
	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")
	ep=$(endpoint_of_mem "$mem")
	pre_committed=$(port_committed_count "$ep")

	region=$(create_region "$rd" 1 256 "$mem")
	[ -n "$region" ] && ok "create HDM-DB region" \
		|| { fail "create HDM-DB region"; exit 1; }
	check "commit HDM-DB region under switch" commit_region "$region"
	expect_eq "endpoint bi=1 (switched)" "$(cat "$CXL/$dec/back_invalidate")" 1
	expect_eq "endpoint decoders_committed bumped" \
		"$(port_committed_count "$ep")" "$((pre_committed + 1))"
	no_setup_failure
	no_region_mismatch_warn

	# Detach: reset commit, tear down region. Endpoint bi returns to 0.
	destroy_region "$region"
	expect_eq "endpoint bi=0 after destroy" "$(cat "$CXL/$dec/back_invalidate")" 0
	expect_eq "endpoint decoders_committed back to pre" \
		"$(port_committed_count "$ep")" "$pre_committed"

	# Re-create/commit cycle: cxl_bi_setup/dealloc must not have
	# toggled BI on the topology, and a fresh region reaches bi=1.
	region=$(create_region "$rd" 1 256 "$mem")
	[ -n "$region" ] && commit_region "$region" && \
		ok "re-create + commit HDM-DB after full teardown" || \
		fail "re-create + commit HDM-DB after full teardown"
	expect_eq "endpoint bi=1 (recreated region)" \
		"$(cat "$CXL/$dec/back_invalidate")" 1
	destroy_region "$region"
	no_region_mismatch_warn

	# Discovery behind a switch: the boot dmesg must show the BI
	# capability walk (endpoint, RP and DSP decoders + the USP RT)
	# and the BI-ID commits that backed the region commits above.
	ndec=$(dmesg | grep -c "found BI Decoder capability")
	[ "$ndec" -ge 3 ] && ok "BI Decoder caps discovered (ep+rp+dsp)" \
		|| fail "BI Decoder caps discovered (got $ndec, want >= 3)"
	check "dmesg: 'found BI RT capability' (USP)" \
		dmesg_saw "found BI RT capability"
	check "dmesg: 'BI-ID commit wait took'" \
		dmesg_saw "BI-ID commit wait took"
	# The RP role by position (Forward above a switch, Table 8-157 /
	# 9.14.2 allocate step 6) is asserted by register readback in
	# phase 2 and in t24; the qemu BI oracle guards every write.

	# Phase 2 (unbind/rebind) is driven from run-all.sh with the
	# guest/unbindrebind-phase.sh helper.
	;;

# ---------------------------------------------------------------- t3
t3)	# BI-capable device, HDM-H (no BI) CFMWS. Region must be HOSTONLYMEM.
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	rd=$(root_decoder_bi)
	if [ -n "$rd" ]; then
		fail "unexpected BI root decoder $rd (CFMWS has no BI)"
	else
		ok "no BI root decoder present (as expected)"
	fi
	rd=$(root_decoder_nobi)
	[ -n "$rd" ] || { fail "no HDM-H root decoder"; exit 1; }

	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")
	region=$(create_region "$rd" 1 256 "$mem")
	[ -n "$region" ] && ok "create HDM-H region on HDM-H CFMWS" \
		|| { fail "create HDM-H region"; exit 1; }
	check "commit HDM-H region" commit_region "$region"
	expect_eq "endpoint decoder target_type=expander (HOSTONLYMEM)" \
		"$(endpoint_decoder_target_type "$dec")" expander
	expect_eq "endpoint bi=0 (HDM-H)" "$(cat "$CXL/$dec/back_invalidate")" 0
	# The BI walk itself must have found the topology capable but
	# there was nothing on the CFMWS side to commit BI decoders for.
	no_setup_failure
	destroy_region "$region"
	;;

# ---------------------------------------------------------------- t4
t4)	# non-BI device, BI-restricted CFMWS. Attach must be rejected.
	check_cap_back_invalidate_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")

	# cxlds->bi must be false: the device doesn't advertise hdm-db.
	# The cleanest reachable proof from userspace is that attach to a
	# DEVMEM region fails and dmesg logs the rejection.
	region=$(create_region "$rd" 1 256 "$mem")
	if [ -n "$region" ]; then
		# create_region already wired one target; commit should fail
		# only if attach failed. Some kernels reject at attach time
		# in create_region itself (echo dec > target$i returns EIO).
		if commit_region "$region" 2>/dev/null; then
			# Verify the endpoint did not end up in HDM-DB mode.
			expect_eq "endpoint bi=0 on non-BI device" \
				"$(cat "$CXL/$dec/back_invalidate")" 0
			fail "attach unexpectedly permitted for non-BI device"
		else
			ok "non-BI device rejected at region commit"
		fi
		destroy_region "$region"
	else
		ok "non-BI device rejected at attach (target write)"
	fi
	check "dmesg: 'BI not enabled on device'" \
		dmesg_saw "BI not enabled on device"
	;;

# ---------------------------------------------------------------- t5
t5)	# 2-way interleave across two BI-capable endpoints under one switch.
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	mems=( $(all_mems) )
	expect_eq "two memdevs enumerated" "${#mems[@]}" 2

	dec0=$(ep_decoder_for_mem "${mems[0]}")
	dec1=$(ep_decoder_for_mem "${mems[1]}")
	expect_eq "both endpoints bi=0 pre-region" \
		"$(cat "$CXL/$dec0/back_invalidate")$(cat "$CXL/$dec1/back_invalidate")" "00"

	region=$(create_region "$rd" 2 256 "${mems[0]}" "${mems[1]}")
	[ -n "$region" ] && ok "create 2-way HDM-DB region" \
		|| { fail "create 2-way HDM-DB region"; exit 1; }
	check "commit 2-way HDM-DB region" commit_region "$region"
	expect_eq "both endpoints bi=1 post-commit" \
		"$(cat "$CXL/$dec0/back_invalidate")$(cat "$CXL/$dec1/back_invalidate")" "11"
	no_setup_failure

	# Destroy resets both endpoints.
	destroy_region "$region"
	expect_eq "both endpoints bi=0 post-destroy" \
		"$(cat "$CXL/$dec0/back_invalidate")$(cat "$CXL/$dec1/back_invalidate")" "00"
	# Phase 2 (nr_bi refcount via hot-remove) driven from run-all.sh.
	;;

# ---------------------------------------------------------------- t6
t6)	# USP RT optional per 8.2.4.26. With upstream QEMU this suite is
	# effectively identical to t2; it exists to make the "USP without
	# RT is allowed" invariant load-bearing so a regression on the
	# @bi==NULL-allowed-for-USP branch of cxl_is_bi_capable() shows up.
	check_cap_back_invalidate_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")
	region=$(create_region "$rd" 1 256 "$mem")
	[ -n "$region" ] && ok "create HDM-DB region (USP RT variant)" \
		|| { fail "create HDM-DB region"; exit 1; }
	check "commit HDM-DB region" commit_region "$region"
	expect_eq "endpoint bi=1 (USP RT variant)" \
		"$(cat "$CXL/$dec/back_invalidate")" 1
	no_setup_failure
	destroy_region "$region"
	;;

# ---------------------------------------------------------------- t7
t7)	# RP uplink not in 256B Flit mode. Expected: cxl_is_bi_capable
	# returns false at the RP hop; BI setup returns 0 silently and
	# cxlds->bi=0; a DEVMEM region attach later rejects with
	# "BI not enabled on device".
	#
	# QEMU limitation: `x-256b-flit=off` on cxl-rp/downstream is a
	# device option but doesn't propagate to LnkCtl2.FlitModeEnable,
	# so cxl_pci_flit_256() still returns true and BI setup succeeds.
	# Detect that here and emit TAP SKIPs instead of failures.
	check_cap_back_invalidate_present
	if bi_setup_succeeded; then
		skip_qemu_gap 3 \
		    "QEMU x-256b-flit=off on RP does not reach LnkCtl2"
	else
		rd=$(root_decoder_bi)
		[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
		mem=$(all_mems | head -1)
		dec=$(ep_decoder_for_mem "$mem")
		region=$(create_region "$rd" 1 256 "$mem")
		if [ -n "$region" ] && commit_region "$region" 2>/dev/null; then
			fail "non-flit endpoint commit unexpectedly succeeded"
			destroy_region "$region"
		else
			ok "non-flit uplink rejected (attach or commit)"
			[ -n "$region" ] && destroy_region "$region"
		fi
		expect_eq "endpoint bi stays 0 on non-flit" \
			"$(cat "$CXL/$dec/back_invalidate")" 0
		if dmesg_saw "BI not supported by topology" || \
		   dmesg_saw "BI not enabled on device"; then
			ok "dmesg reflects non-flit rejection"
		else
			fail "dmesg reflects non-flit rejection"
		fi
	fi
	;;

# ---------------------------------------------------------------- t8
t8)	# DSP not in 256B Flit mode. BI walk's DSP check fails, cxlds->bi=0.
	# Same QEMU limitation as t7: `x-256b-flit=off` on cxl-downstream
	# does not affect the flit-mode-enable register the kernel reads.
	check_cap_back_invalidate_present
	if bi_setup_succeeded; then
		skip_qemu_gap 2 \
		    "QEMU x-256b-flit=off on DSP does not reach LnkCtl2"
	else
		rd=$(root_decoder_bi)
		[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
		mem=$(all_mems | head -1)
		dec=$(ep_decoder_for_mem "$mem")
		region=$(create_region "$rd" 1 256 "$mem")
		if [ -n "$region" ] && commit_region "$region" 2>/dev/null; then
			fail "mixed-config (68b DSP) commit unexpectedly succeeded"
			destroy_region "$region"
		else
			ok "mixed-config (68b DSP) rejected"
			[ -n "$region" ] && destroy_region "$region"
		fi
		if dmesg_saw "BI not supported by topology" || \
		   dmesg_saw "BI not enabled on device" || \
		   dmesg_saw "BI setup failed"; then
			ok "dmesg reflects mixed-config rejection"
		else
			fail "dmesg reflects mixed-config rejection"
		fi
	fi
	;;

# ---------------------------------------------------------------- t9
t9)	# cascaded switches: BI comes up across both switch levels.
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	# Expect at least two non-root cxl_port entries (outer + inner switch).
	nports=$(ls -d $CXL/port* 2>/dev/null | wc -l)
	if [ "$nports" -ge 2 ]; then
		ok "two switch cxl_port entries present ($nports)"
	else
		fail "cascaded switches ($nports cxl_port(s), want >=2)"
	fi

	rd=$(root_decoder_bi)
	rd_h=$(root_decoder_nobi)
	[ -n "$rd" ]   || { fail "no BI root decoder"; exit 1; }
	[ -n "$rd_h" ] || { fail "no HDM-H root decoder"; exit 1; }
	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")

	# The BI window must accept the endpoint two switch hops down.
	region=$(create_region "$rd" 1 256 "$mem")
	[ -n "$region" ] && ok "create HDM-DB region (cascaded path)" \
		|| { fail "create HDM-DB region (cascaded path)"; exit 1; }
	check "commit HDM-DB region across cascade" commit_region "$region"
	expect_eq "endpoint bi=1 (cascade)" \
		"$(cat "$CXL/$dec/back_invalidate")" 1

	# Register truth while the HDM-DB region is committed: BI roles
	# by position (Table 8-157), and the BI bit in the committed HDM
	# decoder at each switch USP - the decoder an Enabled DSP must
	# verify before accepting a BISnp (Table 9-13).
	path=$(readlink -f "$CXL/$mem")
	adj=$(awk -F/ '{print $(NF-2)}' <<<"$path")
	usp_in=$(awk -F/ '{print $(NF-3)}' <<<"$path")
	transit=$(awk -F/ '{print $(NF-4)}' <<<"$path")
	usp_out=$(awk -F/ '{print $(NF-5)}' <<<"$path")
	rp=$(awk -F/ '{print $(NF-6)}' <<<"$path")
	actl=$(creg "$adj" bictrl)
	if [ -z "$actl" ]; then
		for i in 1 2 3 4 5; do
			ok "cascade register truth # SKIP no /dev/mem MMIO"
		done
	else
		expect_eq "adjacent DSP Enable (committed region)" \
			"$((actl & 0x3))" 2
		expect_eq "transit DSP Forward (committed region)" \
			"$(($(creg "$transit" bictrl) & 0x3))" 1
		expect_eq "RP Forward (committed region)" \
			"$(($(creg "$rp" bictrl) & 0x3))" 1
		expect_eq "inner USP committed HDM decoder BI" \
			"$(creg "$usp_in" hdmbi)" 1
		expect_eq "outer USP committed HDM decoder BI" \
			"$(creg "$usp_out" hdmbi)" 1
	fi
	destroy_region "$region" "$rd"
	expect_eq "endpoint bi=0 after destroy" \
		"$(cat "$CXL/$dec/back_invalidate")" 0

	# The walk must reach every level: BI decoders on the endpoint,
	# the RP and both DSPs, a route table on each switch USP, and a
	# commit at each DSP and each RT - the RP and the device take
	# none (Table 8-156).
	ndec=$(dmesg | grep -c "found BI Decoder capability")
	[ "$ndec" -ge 4 ] && ok "BI Decoder caps discovered (ep+rp+2 dsp)" \
		|| fail "BI Decoder caps discovered (got $ndec, want >= 4)"
	nrt=$(dmesg | grep -c "found BI RT capability")
	[ "$nrt" -ge 2 ] && ok "BI RT caps discovered (both USPs)" \
		|| fail "BI RT caps discovered (got $nrt, want >= 2)"
	ncmt=$(dmesg | grep -c "BI-ID commit wait took")
	[ "$ncmt" -ge 4 ] && ok "BI-ID commits at both switch levels" \
		|| fail "BI-ID commits at both levels (got $ncmt, want >= 4)"
	check "dmesg: endpoint BI requests enabled" \
		dmesg_saw "BI requests enabled"

	# HDM-H still assembles and commits across both switches.
	region=$(create_region "$rd_h" 1 256 "$mem")
	[ -n "$region" ] && ok "create HDM-H region (cascaded)" \
		|| { fail "create HDM-H region"; exit 1; }
	check "commit HDM-H region across cascade" commit_region "$region"
	expect_eq "endpoint bi=0 post-commit" \
		"$(cat "$CXL/$dec/back_invalidate")" 0
	no_setup_failure
	destroy_region "$region" "$rd_h"
	;;

# --------------------------------------------------------------- t10
t10)	# cross-RP: two BI-capable endpoints under different RPs.
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	mems=( $(all_mems) )
	expect_eq "two memdevs enumerated" "${#mems[@]}" 2

	dec0=$(ep_decoder_for_mem "${mems[0]}")
	dec1=$(ep_decoder_for_mem "${mems[1]}")
	# Independent RP walks: verify neither endpoint failed BI setup.
	no_setup_failure

	# Cross-RP interleave may or may not succeed depending on the
	# root decoder's target set. If the root's interleave_ways
	# supports 2, try to build a 2-way HDM-DB region across both RPs.
	iw=$(cat "$CXL/$rd/interleave_ways" 2>/dev/null || echo 1)
	if [ "$iw" -ge 2 ]; then
		region=$(create_region "$rd" 2 256 "${mems[0]}" "${mems[1]}")
		if [ -n "$region" ] && commit_region "$region"; then
			ok "commit 2-way cross-RP HDM-DB region"
			expect_eq "both endpoints bi=1 (cross-RP)" \
				"$(cat "$CXL/$dec0/back_invalidate")$(cat "$CXL/$dec1/back_invalidate")" "11"
			destroy_region "$region"
		else
			ok "cross-RP 2-way commit rejected by root (expected on some hosts)"
			[ -n "$region" ] && destroy_region "$region"
		fi
	else
		ok "root interleave_ways=$iw (2-way cross-RP skipped)"
	fi

	# Fall back to per-endpoint 1-way to verify each RP is BI-enabled.
	region=$(create_region "$rd" 1 256 "${mems[0]}")
	[ -n "$region" ] && commit_region "$region" && \
		ok "commit 1-way HDM-DB region on RP0" || \
		fail "commit 1-way HDM-DB region on RP0"
	expect_eq "mem0 endpoint bi=1" "$(cat "$CXL/$dec0/back_invalidate")" 1
	destroy_region "$region"
	;;

# --------------------------------------------------------------- t11
t11)	# PMEM HDM-DB region: create_pmem_region on the BI root.
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	expect_eq "BI root cap_pmem=1" "$(cat "$CXL/$rd/cap_pmem" 2>/dev/null)" 1
	check_create_visibility "$rd"

	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")
	# create_region() hard-codes create_ram_region; roll a pmem
	# variant inline. The endpoint switches to mode=pmem before the
	# dpa_size allocation so DPA gets carved from the pmem partition.
	sz=$((256 << 20))
	region=$(cat "$CXL/$rd/create_pmem_region")
	echo "$region" > "$CXL/$rd/create_pmem_region" 2>/dev/null || \
		{ fail "create_pmem_region write"; exit 1; }
	ok "create HDM-DB pmem region ($region)"
	R=$CXL/$region
	# pmem regions require uuid before size; also grant it before
	# any target attach.
	echo "$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)" \
		> "$R/uuid"
	echo 256 > "$R/interleave_granularity"
	echo 1 > "$R/interleave_ways"
	echo "$sz" > "$R/size"
	echo pmem > "$CXL/$dec/mode" || fail "endpoint mode=pmem"
	# Release any leftover DPA before re-reserving on the pmem partition.
	echo 0 > "$CXL/$dec/dpa_size" 2>/dev/null
	echo "$sz" > "$CXL/$dec/dpa_size" || fail "dpa_size (pmem)"
	echo "$dec" > "$R/target0" || fail "attach mem0 to pmem region"
	check "commit HDM-DB pmem region" commit_region "$region"
	expect_eq "endpoint bi=1 (pmem)" "$(cat "$CXL/$dec/back_invalidate")" 1
	expect_eq "endpoint decoder target_type=accelerator (pmem)" \
		"$(endpoint_decoder_target_type "$dec")" accelerator
	no_setup_failure
	no_region_mismatch_warn
	# Teardown: pmem regions also honor commit=0 + delete_region.
	reset_region "$region"
	echo "$region" > "$CXL/$rd/delete_region" 2>/dev/null
	;;

# --------------------------------------------------------------- t12
t12)	# One BI-capable + one non-BI endpoint under one switch, BI CFMWS.
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	mems=( $(all_mems) )
	expect_eq "two memdevs enumerated" "${#mems[@]}" 2

	# Identify BI vs non-BI endpoint by whether cxl_bi_setup succeeded.
	# The visible proxy is: attempt a 1-way HDM-DB region on each; the
	# non-BI one rejects. We use the order of all_mems as heuristic,
	# but re-classify if the first attempt succeeds.
	m_bi= m_nobi=
	for m in "${mems[@]}"; do
		d=$(ep_decoder_for_mem "$m")
		r=$(create_region "$rd" 1 256 "$m")
		if [ -n "$r" ] && commit_region "$r" 2>/dev/null; then
			[ "$(cat "$CXL/$d/back_invalidate")" = 1 ] && m_bi=$m
			destroy_region "$r"
		else
			m_nobi=$m
			[ -n "$r" ] && destroy_region "$r"
		fi
	done
	[ -n "$m_bi" ] && ok "BI-capable endpoint identified ($m_bi)" \
		|| fail "no BI-capable endpoint (both attaches failed)"
	[ -n "$m_nobi" ] && ok "non-BI endpoint identified ($m_nobi)" \
		|| fail "no non-BI endpoint (both attaches succeeded)"

	# 2-way HDM-DB attempt across the pair: the non-BI endpoint's
	# attach must fail. Reaching commit means the attach reject was
	# missed.
	if [ -n "$m_bi" ] && [ -n "$m_nobi" ]; then
		region=$(create_region "$rd" 2 256 "$m_bi" "$m_nobi")
		if [ -n "$region" ] && commit_region "$region" 2>/dev/null; then
			fail "2-way commit unexpectedly permitted with non-BI target"
			destroy_region "$region"
		else
			ok "2-way commit rejects non-BI target"
			[ -n "$region" ] && destroy_region "$region"
		fi
		check "dmesg: 'BI not enabled on device'" \
			dmesg_saw "BI not enabled on device"
	fi
	no_region_mismatch_warn
	;;

# --------------------------------------------------------------- t14
t14)	# Two CFMWS windows: one BI, one HDM-H, two independent endpoints.
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	rd_bi=$(root_decoder_bi)
	rd_h=$(root_decoder_nobi)
	[ -n "$rd_bi" ] || { fail "no BI root decoder"; exit 1; }
	[ -n "$rd_h" ]  || { fail "no HDM-H root decoder"; exit 1; }
	ok "both BI and HDM-H root decoders present"
	check_create_visibility "$rd_bi"
	check_create_visibility "$rd_h"

	mems=( $(all_mems) )
	expect_eq "two memdevs enumerated" "${#mems[@]}" 2

	# Attach each endpoint to its "own" root decoder by trying both
	# and keeping the pairing that commits successfully. This avoids
	# hard-coding which memdev corresponds to which pxb.
	pair_bi_mem= pair_h_mem=
	for m in "${mems[@]}"; do
		r=$(create_region "$rd_bi" 1 256 "$m")
		if [ -n "$r" ] && commit_region "$r" 2>/dev/null; then
			pair_bi_mem=$m
			destroy_region "$r"
		else
			[ -n "$r" ] && destroy_region "$r"
		fi
	done
	for m in "${mems[@]}"; do
		[ "$m" = "$pair_bi_mem" ] && continue
		r=$(create_region "$rd_h" 1 256 "$m")
		if [ -n "$r" ] && commit_region "$r" 2>/dev/null; then
			pair_h_mem=$m
			destroy_region "$r"
		else
			[ -n "$r" ] && destroy_region "$r"
		fi
	done
	[ -n "$pair_bi_mem" ] && ok "BI endpoint bound to BI root ($pair_bi_mem)" \
		|| fail "no endpoint could bind to BI root"
	[ -n "$pair_h_mem" ] && ok "HDM-H endpoint bound to HDM-H root ($pair_h_mem)" \
		|| fail "no endpoint could bind to HDM-H root"

	# Cross-assignment must fail: an endpoint whose HB is not in the
	# BI CFMWS window can't attach to that root decoder.
	if [ -n "$pair_bi_mem" ] && [ -n "$pair_h_mem" ]; then
		r=$(create_region "$rd_bi" 1 256 "$pair_h_mem")
		if [ -n "$r" ] && commit_region "$r" 2>/dev/null; then
			fail "cross-assignment (HDM-H endpoint into BI root) rejected"
			destroy_region "$r"
		else
			ok "cross-assignment (HDM-H endpoint into BI root) rejected"
			[ -n "$r" ] && destroy_region "$r"
		fi
	fi
	no_setup_failure
	no_region_mismatch_warn
	;;
t15)	# One endpoint reachable by two CFMWS windows (BI + HDM-H) on
	# the same root port. Cycle a single endpoint decoder through
	# both region flavors: attach to an HDM-DB region inherits
	# DEVMEM; deleting the region must restore the decoder's
	# default target_type so a subsequent HDM-H region commits on
	# the same decoder without the "mismatch decoder type" WARN.
	check_cap_back_invalidate_present
	rd_bi=$(root_decoder_bi)
	rd_h=$(root_decoder_nobi)
	[ -n "$rd_bi" ] || { fail "no BI root decoder"; exit 1; }
	[ -n "$rd_h" ]  || { fail "no HDM-H root decoder"; exit 1; }
	ok "both BI and HDM-H root decoders present"

	mems=( $(all_mems) )
	expect_eq "one memdev enumerated" "${#mems[@]}" 1
	mem=${mems[0]}
	dec=$(ep_decoder_for_mem "$mem")
	[ -n "$dec" ] || { fail "no endpoint decoder for $mem"; exit 1; }

	expect_eq "decoder starts at default type" \
		"$(endpoint_decoder_target_type "$dec")" expander

	region=$(create_region "$rd_bi" 1 256 "$mem")
	[ -n "$region" ] || { fail "HDM-DB region create"; exit 1; }
	check "HDM-DB region commit" commit_region "$region"
	expect_eq "endpoint bi=1 in HDM-DB region" "$(cat "$CXL/$dec/back_invalidate")" 1
	expect_eq "decoder type follows HDM-DB region" \
		"$(endpoint_decoder_target_type "$dec")" accelerator
	destroy_region "$region" "$rd_bi"

	expect_eq "decoder type restored to default after delete" \
		"$(endpoint_decoder_target_type "$dec")" expander

	region=$(create_region "$rd_h" 1 256 "$mem")
	[ -n "$region" ] || { fail "HDM-H region create on recycled decoder"; exit 1; }
	check "HDM-H region commit on recycled decoder" commit_region "$region"
	expect_eq "endpoint bi=0 in HDM-H region" "$(cat "$CXL/$dec/back_invalidate")" 0
	destroy_region "$region" "$rd_h"

	no_setup_failure
	no_region_mismatch_warn
	;;

# --------------------------------------------------------------- t18
t18)	# concurrency storm on the t5 topology (two EPs, shared USP/RP).
	# Phase A: parallel unbind/bind flips of both endpoints by BDF
	# (memN names recycle across a flip, BDFs never do) under a
	# concurrent back_invalidate/cap_back_invalidate sysfs reader.
	# Races nr_bi accounting on the shared dports, cxl_bi_setup vs
	# cxl_bi_dealloc, and devres teardown against sysfs reads.
	# Phase B: region create/commit/destroy churn with per-cycle
	# timing: a rollback regression that drives a commit poll on a
	# failed dport shows up as a 5s+ jump in cycle time.
	# Both phases end with a full-function proof (2-way HDM-DB
	# commit) and a dmesg hygiene sweep over the storm window.
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	mems=( $(all_mems) )
	expect_eq "two memdevs enumerated" "${#mems[@]}" 2
	bdf0=$(bdf_for_mem "${mems[0]}")
	bdf1=$(bdf_for_mem "${mems[1]}")

	# Pre-storm baseline: the topology works.
	region=$(create_region "$rd" 2 256 "${mems[0]}" "${mems[1]}")
	[ -n "$region" ] && commit_region "$region" && \
		ok "pre-storm 2-way HDM-DB commit" || \
		{ fail "pre-storm 2-way HDM-DB commit"; exit 1; }
	destroy_region "$region"

	# Fresh dmesg window: everything the storm provokes is swept
	# by the hygiene checks below.
	dmesg -C

	FLIPS=12
	flipfail=/tmp/t18-flipfail.$$
	: > "$flipfail"
	flip_storm() { # flip_storm <bdf>
		local bdf=$1 i j
		for i in $(seq 1 $FLIPS); do
			echo "$bdf" > /sys/bus/pci/drivers/cxl_pci/unbind \
				2>/dev/null || echo "$bdf unbind#$i" >> "$flipfail"
			sleep 0.$((RANDOM % 4))
			echo "$bdf" > /sys/bus/pci/drivers/cxl_pci/bind \
				2>/dev/null || echo "$bdf bind#$i" >> "$flipfail"
			for j in $(seq 1 50); do
				[ -n "$(mem_for_bdf "$bdf")" ] && break
				sleep 0.2
			done
			[ -n "$(mem_for_bdf "$bdf")" ] || \
				echo "$bdf reprobe#$i" >> "$flipfail"
		done
	}
	readflag=/tmp/t18-reader.$$
	touch "$readflag"
	( while [ -e "$readflag" ]; do
		cat $CXL/decoder0.*/cap_back_invalidate $CXL/endpoint*/decoder*/back_invalidate \
			>/dev/null 2>&1
	  done ) &
	reader_pid=$!
	flip_storm "$bdf0" & p0=$!
	flip_storm "$bdf1" & p1=$!
	wait $p0 $p1
	rm -f "$readflag"; wait $reader_pid 2>/dev/null
	expect_eq "storm A: no unbind/bind/reprobe failures" \
		"$(wc -l < "$flipfail")" 0
	[ -s "$flipfail" ] && sed 's/^/# /' "$flipfail"
	rm -f "$flipfail"

	# Convergence: the bind write returns when cxl_pci probe is done,
	# but the memdev -> endpoint port -> decoders chain (cxl_mem and
	# cxl_port probes) completes after it. Wait at the decoder level.
	#
	# The kernel does not promise that a probe racing a sibling's
	# switch-port reap succeeds: it may fail terminally, leaving the
	# memdev driverless, recoverable by rebind (see README Known
	# limitations). Assert the recoverable contract: allow one
	# recovery rebind per endpoint and report it; only a memdev that
	# stays endpoint-less after that is a failure.
	recfile=/tmp/t18-recovered.$$
	: > "$recfile"
	wait_ep() { # wait_ep <bdf> <passes> -> echoes the endpoint decoder
		local i m d
		for i in $(seq 1 "$2"); do
			m=$(mem_for_bdf "$1")
			if [ -n "$m" ]; then
				d=$(ep_decoder_for_mem "$m")
				[ -n "$d" ] && { echo "$d"; return 0; }
			fi
			sleep 0.5
		done
		return 1
	}
	converge() { # converge <bdf> -> decoder; one recovery rebind allowed
		local d m
		d=$(wait_ep "$1" 20)
		if [ -z "$d" ]; then
			m=$(mem_for_bdf "$1")
			if [ -n "$m" ] && [ ! -e "$CXL/$m/driver" ]; then
				echo "$m" >> "$recfile"
				echo "$m" > /sys/bus/cxl/drivers/cxl_mem/bind \
					2>/dev/null
				d=$(wait_ep "$1" 60)
			fi
		fi
		echo "$d"
	}
	dec0=$(converge "$bdf0")
	dec1=$(converge "$bdf1")
	mem0=$(mem_for_bdf "$bdf0")
	mem1=$(mem_for_bdf "$bdf1")
	nrec=$(wc -l < "$recfile")
	rm -f "$recfile"
	[ "$nrec" -gt 0 ] && echo \
		"# storm A: recovered $nrec endpoint(s) via rebind (probe lost reap race)"
	if [ -n "$dec0" ] && [ -n "$dec1" ]; then
		ok "storm A: both endpoints converged ($mem0 $mem1, recovered=$nrec)"
	else
		fail "storm A: both endpoints converged (dec0='$dec0' dec1='$dec1' recovered=$nrec)"
		dmesg | grep -E "cxl.*probe|endpoint" | tail -8 | sed 's/^/# /'
		exit 1
	fi
	check_endpoint_bi_present

	# Phase B: region churn, per-cycle wall-clock bounded.
	CYCLES=10 max_ms=0 churn_fail=0
	for i in $(seq 1 $CYCLES); do
		t0=$(date +%s%N)
		region=$(create_region "$rd" 1 256 "$mem0")
		if [ -z "$region" ] || ! commit_region "$region"; then
			churn_fail=$((churn_fail + 1))
		fi
		[ -n "$region" ] && destroy_region "$region"
		ms=$((($(date +%s%N) - t0) / 1000000))
		[ "$ms" -gt "$max_ms" ] && max_ms=$ms
	done
	expect_eq "storm B: $CYCLES create/commit/destroy cycles clean" \
		"$churn_fail" 0
	echo "# storm B max cycle: ${max_ms}ms"
	if [ "$max_ms" -lt 15000 ]; then
		ok "storm B: no stalled cycle (max ${max_ms}ms < 15s)"
	else
		fail "storm B: no stalled cycle (max ${max_ms}ms, 5s-poll leak?)"
	fi

	# Post-storm full-function proof.
	region=$(create_region "$rd" 2 256 "$mem0" "$mem1")
	[ -n "$region" ] && commit_region "$region" && \
		ok "post-storm 2-way HDM-DB commit" || \
		fail "post-storm 2-way HDM-DB commit"
	dec0=$(ep_decoder_for_mem "$mem0")
	dec1=$(ep_decoder_for_mem "$mem1")
	expect_eq "post-storm both endpoints bi=1" \
		"$(cat "$CXL/$dec0/back_invalidate")$(cat "$CXL/$dec1/back_invalidate")" "11"
	[ -n "$region" ] && destroy_region "$region"

	# Hygiene sweep over the whole storm window.
	for pat in "WARNING:" "BUG:" "possible circular" "refcount_t" \
		   "BI setup failed" "Failed to request region" \
		   "mismatch decoder type"; do
		if dmesg | grep -q "$pat"; then
			fail "dmesg clean of '$pat'"
			dmesg | grep "$pat" | head -2 | sed 's/^/# /'
		else
			ok "dmesg clean of '$pat'"
		fi
	done
	;;

# --------------------------------------------------------------- t19
t19)	# manual window-level 2-way HDM-DB interleave across two HBs.
	# The window has two targets, so the root decoder is iw=2 and
	# region targets must be wired in window-target (BDF) order;
	# 1-way regions cannot exist under this window (every stride
	# crosses both HBs).
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	expect_eq "root decoder iw=2 (window-level interleave)" \
		"$(cat "$CXL/$rd/interleave_ways")" 2
	CR_IG=4096
	mems=( $(for m in $CXL/mem*; do
			m=$(basename "$m")
			echo "$(bdf_for_mem "$m") $m"
		 done | sort | awk '{print $2}') )
	expect_eq "two memdevs enumerated" "${#mems[@]}" 2
	dec0=$(ep_decoder_for_mem "${mems[0]}")
	dec1=$(ep_decoder_for_mem "${mems[1]}")

	region=$(create_region "$rd" 2 256 "${mems[0]}" "${mems[1]}")
	[ -n "$region" ] && ok "create 2-way HDM-DB region (cross-HB)" \
		|| { fail "create 2-way HDM-DB region (cross-HB)"; exit 1; }
	check "commit 2-way HDM-DB region (cross-HB)" commit_region "$region"
	expect_eq "both endpoints bi=1 post-commit" \
		"$(cat "$CXL/$dec0/back_invalidate")$(cat "$CXL/$dec1/back_invalidate")" "11"
	check "dmesg: 'created HDM-DB' region log" dmesg_saw "created HDM-DB"
	no_setup_failure
	no_region_mismatch_warn
	destroy_region "$region"
	expect_eq "both endpoints bi=0 post-destroy" \
		"$(cat "$CXL/$dec0/back_invalidate")$(cat "$CXL/$dec1/back_invalidate")" "00"

	region=$(create_region "$rd" 2 256 "${mems[0]}" "${mems[1]}")
	[ -n "$region" ] && commit_region "$region" && \
		ok "re-create + commit after full teardown" || \
		fail "re-create + commit after full teardown"
	[ -n "$region" ] && destroy_region "$region"
	;;

# --------------------------------------------------------------- t20
t20)	# manual interleave mixing coherency models must reject. Same
	# window shape as t19 (which is the passing control), but the
	# second device is host-only coherent: the 2-way HDM-DB attach
	# must reject the plain target in either wiring order, with no
	# WARNs and nothing left committed. No 1-way fallback exists
	# under a 2-target window, so the BI device is classified from
	# the 'BI requests enabled' BDF instead of a probe commit.
	check_cap_back_invalidate_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	CR_IG=4096
	mems=( $(all_mems) )
	expect_eq "two memdevs enumerated" "${#mems[@]}" 2

	expect_eq "exactly one endpoint enabled BI" \
		"$(dmesg | grep -c 'BI requests enabled')" 1
	bdf_bi=$(dmesg | grep "BI requests enabled" | head -1 | \
		 grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]')
	m_bi=$(mem_for_bdf "$bdf_bi")
	m_nobi=
	for m in "${mems[@]}"; do
		[ "$m" = "$m_bi" ] || m_nobi=$m
	done
	[ -n "$m_bi" ] && [ -n "$m_nobi" ] && \
		ok "classified BI ($m_bi) vs host-only ($m_nobi) endpoints" || \
		{ fail "classified BI vs host-only endpoints"; exit 1; }

	for order in "$m_bi $m_nobi" "$m_nobi $m_bi"; do
		set -- $order
		region=$(create_region "$rd" 2 256 "$1" "$2")
		if [ -n "$region" ] && commit_region "$region" 2>/dev/null; then
			fail "mixed 2-way rejected (order $1,$2)"
			destroy_region "$region"
		else
			ok "mixed 2-way rejected (order $1,$2)"
			[ -n "$region" ] && destroy_region "$region"
		fi
	done
	if dmesg | grep -qE "BI not enabled on device|HDM is host-only coherent"; then
		ok "device coherency gate diagnostic present"
	else
		fail "device coherency gate diagnostic present"
	fi
	ncommitted=0
	for r in $CXL/region*/commit; do
		[ -e "$r" ] && [ "$(cat "$r")" = 1 ] && ncommitted=$((ncommitted+1))
	done
	expect_eq "nothing left committed after mixed attempts" \
		"$ncommitted" 0
	d_nobi=$(ep_decoder_for_mem "$m_nobi")
	expect_eq "host-only endpoint survives, bi=0" \
		"$(cat "$CXL/$d_nobi/back_invalidate")" 0
	no_region_mismatch_warn
	;;

# --------------------------------------------------------------- t21
t21)	# BOTH-coherency endpoint (CXL_HDM_DECODER_COHERENCY_BOTH)
	# behind a switch, BI + HDM-H windows. When BI setup fails at
	# endpoint probe (staged by qemu committing slower than the
	# advertised timeout), the device must fail closed for HDM-DB
	# regions but keep serving host-only ones on the same decoder.
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	rd_bi=$(root_decoder_bi)
	rd_h=$(root_decoder_nobi)
	[ -n "$rd_bi" ] || { fail "no BI root decoder"; exit 1; }
	[ -n "$rd_h" ]  || { fail "no HDM-H root decoder"; exit 1; }
	ok "both BI and HDM-H root decoders present"

	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")
	[ -n "$dec" ] || { fail "no endpoint decoder for $mem"; exit 1; }

	if ! dmesg | grep -q "BI setup failed"; then
		# Stock qemu commits within the advertised timeout, so
		# setup succeeded and the fallback cannot be staged.
		ok "fallback staging # SKIP needs qemu BI commit-latency mod"
	else
		ok "BI setup failed at boot (staged commit timeout)"
		if dmesg | grep -q "BI-ID commit timed out"; then
			ok "BI-ID commit timed out logged"
		else
			fail "BI-ID commit timed out logged"
		fi
		expect_eq "endpoint bi=0 after failed setup" \
			"$(cat "$CXL/$dec/back_invalidate")" 0
		expect_eq "decoder defaults to expander (BOTH)" \
			"$(endpoint_decoder_target_type "$dec")" expander

		# Fail closed: an HDM-DB attach on the BI window rejects.
		region=$(create_region "$rd_bi" 1 256 "$mem")
		if [ -z "$region" ]; then
			ok "HDM-DB attach rejected with BI down"
		elif commit_region "$region" 2>/dev/null; then
			fail "HDM-DB region committed with BI down"
			destroy_region "$region" "$rd_bi"
		else
			ok "HDM-DB attach rejected with BI down"
			destroy_region "$region" "$rd_bi"
		fi
		if dmesg | grep -q "BI not enabled on device"; then
			ok "attach gate: 'BI not enabled on device'"
		else
			fail "attach gate: 'BI not enabled on device'"
		fi
		# A failed attach leaves an uncommitted region shell
		# behind; clear it so the HDM-H half starts clean.
		for r in $(ls -d "$CXL"/region* 2>/dev/null); do
			echo "$(basename "$r")" > "$CXL/$rd_bi/delete_region" \
				2>/dev/null
		done

		# The same decoder must still serve host-only regions.
		region=$(create_region "$rd_h" 1 256 "$mem")
		[ -n "$region" ] || \
			{ fail "HDM-H region create after BI failure"; exit 1; }
		check "HDM-H commit after BI failure" commit_region "$region"
		expect_eq "endpoint bi=0 (HDM-H)" "$(cat "$CXL/$dec/back_invalidate")" 0
		expect_eq "decoder type stays expander" \
			"$(endpoint_decoder_target_type "$dec")" expander
		destroy_region "$region" "$rd_h"
		no_region_mismatch_warn
	fi
	;;

# --------------------------------------------------------------- t22
t22)	# BI device reporting Unknown coherency models. The kernel must
	# still enable BI and let the decoder inherit device-coherent
	# when it joins an HDM-DB region: Unknown says nothing about
	# whether Target Range Type is writable, so refusing it would
	# also exclude devices that support both models silently.
	check_cap_back_invalidate_present
	check_endpoint_bi_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")
	[ -n "$dec" ] || { fail "no endpoint decoder for $mem"; exit 1; }

	# Pre-region state: the default is host-only, as for any Type 3
	# decoder that does not report device-coherent only.
	expect_eq "decoder defaults to expander" \
		"$(endpoint_decoder_target_type "$dec")" expander
	expect_eq "endpoint bi=0 before attach" "$(cat "$CXL/$dec/back_invalidate")" 0
	no_setup_failure

	region=$(create_region "$rd" 1 256 "$mem")
	[ -n "$region" ] && ok "HDM-DB region create (Unknown coherency)" \
		|| { fail "HDM-DB region create (Unknown coherency)"; exit 1; }
	# The inheritance under test: host-only default -> device-coherent.
	expect_eq "decoder inherits accelerator on attach" \
		"$(endpoint_decoder_target_type "$dec")" accelerator
	expect_eq "endpoint bi=1 on attach" "$(cat "$CXL/$dec/back_invalidate")" 1
	check "HDM-DB commit (Unknown coherency)" commit_region "$region"
	expect_eq "endpoint bi=1 committed" "$(cat "$CXL/$dec/back_invalidate")" 1

	destroy_region "$region" "$rd"
	expect_eq "decoder back to expander after destroy" \
		"$(endpoint_decoder_target_type "$dec")" expander
	no_region_mismatch_warn
	;;
esac

exit $((FAIL != 0))
