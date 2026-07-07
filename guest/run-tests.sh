#!/bin/bash
# In-guest CXL BI test driver. TAP-ish output on stdout.
# Usage: run-tests.sh <suite>   (suite: t1 | t2 | t3 | t4 | t5 | t6 |
#                                       t7 | t8 | t9 | t10)
#
# Invariants exercised (kernel v6 BI series):
#  - patch 1: BI regs mapped inside the dport devres group (leak fix).
#  - patch 2: cxl_bi_setup enables BI on every dport in the path;
#             rollback skips the failed dport (Richard).
#  - patch 3: HDM Supported Coherency Models drive endpoint default
#             target_type; pre-committed BI decoders rejected -ENXIO.
#  - patch 4: root cap_bi from CFMWS BI restriction; region type
#             derived from root decoder F_BI at userspace create;
#             endpoint bi=1 iff committed in HDM-DB region.
#  - patch 5: F_TYPE2/F_TYPE3 renamed to F_DEVMEM/F_HOSTONLY.

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

# ---------- enumeration helpers ------------------------------------
root_decoder_bi() { # first root decoder whose cap_bi = 1
	local d
	for d in $CXL/decoder0.*; do
		[ -e "$d/cap_bi" ] || continue
		[ "$(cat "$d/cap_bi")" = 1 ] && { basename "$d"; return; }
	done
}
root_decoder_nobi() { # first root decoder whose cap_bi = 0
	local d
	for d in $CXL/decoder0.*; do
		[ -e "$d/cap_bi" ] || continue
		[ "$(cat "$d/cap_bi")" = 0 ] && { basename "$d"; return; }
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
region_type_of() { # regionN -> "accelerator" | "expander"
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
	echo 256 > "$R/interleave_granularity" || { echo ""; return 1; }
	echo "$ways" > "$R/interleave_ways" || { echo ""; return 1; }
	echo $((sz * ways)) > "$R/size" || { echo ""; return 1; }
	local i=0 mem dec
	for mem in "$@"; do
		dec=$(ep_decoder_for_mem "$mem")
		[ -n "$dec" ] || { echo ""; return 1; }
		echo ram > "$CXL/$dec/mode" 2>/dev/null
		echo "$sz" > "$CXL/$dec/dpa_size" || { echo ""; return 1; }
		echo "$dec" > "$R/target$i" || { echo ""; return 1; }
		i=$((i+1))
	done
	echo "$region"
}
commit_region()  { echo 1 > "$CXL/$1/commit"; }
reset_region()   { echo 0 > "$CXL/$1/commit" 2>/dev/null; }
destroy_region() {
	local rd
	reset_region "$1"
	rd=$(root_decoder_any)
	echo "$1" > "$CXL/$rd/delete_region" 2>/dev/null
}

# ---------- generic invariants -----------------------------------
# Every root decoder must expose cap_bi (added by patch 4) whether it
# is set or not. Verify presence + a valid 0/1 value.
check_cap_bi_present() {
	local d v n=0
	for d in $CXL/decoder0.*; do
		[ -e "$d/cap_bi" ] || { fail "$d/cap_bi missing"; return; }
		v=$(cat "$d/cap_bi")
		case $v in 0|1) n=$((n+1)) ;; *)
			fail "$d/cap_bi has bogus value '$v'"; return ;;
		esac
	done
	ok "cap_bi present on all root decoders ($n found)"
}

# The `bi` file is present on every endpoint decoder and reads 0 or 1.
check_endpoint_bi_present() {
	local ep d v n=0
	for ep in $CXL/endpoint*; do
		[ -d "$ep" ] || continue
		for d in "$ep"/decoder*; do
			[ -e "$d/bi" ] || { fail "$d/bi missing"; return; }
			v=$(cat "$d/bi")
			case $v in 0|1) n=$((n+1)) ;; *)
				fail "$d/bi has bogus value '$v'"; return ;;
			esac
		done
	done
	ok "bi present on all endpoint decoders ($n found)"
}

# Switch decoders must NOT expose cap_bi or bi (patch 4 only added them
# to root and endpoint groups respectively).
check_no_switch_bi_files() {
	local d bad=0
	for d in $CXL/decoder*; do
		[ -d "$d" ] || continue
		local nm; nm=$(basename "$d")
		# skip root (decoder0.*) and endpoint decoders
		case $nm in decoder0.*) continue ;; esac
		local par; par=$(readlink -f "$d/..")
		basename "$par" | grep -q '^endpoint' && continue
		if [ -e "$d/cap_bi" ] || [ -e "$d/bi" ]; then
			bad=$((bad+1))
		fi
	done
	expect_eq "no cap_bi/bi on switch decoders" "$bad" 0
}

# Read-only ABI: writes to bi/cap_bi must be rejected.
check_bi_ro() {
	local ep=$1 rd; rd=$(root_decoder_bi)
	if [ -z "$rd" ]; then ok "cap_bi RO (no BI root decoder)"; else
		if echo 0 > "$CXL/$rd/cap_bi" 2>/dev/null; then
			fail "cap_bi writable (should be RO)"
		else
			ok "cap_bi read-only"
		fi
	fi
	if [ -n "$ep" ]; then
		if echo 0 > "$CXL/$ep/bi" 2>/dev/null; then
			fail "endpoint bi writable (should be RO)"
		else
			ok "endpoint bi read-only"
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
# patch 4 relaxes cxl_rr_assign_decoder's WARN_ONCE for HDM-DB regions;
# any lingering "mismatch decoder type" warning on a BI attach is a
# regression.
no_type_mismatch_warn() {
	if dmesg | grep -q "mismatch decoder type"; then
		fail "no 'mismatch decoder type' WARN across BI attach"
	else
		ok "no 'mismatch decoder type' WARN across BI attach"
	fi
}

# create_region_region_visible <root_decoder>
# Returns 0 if the given root decoder exposes create_ram_region or
# create_pmem_region files matching its cap_ram / cap_pmem flags. Patch
# 4 flipped can_create_ram/can_create_pmem to accept either HDM-H
# (F_HOSTONLY|F_RAM) or HDM-DB (F_DEVMEM|F_BI|F_RAM); we verify the
# visibility algebra matches the flags.
check_create_visibility() { # <root_decoder>
	local rd=$1 have_cap_bi have_cap_ram have_cap_pmem
	have_cap_bi=$(cat "$CXL/$rd/cap_bi" 2>/dev/null || echo 0)
	have_cap_ram=$(cat "$CXL/$rd/cap_ram" 2>/dev/null || echo 0)
	have_cap_pmem=$(cat "$CXL/$rd/cap_pmem" 2>/dev/null || echo 0)
	# On an HDM-DB CFMWS: cap_bi=1, exactly one of ram/pmem is 1, and
	# the corresponding create_*_region attr must be present.
	# On an HDM-H CFMWS: cap_bi=0, same rule for ram/pmem visibility.
	if [ "$have_cap_ram" = 1 ]; then
		if [ -e "$CXL/$rd/create_ram_region" ]; then
			ok "$rd: create_ram_region present (cap_ram=1, cap_bi=$have_cap_bi)"
		else
			fail "$rd: create_ram_region missing despite cap_ram=1"
		fi
	fi
	if [ "$have_cap_pmem" = 1 ]; then
		if [ -e "$CXL/$rd/create_pmem_region" ]; then
			ok "$rd: create_pmem_region present (cap_pmem=1, cap_bi=$have_cap_bi)"
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
	check_cap_bi_present
	check_endpoint_bi_present
	check_no_switch_bi_files

	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	ok "found BI root decoder $rd"

	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")
	[ -n "$dec" ] || { fail "no endpoint decoder for $mem"; exit 1; }
	expect_eq "endpoint bi=0 pre-region" "$(cat "$CXL/$dec/bi")" 0
	check_bi_ro "$dec"

	# create + attach + commit HDM-DB region
	region=$(create_region "$rd" 1 256 "$mem")
	[ -n "$region" ] || { fail "create HDM-DB region"; exit 1; }
	ok "create HDM-DB region"
	expect_eq "region target_type is accelerator (DEVMEM)" \
		"$(region_type_of "$region")" accelerator
	check "commit HDM-DB region" commit_region "$region"
	expect_eq "endpoint bi=1 post-commit" "$(cat "$CXL/$dec/bi")" 1
	no_setup_failure
	destroy_region "$region"
	expect_eq "endpoint bi=0 post-destroy" "$(cat "$CXL/$dec/bi")" 0
	;;

# ---------------------------------------------------------------- t2
t2)	# switched happy path: DSP + USP + RP + endpoint.
	check_cap_bi_present
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
	expect_eq "endpoint bi=1 (switched)" "$(cat "$CXL/$dec/bi")" 1
	expect_eq "endpoint decoders_committed bumped" \
		"$(port_committed_count "$ep")" "$((pre_committed + 1))"
	no_setup_failure
	no_type_mismatch_warn

	# Detach: reset commit, tear down region. Endpoint bi returns to 0.
	destroy_region "$region"
	expect_eq "endpoint bi=0 after destroy" "$(cat "$CXL/$dec/bi")" 0
	expect_eq "endpoint decoders_committed back to pre" \
		"$(port_committed_count "$ep")" "$pre_committed"

	# Re-create/commit cycle: cxl_bi_setup/dealloc must not have
	# toggled BI on the topology, and a fresh region reaches bi=1.
	region=$(create_region "$rd" 1 256 "$mem")
	[ -n "$region" ] && commit_region "$region" && \
		ok "re-create + commit HDM-DB after full teardown" || \
		fail "re-create + commit HDM-DB after full teardown"
	expect_eq "endpoint bi=1 (recreated region)" \
		"$(cat "$CXL/$dec/bi")" 1
	destroy_region "$region"
	no_type_mismatch_warn

	# Phase 2 (unbind/rebind) is driven from run-all.sh with the
	# guest/unbindrebind-phase.sh helper.
	;;

# ---------------------------------------------------------------- t3
t3)	# BI-capable device, HDM-H (no BI) CFMWS. Region must be HOSTONLYMEM.
	check_cap_bi_present
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
	expect_eq "region target_type is expander (HOSTONLYMEM)" \
		"$(region_type_of "$region")" expander
	check "commit HDM-H region" commit_region "$region"
	expect_eq "endpoint bi=0 (HDM-H)" "$(cat "$CXL/$dec/bi")" 0
	# The BI walk itself must have found the topology capable but
	# there was nothing on the CFMWS side to commit BI decoders for.
	no_setup_failure
	destroy_region "$region"
	;;

# ---------------------------------------------------------------- t4
t4)	# non-BI device, BI-restricted CFMWS. Attach must be rejected.
	check_cap_bi_present
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
				"$(cat "$CXL/$dec/bi")" 0
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
	check_cap_bi_present
	check_endpoint_bi_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	mems=( $(all_mems) )
	expect_eq "two memdevs enumerated" "${#mems[@]}" 2

	dec0=$(ep_decoder_for_mem "${mems[0]}")
	dec1=$(ep_decoder_for_mem "${mems[1]}")
	expect_eq "both endpoints bi=0 pre-region" \
		"$(cat "$CXL/$dec0/bi")$(cat "$CXL/$dec1/bi")" "00"

	region=$(create_region "$rd" 2 256 "${mems[0]}" "${mems[1]}")
	[ -n "$region" ] && ok "create 2-way HDM-DB region" \
		|| { fail "create 2-way HDM-DB region"; exit 1; }
	check "commit 2-way HDM-DB region" commit_region "$region"
	expect_eq "both endpoints bi=1 post-commit" \
		"$(cat "$CXL/$dec0/bi")$(cat "$CXL/$dec1/bi")" "11"
	no_setup_failure

	# Destroy resets both endpoints.
	destroy_region "$region"
	expect_eq "both endpoints bi=0 post-destroy" \
		"$(cat "$CXL/$dec0/bi")$(cat "$CXL/$dec1/bi")" "00"
	# Phase 2 (nr_bi refcount via hot-remove) driven from run-all.sh.
	;;

# ---------------------------------------------------------------- t6
t6)	# USP RT optional per 8.2.4.26. With upstream QEMU this suite is
	# effectively identical to t2; it exists to make the "USP without
	# RT is allowed" invariant load-bearing so a regression on the
	# @bi==NULL-allowed-for-USP branch of cxl_is_bi_capable() shows up.
	check_cap_bi_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")
	region=$(create_region "$rd" 1 256 "$mem")
	[ -n "$region" ] && ok "create HDM-DB region (USP RT variant)" \
		|| { fail "create HDM-DB region"; exit 1; }
	check "commit HDM-DB region" commit_region "$region"
	expect_eq "endpoint bi=1 (USP RT variant)" \
		"$(cat "$CXL/$dec/bi")" 1
	no_setup_failure
	destroy_region "$region"
	;;

# ---------------------------------------------------------------- t7
t7)	# endpoint uplink not in 256B Flit. cxl_is_bi_capable false at the
	# endpoint check; BI setup returns 0 silently and cxlds->bi = 0.
	check_cap_bi_present
	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")

	# Same failure surface as t4: attach to a DEVMEM region rejects.
	region=$(create_region "$rd" 1 256 "$mem")
	if [ -n "$region" ] && commit_region "$region" 2>/dev/null; then
		fail "non-flit endpoint commit unexpectedly succeeded"
		expect_eq "endpoint bi stays 0 on non-flit" \
			"$(cat "$CXL/$dec/bi")" 0
		destroy_region "$region"
	else
		ok "non-flit endpoint rejected (attach or commit)"
		[ -n "$region" ] && destroy_region "$region"
	fi
	# Dmesg on this path can be either "BI not supported by topology"
	# (BI walk skipped) or "BI not enabled on device" (region attach).
	if dmesg_saw "BI not supported by topology" || \
	   dmesg_saw "BI not enabled on device"; then
		ok "dmesg reflects non-flit rejection"
	else
		fail "dmesg reflects non-flit rejection"
	fi
	;;

# ---------------------------------------------------------------- t8
t8)	# DSP not in 256B Flit mode. BI walk's DSP check fails, cxlds->bi=0.
	check_cap_bi_present
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
	;;

# ---------------------------------------------------------------- t9
t9)	# cascaded switches: cxl_bi_setup walks two switch pairs.
	check_cap_bi_present
	check_endpoint_bi_present
	# Expect at least two non-root cxl_port entries (outer + inner switch).
	nports=$(ls -d $CXL/port* 2>/dev/null | wc -l)
	if [ "$nports" -ge 2 ]; then
		ok "two switch cxl_port entries present ($nports)"
	else
		fail "cascaded switches ($nports cxl_port(s), want >=2)"
	fi

	rd=$(root_decoder_bi)
	[ -n "$rd" ] || { fail "no BI root decoder"; exit 1; }
	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")

	region=$(create_region "$rd" 1 256 "$mem")
	[ -n "$region" ] && ok "create HDM-DB region (cascaded)" \
		|| { fail "create HDM-DB region"; exit 1; }
	check "commit HDM-DB region across cascade" commit_region "$region"
	expect_eq "endpoint bi=1 (cascaded)" "$(cat "$CXL/$dec/bi")" 1
	no_setup_failure
	destroy_region "$region"
	;;

# --------------------------------------------------------------- t10
t10)	# cross-RP: two BI-capable endpoints under different RPs.
	check_cap_bi_present
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
				"$(cat "$CXL/$dec0/bi")$(cat "$CXL/$dec1/bi")" "11"
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
	expect_eq "mem0 endpoint bi=1" "$(cat "$CXL/$dec0/bi")" 1
	destroy_region "$region"
	;;

# --------------------------------------------------------------- t11
t11)	# PMEM HDM-DB region: create_pmem_region on the BI root.
	check_cap_bi_present
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
	echo 256 > "$R/interleave_granularity"
	echo 1 > "$R/interleave_ways"
	echo "$sz" > "$R/size"
	# UUID: pmem regions require it before commit.
	echo "$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)" \
		> "$R/uuid"
	echo pmem > "$CXL/$dec/mode" || fail "endpoint mode=pmem"
	echo "$sz" > "$CXL/$dec/dpa_size" || fail "dpa_size (pmem)"
	echo "$dec" > "$R/target0" || fail "attach mem0 to pmem region"
	check "commit HDM-DB pmem region" commit_region "$region"
	expect_eq "endpoint bi=1 (pmem)" "$(cat "$CXL/$dec/bi")" 1
	expect_eq "region target_type accelerator (pmem)" \
		"$(cat "$R/target_type")" accelerator
	no_setup_failure
	no_type_mismatch_warn
	# Teardown: pmem regions also honor commit=0 + delete_region.
	reset_region "$region"
	echo "$region" > "$CXL/$rd/delete_region" 2>/dev/null
	;;

# --------------------------------------------------------------- t12
t12)	# One BI-capable + one non-BI endpoint under one switch, BI CFMWS.
	check_cap_bi_present
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
			[ "$(cat "$CXL/$d/bi")" = 1 ] && m_bi=$m
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
	no_type_mismatch_warn
	;;

# --------------------------------------------------------------- t14
t14)	# Two CFMWS windows: one BI, one HDM-H, two independent endpoints.
	check_cap_bi_present
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
	no_type_mismatch_warn
	;;
esac

echo "1..$N"
echo "# passed: $PASS  failed: $FAIL"
exit $((FAIL != 0))
