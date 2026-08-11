#!/bin/sh /etc/rc.common

START=12
STOP=88

ZRAM_SIZE=$((96 * 1024 * 1024))
ZRAM_DEV=/dev/zram0
ZRAM_SYS=/sys/block/zram0

set_algorithm() {
	local algorithms algorithm

	algorithms="$(cat "$ZRAM_SYS/comp_algorithm" 2>/dev/null)"
	for algorithm in lz4 lzo-rle lzo; do
		case " $algorithms " in
			*" $algorithm "*)
				echo "$algorithm" >"$ZRAM_SYS/comp_algorithm"
				return
				;;
		esac
	done
}

start() {
	grep -q "^$ZRAM_DEV " /proc/swaps 2>/dev/null && return 0

	modprobe zram num_devices=1 >/dev/null 2>&1 || true
	[ -e "$ZRAM_SYS/disksize" ] || {
		logger -t pzl8-memory "ZRAM driver unavailable; compressed swap was not enabled"
		return 0
	}

	echo 1 >"$ZRAM_SYS/reset" 2>/dev/null || true
	set_algorithm
	echo "$ZRAM_SIZE" >"$ZRAM_SYS/disksize" || return 1
	mkswap "$ZRAM_DEV" >/dev/null 2>&1 || return 1
	swapon -p 100 "$ZRAM_DEV" >/dev/null 2>&1 || return 1
	logger -t pzl8-memory "enabled 96 MiB ZRAM swap"
}

stop() {
	grep -q "^$ZRAM_DEV " /proc/swaps 2>/dev/null &&
		swapoff "$ZRAM_DEV" >/dev/null 2>&1
	[ -e "$ZRAM_SYS/reset" ] && echo 1 >"$ZRAM_SYS/reset"
}
