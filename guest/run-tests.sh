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
	mem=$(all_mems | head -1)
	dec=$(ep_decoder_for_mem "$mem")

	region=$(create_region "$rd" 1 256 "$mem")
	[ -n "$region" ] && ok "create HDM-DB region" \
		|| { fail "create HDM-DB region"; exit 1; }
	check "commit HDM-DB region under switch" commit_region "$region"
	expect_eq "endpoint bi=1 (switched)" "$(cat "$CXL/$dec/bi")" 1
	no_setup_failure

	# Detach: reset commit, tear down region. Endpoint bi returns to 0.
	destroy_region "$region"
	expect_eq "endpoint bi=0 after destroy" "$(cat "$CXL/$dec/bi")" 0
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
esac

echo "1..$N"
echo "# passed: $PASS  failed: $FAIL"
exit $((FAIL != 0))
