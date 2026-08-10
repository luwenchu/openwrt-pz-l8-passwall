#!/bin/sh

lock=/tmp/pzl8-postboot.lock
log=/tmp/pzl8-postboot.log
delay="${PZL8_POSTBOOT_DELAY:-90}"

mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock"' EXIT

sleep "$delay"
echo "$(date '+%F %T') postboot start" >>"$log"

wireless_changed=0
if [ "$(uci -q get wireless.wifinet0.ssid)" != "PZL8_2.4G_0" ]; then
	uci -q set wireless.wifinet0.ssid='PZL8_2.4G_0'
	wireless_changed=1
fi
if [ "$(uci -q get wireless.wifinet1.ssid)" != "PZL8_5G_1" ]; then
	uci -q set wireless.wifinet1.ssid='PZL8_5G_1'
	wireless_changed=1
fi

if [ "$wireless_changed" -eq 1 ]; then
	uci -q commit wireless
	wifi reload >>"$log" 2>&1
	echo "$(date '+%F %T') wireless defaults restored" >>"$log"
fi

if [ "$(uci -q get passwall.@global[0].enabled)" = "1" ]; then
	/etc/init.d/passwall enable >/dev/null 2>&1
	if ! pgrep -f '/tmp/etc/passwall/bin/xray run' >/dev/null 2>&1; then
		rm -f /tmp/lock/passwall.lock
		/etc/init.d/passwall start </dev/null >>"$log" 2>&1
	fi
fi

echo "$(date '+%F %T') postboot complete" >>"$log"
