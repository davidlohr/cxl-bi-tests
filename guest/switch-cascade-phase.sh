#!/bin/bash
# t9 phase 2: mid-level switch port unbind cascade.
#
# Ports created by endpoint enumeration are devres-hosted on their
# parent port, so unbinding the *outer* switch port's cxl_port driver
# must tear down the child subtree first (inner port, endpoint port,
# region) and free the outer port's dports last. cxl_bi_dealloc's
# dport-disable walk therefore runs while every ancestor mapping is
# still live; a LIFO ordering regression is a use-after-free in that
# walk. Once the cascaded memdev detach runs cxl_detach_ep, the outer
# port is empty and driverless and gets reaped outright; a cxl_mem
# rebind then re-enumerates the whole cascade (fresh port numbers,
# re-probed dports, re-mapped BI RT) and a new HDM-DB region must
# commit. A second cycle fires the unbind under region create/commit
# churn plus a decoder-attribute reader to race the cascade against
# an in-flight cxl_bi_setup walk.
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

BDF_RE='^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$'
# Switch ports are the cxl_ports whose uport is a PCI function (USP).
# The outer one hangs off the root port: its USP's grandparent in PCI
# sysfs is the host bridge root bus, not another BDF.
classify_switch_ports() { # sets OUTER, INNER, NSWITCH
	local p u gp
	OUTER=; INNER=; NSWITCH=0
	for p in $CXL/port*; do
		[ -d "$p" ] || continue
		u=$(readlink -f "$p/uport")
		[[ "$(basename "$u")" =~ $BDF_RE ]] || continue
		NSWITCH=$((NSWITCH+1))
		gp=$(basename "$(dirname "$(dirname "$u")")")
		if [[ "$gp" =~ $BDF_RE ]]; then
			INNER=$(basename "$p")
		else
			OUTER=$(basename "$p")
		fi
	done
}

create_region() { # <root-decoder> <ep-decoder>
	local rd=$1 dec=$2 sz=$((256 << 20))
	local region; region=$(cat "$CXL/$rd/create_ram_region")
	echo "$region" > "$CXL/$rd/create_ram_region" 2>/dev/null || return 1
	local R=$CXL/$region
	echo 256 > "$R/interleave_granularity"
	echo 1   > "$R/interleave_ways"
	echo $sz > "$R/size"
	echo 0 > "$CXL/$dec/dpa_size" 2>/dev/null
	echo ram > "$CXL/$dec/mode" 2>/dev/null
	echo "$sz" > "$CXL/$dec/dpa_size"
	echo "$dec" > "$R/target0"
	echo "$region"
}
delete_regions() {
	local r
	for r in $(ls $CXL 2>/dev/null | grep '^region'); do
		echo 0 > "$CXL/$r/commit" 2>/dev/null
		echo "$r" > "$CXL/$1/delete_region" 2>/dev/null
	done
}
rebind_and_wait() { # <mem>  -> echoes fresh decoder, empty on timeout
	local mem=$1 i dec
	echo "$mem" > /sys/bus/cxl/drivers/cxl_mem/bind 2>/dev/null
	for i in $(seq 1 60); do
		dec=$(ep_decoder_for_mem "$mem")
		[ -n "$dec" ] && { echo "$dec"; return; }
		sleep 0.5
	done
}

echo "# t9 phase 2: switch-unbind cascade"

rd=$(root_decoder_bi)
mem=$(first_mem)
dec=$(ep_decoder_for_mem "$mem")
ep=$(dirname "$(readlink -f "$CXL/$dec")"); ep=$(basename "$ep")
classify_switch_ports
if [ "$NSWITCH" = 2 ] && [ -n "$OUTER" ] && [ -n "$INNER" ]; then
	ok "two switch ports classified (outer=$OUTER inner=$INNER)"
else
	fail "two switch ports classified (n=$NSWITCH o=$OUTER i=$INNER)"
	echo "Bail out! unexpected topology"; exit 1
fi
[ -n "$rd" ] && [ -n "$mem" ] && [ -n "$dec" ] || \
	{ echo "Bail out! prereq missing"; exit 1; }

# The main suite may leave its region behind; start clean.
delete_regions "$rd"
region=$(create_region "$rd" "$dec")
if [ -n "$region" ] && echo 1 > "$CXL/$region/commit" 2>/dev/null && \
   [ "$(cat "$CXL/$dec/bi")" = 1 ]; then
	ok "pre-unbind: committed HDM-DB region, bi=1"
else
	fail "pre-unbind: committed HDM-DB region, bi=1"
	echo "Bail out! baseline broken"; exit 1
fi

# ---- deterministic cascade -----------------------------------------
dmesg -C
echo "$OUTER" > /sys/bus/cxl/drivers/cxl_port/unbind 2>/dev/null
# The subtree teardown (inner port, endpoint, region, BI dealloc) runs
# synchronously in the unbind write; give sysfs a short settle anyway.
for i in $(seq 1 20); do
	[ -d "$CXL/$ep" ] || break
	sleep 0.1
done
[ ! -d "$CXL/$ep" ] && ok "cascade: endpoint port gone" \
	|| fail "cascade: endpoint port gone"
[ ! -d "$CXL/$INNER" ] && ok "cascade: inner switch port gone" \
	|| fail "cascade: inner switch port gone"
# The region device survives target loss; it must be decommitted.
expect_eq "cascade: region decommitted" \
	"$(cat "$CXL/$region/commit" 2>/dev/null)" 0
if dmesg | grep -q "BI requests disabled"; then
	ok "cascade: BI disabled during teardown"
else
	fail "cascade: BI disabled during teardown"
fi

# The memdev detach is a workqueue item; the same pass runs
# cxl_detach_ep, which finds the outer port empty + driverless and
# reaps it (delete_switch_port).
for i in $(seq 1 100); do
	[ -e "$CXL/$mem/driver" ] || break
	sleep 0.2
done
[ ! -e "$CXL/$mem/driver" ] && ok "cascade: memdev detached" \
	|| fail "cascade: memdev detached"
for i in $(seq 1 100); do
	[ -d "$CXL/$OUTER" ] || break
	sleep 0.2
done
[ ! -d "$CXL/$OUTER" ] && ok "cascade: empty outer port reaped" \
	|| fail "cascade: empty outer port reaped"

# LIFO proof in the log: the dealloc walk's disable precedes the
# memdev disconnect from the surviving ancestors.
dis=$(dmesg | grep -n "BI requests disabled" | head -1 | cut -d: -f1)
dc=$(dmesg | grep -n "disconnect" | head -1 | cut -d: -f1)
if [ -n "$dis" ] && [ -n "$dc" ] && [ "$dis" -lt "$dc" ]; then
	ok "cascade: BI disable precedes memdev disconnect"
else
	fail "cascade: BI disable precedes memdev disconnect (dis=$dis dc=$dc)"
fi
dmesg | grep -q "BI setup failed" && fail "cascade: no 'BI setup failed'" \
	|| ok "cascade: no 'BI setup failed'"

# ---- rebuild -------------------------------------------------------
# cxl_mem rebind re-enumerates: probe_dport() re-adds the outer
# port's dports (nr_dports reset on rebind), one-time setup re-maps
# decoders and BI RT, and the inner/endpoint ports come back under
# fresh names.
dec2=$(rebind_and_wait "$mem")
if [ -n "$dec2" ]; then
	ok "rebuild: endpoint decoder back after rebind ($dec2)"
	region=$(create_region "$rd" "$dec2")
	if [ -n "$region" ] && echo 1 > "$CXL/$region/commit" 2>/dev/null; then
		expect_eq "rebuild: fresh HDM-DB commit, bi=1" \
			"$(cat "$CXL/$dec2/bi")" 1
	else
		fail "rebuild: fresh HDM-DB commit, bi=1"
	fi
	delete_regions "$rd"
else
	fail "rebuild: endpoint decoder back after rebind"
fi

# ---- cascade under churn -------------------------------------------
# Region create/commit/destroy churn plus a decoder-attribute reader,
# with the outer-port unbind landing mid-flight: races the cascade
# against an in-flight cxl_bi_setup walk (region rwsem serialization)
# and against attribute readers (endpoint device lock).
classify_switch_ports
if [ "$NSWITCH" = 2 ] && [ -n "$OUTER" ]; then
	flag=/tmp/swc-flag.$$
	touch "$flag"
	( while [ -e "$flag" ]; do
		cat $CXL/decoder*/bi $CXL/decoder*/target_type \
		    $CXL/decoder0.*/cap_bi >/dev/null 2>&1
	  done ) &
	reader=$!
	( while [ -e "$flag" ]; do
		d=$(ep_decoder_for_mem "$mem"); [ -n "$d" ] || break
		r=$(create_region "$rd" "$d" 2>/dev/null)
		[ -n "$r" ] && echo 1 > "$CXL/$r/commit" 2>/dev/null
		delete_regions "$rd"
	  done ) &
	churn=$!
	sleep 1.2
	echo "$OUTER" > /sys/bus/cxl/drivers/cxl_port/unbind 2>/dev/null
	for i in $(seq 1 100); do
		[ -e "$CXL/$mem/driver" ] || break
		sleep 0.2
	done
	rm -f "$flag"
	wait "$reader" "$churn" 2>/dev/null
	[ ! -e "$CXL/$mem/driver" ] && ok "race: cascade under churn completed" \
		|| fail "race: cascade under churn completed"
	delete_regions "$rd"
	dec3=$(rebind_and_wait "$mem")
	region=$(create_region "$rd" "$dec3")
	if [ -n "$dec3" ] && [ -n "$region" ] && \
	   echo 1 > "$CXL/$region/commit" 2>/dev/null && \
	   [ "$(cat "$CXL/$dec3/bi")" = 1 ]; then
		ok "race: rebuild + commit after storm (bi=1)"
	else
		fail "race: rebuild + commit after storm"
	fi
else
	fail "race: topology reclassify after rebuild"
fi

# ---- hygiene -------------------------------------------------------
for pat in "BUG:" "Oops" "kernel NULL pointer" "WARNING:" \
	   "possible circular" "inconsistent lock" "use-after-free"; do
	if dmesg | grep -q "$pat"; then
		fail "dmesg clean of '$pat'"
		dmesg | grep "$pat" | head -2 | sed 's/^/# /'
	else
		ok "dmesg clean of '$pat'"
	fi
done

exit $((FAIL != 0))
