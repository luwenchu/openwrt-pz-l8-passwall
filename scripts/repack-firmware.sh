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
firmware_name="PZL8-2026-08-11-passwall-nft-xray-rootfs-factory.bin"
uboot_recovery_name="PZL8-2026-08-11-passwall-nft-xray-uboot-recovery.bin"

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
  --remove-package isc-dhcp-relay-ipv6 \
  --remove-package quagga-watchquagga \
  --remove-package quagga-vtysh \
  --remove-package quagga-ripd \
  --remove-package quagga-zebra \
  --remove-package quagga-libzebra \
  --remove-package quagga \
  --remove-package luci-app-zerotier \
  --remove-package luci-i18n-zerotier-zh-cn \
  --remove-package zerotier \
  --remove-package luci-app-ttyd \
  --remove-package luci-i18n-ttyd-zh-cn \
  --remove-package ttyd \
  --remove-package luci-app-ksmbd \
  --remove-package luci-i18n-ksmbd-zh-cn \
  --remove-package ksmbd-server \
  luci-app-passwall luci-i18n-passwall-zh-cn xray-core

cat > "$work/openwrt_release" <<'EOF'
DISTRIB_ID='PZL8'
DISTRIB_RELEASE='2026.08.11'
DISTRIB_REVISION='子安信息科技'
DISTRIB_TARGET='ipq50xx/ipq50xx_32'
DISTRIB_ARCH='arm_cortex-a7_neon-vfpv4'
DISTRIB_DESCRIPTION='子安信息科技'
DISTRIB_TAINTS='no-all busybox override'
EOF
cat > "$work/banner" <<'EOF'
 ____  ______ _      ___
|  _ \|__  /| |    / _ \
| |_) | / / | |   | (_) |
|  __/ / /_ | |___ > _ <
|_|   /____||_____/|_| |_|
----------------------------
PZL8 2026.08.11
子安信息科技
----------------------------
EOF
grep -Fq "DISTRIB_RELEASE='2026.08.11'" "$work/openwrt_release"
grep -Fq "DISTRIB_REVISION='子安信息科技'" "$work/openwrt_release"
grep -Fq "DISTRIB_DESCRIPTION='子安信息科技'" "$work/openwrt_release"
grep -Fq 'PZL8 2026.08.11' "$work/banner"
grep -Fq '子安信息科技' "$work/banner"
cat > "$work/99-pzl8-passwall-rootfs" <<'EOF'
#!/bin/sh

cp -f /rom/etc/openwrt_release /etc/openwrt_release
uci -q set system.@system[0].hostname='PZL8'
uci -q commit system

uci -q set wireless.wifinet0.ssid='PZL8_2.4G_0'
uci -q set wireless.wifinet1.ssid='PZL8_5G_1'
uci -q commit wireless

[ ! -s /etc/config/passwall ] &&
  cp -f /usr/share/passwall/0_default_config /etc/config/passwall
uci -q set passwall.@global[0].enabled='0'
uci -q commit passwall
/etc/init.d/passwall disable >/dev/null 2>&1 || true

if ! grep -Fq '/usr/sbin/pzl8-postboot' /etc/rc.local; then
  awk '
    /^exit 0$/ && !added {
      print "/usr/sbin/pzl8-postboot </dev/null >/tmp/pzl8-postboot.out 2>&1 &"
      added = 1
    }
    { print }
  ' /etc/rc.local >/tmp/rc.local.pzl8 &&
    cat /tmp/rc.local.pzl8 >/etc/rc.local
  rm -f /tmp/rc.local.pzl8
fi
chmod 0755 /etc/rc.local

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
exit 0
EOF
sudo install -D -m 0644 "$work/openwrt_release" "$rootfs/etc/openwrt_release"
sudo install -D -m 0644 "$work/banner" "$rootfs/etc/banner"
sudo install -D -m 0755 "$work/99-pzl8-passwall-rootfs" \
  "$rootfs/etc/uci-defaults/99-pzl8-passwall-rootfs"
sudo install -D -m 0755 "$repo_root/scripts/pzl8-platform.sh" \
  "$rootfs/lib/upgrade/platform.sh"
sudo install -D -m 0644 "$repo_root/scripts/xray-legacy-compat.lua" \
  "$rootfs/usr/share/passwall/xray_legacy_compat.lua"
sudo install -D -m 0755 "$repo_root/scripts/pzl8-postboot.sh" \
  "$rootfs/usr/sbin/pzl8-postboot"
if ! grep -Fq '/usr/sbin/pzl8-postboot' "$rootfs/etc/rc.local"; then
  awk '
    /^exit 0$/ && !added {
      print "/usr/sbin/pzl8-postboot </dev/null >/tmp/pzl8-postboot.out 2>&1 &"
      added = 1
    }
    { print }
  ' "$rootfs/etc/rc.local" >"$work/rc.local"
  sudo install -m 0755 "$work/rc.local" "$rootfs/etc/rc.local"
fi
sudo chmod 0755 "$rootfs/etc/rc.local"
sudo python3 "$repo_root/scripts/patch-passwall-xray-legacy.py" \
  "$rootfs/usr/share/passwall/app.sh"
sudo python3 "$repo_root/scripts/patch-passwall-nft-reject.py" \
  "$rootfs/usr/share/passwall/nftables.sh"

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
require_file "$rootfs/usr/share/passwall/app.sh"
require_file "$rootfs/usr/share/passwall/xray_legacy_compat.lua"
require_file "$rootfs/usr/share/passwall/nftables.sh"
require_file "$rootfs/usr/sbin/pzl8-postboot"
require_file "$rootfs/etc/rc.local"

grep -Fq 'grep -a -q "$board" /proc/device-tree/compatible' \
  "$rootfs/lib/upgrade/platform.sh"
grep -Fq "cmcc,pzl8" "$rootfs/lib/upgrade/platform.sh"
grep -Fq 'target="$(pzl8_upgrade_target)"' "$rootfs/lib/upgrade/platform.sh"
grep -Fq 'CI_UBIPART="$target"' "$rootfs/lib/upgrade/platform.sh"
grep -Fq 'pzl8_commit_boot_slot' "$rootfs/lib/upgrade/platform.sh"
grep -Fq '0:BOOTCONFIG1' "$rootfs/lib/upgrade/platform.sh"
grep -Fq '0:BOOTCONFIG' "$rootfs/lib/upgrade/platform.sh"
if grep -Eq '(^|[[:space:]])(tr|head)([[:space:]]|$)' \
  "$rootfs/lib/upgrade/platform.sh"; then
  echo "RAMFS-unsafe tr/head dependency remains in platform.sh" >&2
  exit 1
fi
if grep -Fq 'nand_do_upgrade "$1"' "$rootfs/lib/upgrade/platform.sh"; then
  echo "Unsafe active-slot nand_do_upgrade call remains in platform.sh" >&2
  exit 1
fi
sh -n "$rootfs/lib/upgrade/platform.sh"
grep -Fq "wireless.wifinet0.ssid='PZL8_2.4G_0'" \
  "$rootfs/etc/uci-defaults/99-pzl8-passwall-rootfs"
grep -Fq "wireless.wifinet1.ssid='PZL8_5G_1'" \
  "$rootfs/etc/uci-defaults/99-pzl8-passwall-rootfs"
grep -Fq '/usr/sbin/pzl8-postboot </dev/null' \
  "$rootfs/etc/uci-defaults/99-pzl8-passwall-rootfs"
grep -Fq '/usr/sbin/pzl8-postboot </dev/null' "$rootfs/etc/rc.local"
grep -Fq '/etc/init.d/passwall start </dev/null' \
  "$rootfs/usr/sbin/pzl8-postboot"
sh -n "$rootfs/usr/sbin/pzl8-postboot"
sh -n "$rootfs/etc/rc.local"
test "$(grep -Fc "xray_legacy_compat.lua" \
  "$rootfs/usr/share/passwall/app.sh")" -eq 1
grep -Fq "if \$XRAY_BIN version 2>/dev/null | head -n1 | grep -q '^Xray 1\\.'; then" \
  "$rootfs/usr/share/passwall/app.sh"
sh -n "$rootfs/usr/share/passwall/app.sh"
if grep -Fq "counter reject" "$rootfs/usr/share/passwall/nftables.sh"; then
  echo "Unsupported nftables reject action remains in PassWall" >&2
  exit 1
fi
grep -Fq "counter drop" "$rootfs/usr/share/passwall/nftables.sh"
sh -n "$rootfs/usr/share/passwall/nftables.sh"

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

firmware_size_hex="$(printf '0x%08x' "$firmware_size")"
recovery_chunk_size=$((7 * 1024 * 1024))
recovery_chunk_dir="$work/pzl8-uboot-recovery-chunks"
rm -rf "$recovery_chunk_dir"
mkdir -p "$recovery_chunk_dir"
split -b "$recovery_chunk_size" -d -a 2 \
  "$output/$firmware_name" "$recovery_chunk_dir/firmware-"

recovery_extract_commands="$work/pzl8-uboot-extract-commands"
recovery_its_nodes="$work/pzl8-uboot-firmware-nodes.its"
: > "$recovery_extract_commands"
: > "$recovery_its_nodes"
recovery_chunk_count=0
recovery_payload_size=0
recovery_offset=0

for recovery_chunk in "$recovery_chunk_dir"/firmware-[0-9][0-9]; do
  recovery_suffix="${recovery_chunk##*-}"
  recovery_node="firmware-$recovery_suffix"
  recovery_chunk_gzip="$recovery_chunk.gz"
  recovery_chunk_uncompressed_size="$(stat -c %s "$recovery_chunk")"
  if [ "$recovery_chunk_uncompressed_size" -gt $((8 * 1024 * 1024)) ]; then
    echo "U-Boot recovery chunk exceeds the 8 MiB imxtract limit" >&2
    exit 1
  fi

  gzip -9 -n -c "$recovery_chunk" > "$recovery_chunk_gzip"
  gzip -t "$recovery_chunk_gzip"
  recovery_chunk_payload_size="$(stat -c %s "$recovery_chunk_gzip")"
  recovery_chunk_crc32="$(python3 -c \
    'import pathlib, sys, zlib; print(f"{zlib.crc32(pathlib.Path(sys.argv[1]).read_bytes()) & 0xffffffff:08x}")' \
    "$recovery_chunk_gzip")"
  recovery_chunk_address="$(printf '0x%08x' $((0x48000000 + recovery_offset)))"

  cat >> "$recovery_extract_commands" <<EOF
echo "Extracting PZL8 UBI chunk $recovery_suffix"
imxtract "\$fitaddr" "$recovery_node" "$recovery_chunk_address" || exit 1
EOF

  cat >> "$recovery_its_nodes" <<EOF
    $recovery_node {
      description = "PZL8 PassWall UBI chunk $recovery_suffix";
      data = /incbin/("$recovery_chunk_gzip");
      type = "firmware";
      arch = "arm";
      compression = "gzip";
      hash@1 {
        value = <0x$recovery_chunk_crc32>;
        algo = "crc32";
      };
    };
EOF

  recovery_chunk_count=$((recovery_chunk_count + 1))
  recovery_payload_size=$((recovery_payload_size + recovery_chunk_payload_size))
  recovery_offset=$((recovery_offset + recovery_chunk_uncompressed_size))
done

test "$recovery_chunk_count" -gt 1
test "$recovery_offset" -eq "$firmware_size"

sed "s/@FIRMWARE_SIZE_HEX@/$firmware_size_hex/g" \
  "$repo_root/scripts/pzl8-uboot-recovery.scr.in" \
  > "$work/pzl8-uboot-recovery.scr.template"
awk -v commands="$recovery_extract_commands" '
  $0 == "@FIRMWARE_EXTRACT_COMMANDS@" {
    while ((getline line < commands) > 0)
      print line
    close(commands)
    next
  }
  { print }
' "$work/pzl8-uboot-recovery.scr.template" \
  > "$work/pzl8-uboot-recovery.scr"

fit_timestamp="${SOURCE_DATE_EPOCH:-$(git -C "$repo_root" log -1 --format=%ct)}"
script_crc32="$(python3 -c \
  'import pathlib, sys, zlib; print(f"{zlib.crc32(pathlib.Path(sys.argv[1]).read_bytes()) & 0xffffffff:08x}")' \
  "$work/pzl8-uboot-recovery.scr")"

test "$(grep -c '^nand erase ' "$work/pzl8-uboot-recovery.scr")" -eq 2
test "$(grep -c '^nand write ' "$work/pzl8-uboot-recovery.scr")" -eq 2
test "$(grep -c '^imxtract ' "$work/pzl8-uboot-recovery.scr")" \
  -eq "$recovery_chunk_count"
grep -Fq "nand erase 0x00900000 0x03a00000" \
  "$work/pzl8-uboot-recovery.scr"
grep -Fq "nand erase 0x04300000 0x03a00000" \
  "$work/pzl8-uboot-recovery.scr"
grep -Fq "nand write \"\$fileaddr\" 0x00900000 $firmware_size_hex" \
  "$work/pzl8-uboot-recovery.scr"
grep -Fq "nand write \"\$fileaddr\" 0x04300000 $firmware_size_hex" \
  "$work/pzl8-uboot-recovery.scr"
grep -Fq 'setenv recovery_addr 0x48000000' \
  "$work/pzl8-uboot-recovery.scr"
grep -Fq 'imxtract "$fitaddr" "firmware-00" "0x48000000"' \
  "$work/pzl8-uboot-recovery.scr"
if grep -Eq \
  'SBL1|MIBIB|BOOTCONFIG|QSEE|DEVCFG|CDT|APPSBL|ART|saveenv' \
  "$work/pzl8-uboot-recovery.scr"; then
  echo "U-Boot recovery script references protected partitions" >&2
  exit 1
fi

cat > "$work/pzl8-uboot-recovery.its" <<EOF
/dts-v1/;

/ {
  timestamp = <$fit_timestamp>;
  description = "Flashing nand 800 20000";

  images {
    script {
      description = "flash.scr";
      data = /incbin/("$work/pzl8-uboot-recovery.scr");
      type = "script";
      arch = "arm";
      compression = "none";
      hash@1 {
        value = <0x$script_crc32>;
        algo = "crc32";
      };
    };

EOF
cat "$recovery_its_nodes" >> "$work/pzl8-uboot-recovery.its"
cat >> "$work/pzl8-uboot-recovery.its" <<EOF
  };
};
EOF

dtc -I dts -O dtb \
  -o "$output/$uboot_recovery_name" \
  "$work/pzl8-uboot-recovery.its"
python3 -c \
  'import pathlib, sys; assert pathlib.Path(sys.argv[1]).read_bytes()[:4] == b"\xd0\x0d\xfe\xed"' \
  "$output/$uboot_recovery_name"
test "$(fdtget "$output/$uboot_recovery_name" / description)" = \
  "Flashing nand 800 20000"
test "$(fdtget "$output/$uboot_recovery_name" /images/script description)" = \
  "flash.scr"
test "$(fdtget "$output/$uboot_recovery_name" /images/script type)" = \
  "script"
test "$(fdtget "$output/$uboot_recovery_name" /images/script/hash@1 algo)" = \
  "crc32"
for recovery_chunk in "$recovery_chunk_dir"/firmware-[0-9][0-9]; do
  recovery_suffix="${recovery_chunk##*-}"
  recovery_node="firmware-$recovery_suffix"
  test "$(fdtget "$output/$uboot_recovery_name" \
    "/images/$recovery_node" type)" = "firmware"
  test "$(fdtget "$output/$uboot_recovery_name" \
    "/images/$recovery_node" compression)" = "gzip"
  test "$(fdtget "$output/$uboot_recovery_name" \
    "/images/$recovery_node/hash@1" algo)" = "crc32"
done

rm -rf "$work/verify-uboot-recovery"
python3 "$repo_root/scripts/extract_fit.py" \
  "$output/$uboot_recovery_name" \
  "$work/verify-uboot-recovery" |
  tee "$work/verify-uboot-recovery.txt"
test "$(find "$work/verify-uboot-recovery" -maxdepth 1 -type f | wc -l)" \
  -eq $((recovery_chunk_count + 1))
cmp "$work/pzl8-uboot-recovery.scr" \
  "$work/verify-uboot-recovery/script.bin"
cat "$work/verify-uboot-recovery"/firmware-*.bin \
  > "$work/verify-uboot-recovery/firmware.bin"
cmp "$output/$firmware_name" "$work/verify-uboot-recovery/firmware.bin"
uboot_recovery_size="$(stat -c %s "$output/$uboot_recovery_name")"
if [ "$uboot_recovery_size" -ge $((32 * 1024 * 1024)) ]; then
  echo "U-Boot Web recovery image exceeds the 32 MiB HTTP limit" >&2
  exit 1
fi
test "$script_crc32" = "$(python3 -c \
  'import pathlib, sys, zlib; print(f"{zlib.crc32(pathlib.Path(sys.argv[1]).read_bytes()) & 0xffffffff:08x}")' \
  "$work/verify-uboot-recovery/script.bin")"

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
unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
  usr/share/passwall/app.sh > "$work/verify-passwall-app.sh"
unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
  usr/share/passwall/xray_legacy_compat.lua > "$work/verify-xray-legacy-compat.lua"
unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
  usr/share/passwall/nftables.sh > "$work/verify-passwall-nftables.sh"
unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
  usr/sbin/pzl8-postboot > "$work/verify-pzl8-postboot.sh"
unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
  etc/rc.local > "$work/verify-rc.local"
unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
  lib/upgrade/platform.sh > "$work/verify-platform.sh"
unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
  etc/openwrt_release > "$work/verify-openwrt-release"
unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
  etc/banner > "$work/verify-banner"
test "$(grep -Fc "xray_legacy_compat.lua" \
  "$work/verify-passwall-app.sh")" -eq 1
sh -n "$work/verify-passwall-app.sh"
cmp "$repo_root/scripts/xray-legacy-compat.lua" \
  "$work/verify-xray-legacy-compat.lua"
if grep -Fq "counter reject" "$work/verify-passwall-nftables.sh"; then
  echo "Repacked rootfs still contains unsupported nftables reject actions" >&2
  exit 1
fi
grep -Fq "counter drop" "$work/verify-passwall-nftables.sh"
sh -n "$work/verify-passwall-nftables.sh"
cmp "$repo_root/scripts/pzl8-postboot.sh" "$work/verify-pzl8-postboot.sh"
grep -Fq '/etc/init.d/passwall start </dev/null' \
  "$work/verify-pzl8-postboot.sh"
grep -Fq '/usr/sbin/pzl8-postboot </dev/null' "$work/verify-rc.local"
sh -n "$work/verify-pzl8-postboot.sh"
sh -n "$work/verify-rc.local"
cmp "$repo_root/scripts/pzl8-platform.sh" "$work/verify-platform.sh"
cmp "$work/openwrt_release" "$work/verify-openwrt-release"
cmp "$work/banner" "$work/verify-banner"
grep -Fq 'target="$(pzl8_upgrade_target)"' "$work/verify-platform.sh"
grep -Fq 'CI_UBIPART="$target"' "$work/verify-platform.sh"
grep -Fq 'pzl8_commit_boot_slot' "$work/verify-platform.sh"
if grep -Fq 'nand_do_upgrade "$1"' "$work/verify-platform.sh"; then
  echo "Repacked platform.sh still writes the active rootfs slot" >&2
  exit 1
fi
sh -n "$work/verify-platform.sh"

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
for removed_path in \
  usr/sbin/dhcrelay \
  usr/bin/zerotier-one \
  usr/bin/ttyd \
  usr/libexec/ksmbd.tools \
  usr/bin/vtysh \
  usr/sbin/zebra; do
  if unsquashfs -cat "$work/verify-volumes/rootfs.squashfs" \
    "$removed_path" >/dev/null 2>&1; then
    echo "Optional U-Boot Web size reduction file remains: $removed_path" >&2
    exit 1
  fi
done

cp "$work/passwall-packages.txt" "$output/passwall-packages.txt"
(
  cd "$output"
  sha256sum "$firmware_name" "$uboot_recovery_name" > sha256sums
)

cat > "$output/build-manifest.txt" <<EOF
base_file=$BASE_FIRMWARE
base_sha256=$BASE_SHA256
output_file=$firmware_name
output_sha256=$(sha256sum "$output/$firmware_name" | awk '{print $1}')
output_size=$firmware_size
uboot_recovery_file=$uboot_recovery_name
uboot_recovery_sha256=$(sha256sum "$output/$uboot_recovery_name" | awk '{print $1}')
uboot_recovery_size=$uboot_recovery_size
uboot_recovery_format=fit-script-plus-ubi
uboot_recovery_builder=dtc-vendor-fit-compatible
uboot_recovery_hash=crc32
uboot_recovery_compression=gzip
uboot_recovery_payload_size=$recovery_payload_size
uboot_recovery_uncompressed_size=$firmware_size
uboot_recovery_decompress_address=0x48000000
uboot_recovery_chunk_size=$recovery_chunk_size
uboot_recovery_chunk_count=$recovery_chunk_count
uboot_recovery_http_limit=0x02000000
uboot_recovery_flash_geometry=nand-0x800-0x20000
uboot_recovery_layout=dual-rootfs-only
uboot_recovery_rootfs0_offset=0x00900000
uboot_recovery_rootfs1_offset=0x04300000
uboot_recovery_slot_size=0x03a00000
uboot_recovery_protected_partitions=untouched
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
removed_packages=mosdns,luci-app-mosdns,luci-i18n-mosdns-zh-cn,v2dat,isc-dhcp-relay-ipv6,quagga-watchquagga,quagga-vtysh,quagga-ripd,quagga-zebra,quagga-libzebra,quagga,luci-app-zerotier,luci-i18n-zerotier-zh-cn,zerotier,luci-app-ttyd,luci-i18n-ttyd-zh-cn,ttyd,luci-app-ksmbd,luci-i18n-ksmbd-zh-cn,ksmbd-server
passwall_mode=nftables
passwall_core=xray
passwall_xray_1x_compat=yes
passwall_nft_block_action=drop
passwall_stdin_deadlock_fix=yes
postboot_ssid_repair=yes
passwall_default_enabled=no
display_name=PZL8
build_date=2026-08-11
display_release=2026.08.11
display_vendor=子安信息科技
sysupgrade_board_parser=fixed
sysupgrade_dual_slot=fixed
xray_file=$(cat "$work/xray-file.txt")
EOF
