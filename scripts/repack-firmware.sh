#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/pins.env"

base="$repo_root/base/$BASE_FIRMWARE"
work="$repo_root/work"
volumes="$work/volumes"
rootfs="$work/rootfs"
ubi_root="$work/rootfs-data"
output="$repo_root/output"
package_cache="$work/package-cache"
firmware_name="PZL8-2025-01-03-passwall-nft-xray-rootfs-factory.bin"

echo "$BASE_SHA256  $base" | sha256sum -c -
test -d "$package_cache"
rm -rf "$volumes" "$rootfs" "$ubi_root" "$output"
mkdir -p "$volumes" "$ubi_root/upper" "$ubi_root/work" "$output"

python3 "$repo_root/scripts/extract_ubi.py" "$base" "$volumes"
test "$(stat -c %s "$volumes/kernel.bin")" -eq 3921808
test "$(stat -c %s "$volumes/rootfs.squashfs")" -eq 29874708

sudo unsquashfs -d "$rootfs" "$volumes/rootfs.squashfs" >/dev/null
sudo python3 "$repo_root/scripts/install_ipks.py" \
  --ipk-root "$package_cache" \
  --base-status "$rootfs/usr/lib/opkg/status" \
  --root "$rootfs" \
  --remove-package mosdns \
  --remove-package luci-app-mosdns \
  --remove-package luci-i18n-mosdns-zh-cn \
  --remove-package v2dat \
  luci-app-passwall luci-i18n-passwall-zh-cn xray-core

cat > "$work/openwrt_release" <<'EOF'
DISTRIB_ID='PZL8'
DISTRIB_RELEASE='23.05-SNAPSHOT'
DISTRIB_REVISION='r0-6dee7e355-passwall'
DISTRIB_TARGET='ipq50xx/ipq50xx_32'
DISTRIB_ARCH='arm_cortex-a7_neon-vfpv4'
DISTRIB_DESCRIPTION='PZL8 23.05-SNAPSHOT r0-6dee7e355 PassWall'
DISTRIB_TAINTS='no-all busybox override'
EOF
cat > "$work/banner" <<'EOF'
 ____  ______ _      ___
|  _ \|__  /| |    / _ \
| |_) | / / | |   | (_) |
|  __/ / /_ | |___ > _ <
|_|   /____||_____/|_| |_|
----------------------------
PZL8 23.05-SNAPSHOT PassWall
----------------------------
EOF
cat > "$work/99-pzl8-passwall-rootfs" <<'EOF'
#!/bin/sh

cp -f /rom/etc/openwrt_release /etc/openwrt_release
uci -q set system.@system[0].hostname='PZL8'
uci -q commit system

[ ! -s /etc/config/passwall ] &&
  cp -f /usr/share/passwall/0_default_config /etc/config/passwall
uci -q set passwall.@global[0].enabled='0'
uci -q commit passwall
/etc/init.d/passwall disable >/dev/null 2>&1 || true

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
exit 0
EOF
cat > "$work/platform.sh" <<'EOF'
#!/bin/sh
. /lib/functions/system.sh

platform_check_image() {
	return 0
}

platform_do_upgrade() {
	local board part

	board="$(
		tr '\000' '\n' < /proc/device-tree/compatible |
			grep -m1 -E '^(cmcc,pzl8|cmcc,rax3000qy|redmi,ax3000-m79|redmi,ax3000-m81|cucc,vs010|rg,ma3063|axfh3)$'
	)"

	case "$board" in
		cmcc,pzl8|\
		cmcc,rax3000qy|\
		redmi,ax3000-m79|\
		redmi,ax3000-m81|\
		cucc,vs010|\
		rg,ma3063|\
		axfh3)
			part="$(sed -n 's/.*ubi.mtd=\([^ ]*\).*/\1/p' /proc/cmdline)"
			[ -n "$part" ] || part=rootfs
			CI_UBIPART="$part"
			CI_KERNPART="kernel"
			nand_do_upgrade "$1"
			;;
		*)
			echo "Sysupgrade is not supported on your board($board) yet."
			return 1
			;;
	esac
}
EOF
sudo install -D -m 0644 "$work/openwrt_release" "$rootfs/etc/openwrt_release"
sudo install -D -m 0644 "$work/banner" "$rootfs/etc/banner"
sudo install -D -m 0755 "$work/99-pzl8-passwall-rootfs" \
  "$rootfs/etc/uci-defaults/99-pzl8-passwall-rootfs"
sudo install -D -m 0755 "$work/platform.sh" "$rootfs/lib/upgrade/platform.sh"

require_file() {
  if [ ! -f "$1" ]; then
    echo "Required firmware file is missing: $1" >&2
    exit 1
  fi
}

require_file "$rootfs/usr/share/passwall/0_default_config"
require_file "$rootfs/etc/uci-defaults/luci-passwall"
require_file "$rootfs/etc/uci-defaults/99-pzl8-passwall-rootfs"
require_file "$rootfs/usr/lib/lua/luci/controller/passwall.lua"
require_file "$rootfs/lib/upgrade/platform.sh"

grep -Fq "tr '\\000' '\\n' < /proc/device-tree/compatible" \
  "$rootfs/lib/upgrade/platform.sh"
grep -Fq "cmcc,pzl8" "$rootfs/lib/upgrade/platform.sh"

if [ -e "$rootfs/usr/bin/mosdns" ] || [ -e "$rootfs/usr/bin/v2dat" ]; then
  echo "MosDNS executables were not removed before SquashFS packing" >&2
  exit 1
fi

if ! grep -Eq "option enabled ['\"]0['\"]" \
  "$rootfs/usr/share/passwall/0_default_config"; then
  echo "PassWall default template is not disabled" >&2
  exit 1
fi

xray_path="$(find "$rootfs/usr" -type f -name xray -print -quit)"
if [ -z "$xray_path" ]; then
  echo "Xray executable is missing from the rootfs" >&2
  exit 1
fi
file "$xray_path" | tee "$work/xray-file.txt"
if ! grep -Eq 'ELF 32-bit.*ARM' "$work/xray-file.txt"; then
  echo "Xray is not an ARM 32-bit executable" >&2
  exit 1
fi

sudo mksquashfs "$rootfs" "$work/rootfs-passwall.squashfs" \
  -comp xz -Xbcj arm -b 256K -no-xattrs -noappend >/dev/null
rootfs_size="$(stat -c %s "$work/rootfs-passwall.squashfs")"
rootfs_lebs=$(((rootfs_size + 126975) / 126976))
rootfs_vol_size=$((rootfs_lebs * 126976))
if [ "$rootfs_lebs" -gt 246 ]; then
  echo "PassWall SquashFS exceeds the 246 LEB rootfs budget: $rootfs_size" >&2
  exit 1
fi

mkfs.ubifs \
  -r "$ubi_root" \
  -o "$work/rootfs_data.ubifs" \
  -m 2048 -e 126976 -c 173 -x zlib

overlay_size="$(stat -c %s "$work/rootfs_data.ubifs")"
max_overlay=$((173 * 126976))
if [ "$overlay_size" -ge "$max_overlay" ]; then
  echo "rootfs_data image is too large: $overlay_size >= $max_overlay" >&2
  exit 1
fi

rootfs_data_lebs=$(((overlay_size + 126975) / 126976))
if [ "$rootfs_data_lebs" -lt 9 ]; then
  rootfs_data_lebs=9
fi

cat > "$work/ubinize.cfg" <<EOF
[kernel]
mode=ubi
image=$volumes/kernel.bin
vol_id=0
vol_type=dynamic
vol_name=kernel
vol_size=3936256

[rootfs]
mode=ubi
image=$work/rootfs-passwall.squashfs
vol_id=1
vol_type=dynamic
vol_name=rootfs
vol_size=$rootfs_vol_size

[rootfs_data]
mode=ubi
image=$work/rootfs_data.ubifs
vol_id=2
vol_type=dynamic
vol_name=rootfs_data
vol_size=$((rootfs_data_lebs * 126976))
vol_flags=autoresize
EOF

ubinize -o "$output/$firmware_name" -m 2048 -p 128KiB -s 2048 \
  "$work/ubinize.cfg"

firmware_size="$(stat -c %s "$output/$firmware_name")"
if [ "$firmware_size" -gt $((58 * 1024 * 1024)) ]; then
  echo "factory image exceeds the 58 MiB rootfs MTD partition" >&2
  exit 1
fi

python3 "$repo_root/scripts/extract_ubi.py" \
  "$output/$firmware_name" "$work/verify-volumes"
cmp "$volumes/kernel.bin" "$work/verify-volumes/kernel.bin"
if cmp -s "$volumes/rootfs.squashfs" "$work/verify-volumes/rootfs.squashfs"; then
  echo "Repacked rootfs unexpectedly matches the base rootfs" >&2
  exit 1
fi

unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
  usr/share/passwall/0_default_config >/dev/null
unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
  usr/bin/xray > "$work/verify-xray"
file "$work/verify-xray" | tee "$work/verify-xray-file.txt"
grep -Eq 'ELF 32-bit.*ARM' "$work/verify-xray-file.txt"

if unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
  usr/bin/mosdns >/dev/null 2>&1; then
  echo "MosDNS was not removed from the repacked rootfs" >&2
  exit 1
fi
if unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
  usr/bin/v2dat >/dev/null 2>&1; then
  echo "MosDNS v2dat helper was not removed from the repacked rootfs" >&2
  exit 1
fi

cp "$work/passwall-packages.txt" "$output/passwall-packages.txt"
(
  cd "$output"
  sha256sum "$firmware_name" > sha256sums
)

cat > "$output/build-manifest.txt" <<EOF
base_file=$BASE_FIRMWARE
base_sha256=$BASE_SHA256
output_file=$firmware_name
output_sha256=$(sha256sum "$output/$firmware_name" | awk '{print $1}')
output_size=$firmware_size
kernel_size=$(stat -c %s "$volumes/kernel.bin")
rootfs_size=$rootfs_size
rootfs_lebs=$rootfs_lebs
rootfs_volume_size=$rootfs_vol_size
rootfs_data_ubifs_size=$overlay_size
rootfs_data_min_lebs=$rootfs_data_lebs
rootfs_data_autoresize=yes
architecture=arm_cortex-a7_neon-vfpv4
kernel_preserved=yes
rootfs_repacked=yes
passwall_location=squashfs
removed_packages=mosdns,luci-app-mosdns,luci-i18n-mosdns-zh-cn,v2dat
passwall_mode=nftables
passwall_core=xray
passwall_default_enabled=no
display_name=PZL8
sysupgrade_board_parser=fixed
xray_file=$(cat "$work/xray-file.txt")
EOF
