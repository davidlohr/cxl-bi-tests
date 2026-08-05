#!/bin/bash
# t17 guest-side helpers, sourced over ssh by topos/t17-hotplug.sh.
# Devices are identified by memdev serial (sn=... on the qemu side):
# hotplug recycles memN names, so memN is never stable across a cycle.

CXL=/sys/bus/cxl/devices

mem_of_sn() { # 0xNN -> memN
	local m
	for m in $CXL/mem*; do
		[ -d "$m" ] || continue
		[ "$(cat "$m/serial" 2>/dev/null)" = "$1" ] && \
			{ basename "$m"; return; }
	done
}

dec_of_sn() { # 0xNN -> endpoint decoderX.0
	local mem ep
	mem=$(mem_of_sn "$1") || return
	[ -n "$mem" ] || return
	for ep in $CXL/endpoint*; do
		[ -d "$ep" ] || continue
		[ "$(basename "$(readlink -f "$ep/uport")")" = "$mem" ] && \
			{ basename "$(ls -d "$ep"/decoder*.0 | head -1)"; return; }
	done
}

# mkreg_sn <sn>: 1-way 256M HDM-DB region on the device with <sn>.
# Prints "regionN bi=<0|1>" on success. Only one region at a time: the
# switch USP doesn't have enough decoders for two disjoint routings.
mkreg_sn() {
	local d r sz=$((256 << 20))
	d=$(dec_of_sn "$1")
	[ -n "$d" ] || { echo "no-decoder"; return 1; }
	r=$(cat "$CXL/decoder0.0/create_ram_region") || return 1
	echo "$r" > "$CXL/decoder0.0/create_ram_region" || return 1
	echo 256 > "$CXL/$r/interleave_granularity"
	echo 1   > "$CXL/$r/interleave_ways"
	echo $sz > "$CXL/$r/size"
	echo 0   > "$CXL/$d/dpa_size" 2>/dev/null
	echo ram > "$CXL/$d/mode" 2>/dev/null
	echo $sz > "$CXL/$d/dpa_size" || return 1
	echo "$d" > "$CXL/$r/target0" || return 1
	echo 1 > "$CXL/$r/commit" || return 1
	echo "$r bi=$(cat "$CXL/$d/back_invalidate")"
}

rmreg_all() {
	local r
	for r in $(ls $CXL | grep '^region'); do
		echo 0 > "$CXL/$r/commit" 2>/dev/null
		echo "$r" > "$CXL/decoder0.0/delete_region" 2>/dev/null
	done
}
