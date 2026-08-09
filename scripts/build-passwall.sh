#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/pins.env"

work="$repo_root/work"
downloads="$work/downloads"
sdk_archive="$downloads/$SDK_FILE"
sdk="$work/sdk"

mkdir -p "$downloads"
if [ ! -f "$sdk_archive" ]; then
  curl -fL --retry 5 --retry-delay 5 "$SDK_URL" -o "$sdk_archive"
fi
echo "$SDK_SHA256  $sdk_archive" | sha256sum -c -

rm -rf "$sdk"
mkdir -p "$sdk"
tar -xJf "$sdk_archive" -C "$sdk" --strip-components=1

cd "$sdk"
./scripts/feeds update -a
./scripts/feeds install -a

git clone "$PASSWALL_PACKAGES_REPO" package/passwall-packages
git -C package/passwall-packages checkout "$PASSWALL_PACKAGES_COMMIT"
git clone "$PASSWALL_REPO" package/passwall
git -C package/passwall checkout "$PASSWALL_COMMIT"

cat > .config <<'EOF'
CONFIG_PACKAGE_luci-app-passwall=y
# CONFIG_PACKAGE_luci-app-passwall_Iptables_Transparent_Proxy is not set
CONFIG_PACKAGE_luci-app-passwall_Nftables_Transparent_Proxy=y
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Geoview is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Haproxy is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Hysteria is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_NaiveProxy is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Client is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Server is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Client is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Server is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadow_TLS is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Simple_Obfs is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Geodata is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Plugin is not set
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray=y
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray_Plugin is not set
CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=y
EOF

make defconfig
make download -j"$(nproc)"
make -j"$(nproc)" || make -j1 V=s

test -n "$(find bin/packages -name 'luci-app-passwall_*.ipk' -print -quit)"
test -n "$(find bin/packages -name 'xray-core_*.ipk' -print -quit)"
test -n "$(find bin/packages -name 'luci-i18n-passwall-zh-cn_*.ipk' -print -quit)"

