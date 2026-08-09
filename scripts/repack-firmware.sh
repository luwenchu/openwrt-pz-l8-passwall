#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/pins.env"

base="$repo_root/base/$BASE_FIRMWARE"
work="$repo_root/work"
volumes="$work/volumes"
rootfs="$work/rootfs"
ubi_root="$work/rootfs-data"
upper="$ubi_root/upper"
output="$repo_root/output"
sdk="$work/sdk"
firmware_name="Nwrt-2025-01-03-pzl8-passwall-nft-xray-factory.bin"

echo "$BASE_SHA256  $base" | sha256sum -c -
rm -rf "$volumes" "$rootfs" "$ubi_root" "$output"
mkdir -p "$volumes" "$upper" "$ubi_root/work" "$output"

python3 "$repo_root/scripts/extract_ubi.py" "$base" "$volumes"
test "$(stat -c %s "$volumes/kernel.bin")" -eq 3921808
test "$(stat -c %s "$volumes/rootfs.squashfs")" -eq 29874708

unsquashfs -d "$rootfs" "$volumes/rootfs.squashfs" >/dev/null
python3 "$repo_root/scripts/install_ipks.py" \
  --ipk-root "$sdk/bin/packages" \
  --base-status "$rootfs/usr/lib/opkg/status" \
  --root "$upper" \
  luci-app-passwall luci-i18n-passwall-zh-cn xray-core

test -f "$upper/etc/config/passwall"
test -f "$upper/usr/share/luci/menu.d/luci-app-passwall.json" -o \
  -f "$upper/usr/lib/lua/luci/controller/passwall.lua"
xray_path="$(find "$upper/usr" -type f -name xray -print -quit)"
test -n "$xray_path"
file "$xray_path" | tee "$work/xray-file.txt"
grep -Eq 'ELF 32-bit.*ARM' "$work/xray-file.txt"

if grep -Eq "option enabled ['\"]?1" "$upper/etc/config/passwall"; then
  echo "PassWall is unexpectedly enabled in its default configuration" >&2
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
image=$volumes/rootfs.squashfs
vol_id=1
vol_type=dynamic
vol_name=rootfs
vol_size=29966336

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
cmp "$volumes/rootfs.squashfs" "$work/verify-volumes/rootfs.squashfs"

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
rootfs_size=$(stat -c %s "$volumes/rootfs.squashfs")
rootfs_data_ubifs_size=$overlay_size
rootfs_data_min_lebs=$rootfs_data_lebs
rootfs_data_autoresize=yes
architecture=arm_cortex-a7_neon-vfpv4
kernel_preserved=yes
rootfs_preserved=yes
passwall_mode=nftables
passwall_core=xray
passwall_default_enabled=no
xray_file=$(cat "$work/xray-file.txt")
EOF

