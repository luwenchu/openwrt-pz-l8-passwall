#!/bin/sh

. /lib/functions/system.sh

pzl8_board_compatible() {
	tr '\000' '\n' < /proc/device-tree/compatible |
		grep -m1 -E '^(cmcc,pzl8|cmcc,rax3000qy|redmi,ax3000-m79|redmi,ax3000-m81|cucc,vs010|rg,ma3063|axfh3)$'
}

pzl8_current_rootfs() {
	sed -n 's/.*ubi.mtd=\([^ ]*\).*/\1/p' /proc/cmdline |
		head -n 1
}

pzl8_upgrade_target() {
	local current target0 target1

	current="$(pzl8_current_rootfs)"
	[ -n "$current" ] || current=rootfs

	target0="$(cat /proc/boot_info/bootconfig0/rootfs/upgradepartition 2>/dev/null)"
	target1="$(cat /proc/boot_info/bootconfig1/rootfs/upgradepartition 2>/dev/null)"
	[ -n "$target0" ] && [ "$target0" = "$target1" ] || {
		echo "Bootconfig rootfs upgrade targets are unavailable or inconsistent" >&2
		return 1
	}

	case "$target0" in
		rootfs|rootfs_1) ;;
		*)
			echo "Unsupported rootfs upgrade target: $target0" >&2
			return 1
			;;
	esac

	[ "$target0" != "$current" ] || {
		echo "Refusing to overwrite active rootfs slot: $current" >&2
		return 1
	}
	[ -n "$(find_mtd_index "$target0")" ] || {
		echo "Rootfs upgrade target is missing from MTD: $target0" >&2
		return 1
	}

	echo "$target0"
}

pzl8_prepare_bootconfig() {
	local bootconfig primary

	for bootconfig in bootconfig0 bootconfig1; do
		primary="$(cat "/proc/boot_info/$bootconfig/rootfs/primaryboot" 2>/dev/null)"
		case "$primary" in
			0|1) ;;
			*)
				echo "Invalid $bootconfig rootfs primaryboot value: $primary" >&2
				return 1
				;;
		esac
		echo $((primary ^ 1)) > \
			"/proc/boot_info/$bootconfig/rootfs/primaryboot" || return 1
		cat "/proc/boot_info/$bootconfig/getbinary_bootconfig" \
			> "/tmp/$bootconfig.bin" || return 1
		[ -s "/tmp/$bootconfig.bin" ] || return 1
	done
}

pzl8_write_bootconfig() {
	local bootconfig mtdname mtdnum writesize

	bootconfig="$1"
	mtdname="$2"
	mtdnum="$(find_mtd_index "$mtdname")"
	[ -n "$mtdnum" ] || return 1
	writesize="$(cat "/sys/class/mtd/mtd$mtdnum/writesize")"

	dd if="/tmp/$bootconfig.bin" bs="$writesize" conv=sync 2>/dev/null |
		mtd -e "/dev/mtd$mtdnum" write - "/dev/mtd$mtdnum"
}

pzl8_commit_boot_slot() {
	pzl8_prepare_bootconfig || return 1
	pzl8_write_bootconfig bootconfig1 "0:BOOTCONFIG1" || return 1
	pzl8_write_bootconfig bootconfig0 "0:BOOTCONFIG" || return 1
	rm -f /tmp/bootconfig0.bin /tmp/bootconfig1.bin
}

pzl8_verify_upgrade_ubi() {
	local target ubidev

	target="$1"
	ubidev="$(nand_find_ubi "$target")"
	[ -n "$ubidev" ] || return 1
	[ -n "$(nand_find_volume "$ubidev" kernel)" ] || return 1
	[ -n "$(nand_find_volume "$ubidev" rootfs)" ] || return 1
}

platform_check_image() {
	local board

	board="$(pzl8_board_compatible)" || {
		echo "Sysupgrade is not supported on this board" >&2
		return 1
	}
	nand_do_platform_check "$board" "$1"
}

platform_do_upgrade() {
	local board target

	board="$(pzl8_board_compatible)" || {
		echo "Sysupgrade is not supported on this board" >&2
		return 1
	}
	target="$(pzl8_upgrade_target)" || return 1

	echo "Writing firmware to inactive rootfs slot: $target"
	CI_UBIPART="$target"
	CI_KERNPART="kernel"

	sync
	nand_do_flash_file "$1" || {
		echo "Failed to write firmware to inactive rootfs slot: $target" >&2
		return 1
	}
	pzl8_verify_upgrade_ubi "$target" || {
		echo "Inactive rootfs slot verification failed: $target" >&2
		return 1
	}
	nand_do_restore_config || return 1
	pzl8_commit_boot_slot || {
		echo "Firmware was written, but boot slot switching failed" >&2
		return 1
	}
	sync
	echo "Sysupgrade completed; next boot will use $target"
}
