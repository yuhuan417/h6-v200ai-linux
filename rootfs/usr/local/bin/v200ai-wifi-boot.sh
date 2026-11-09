#!/bin/sh
# 开机建 WiFi：首选模式读 /etc/v200ai-wifi-mode（ap|sta，缺省 ap），首选失败回退另一种。
# 等固件注册后再切，不靠固定 sleep。
set -eu
i=0
while [ ! -e /sys/class/net/wlan0 ]; do
    [ "$i" -lt 1200 ] || { echo "wlan0 did not appear in 120s"; exit 1; }
    sleep 0.1; i=$((i+1))
done

pref=$( { tr -d ' \t\r\n' < /etc/v200ai-wifi-mode; } 2>/dev/null | tr 'A-Z' 'a-z' || true)
case "$pref" in
    sta) first=sta; other=ap ;;
    *)   first=ap;  other=sta ;;
esac

if /usr/local/bin/wifi-mode.sh "$first"; then
    echo "[wifi-boot] $first ready at $(cut -d' ' -f1 /proc/uptime)s"
elif /usr/local/bin/wifi-mode.sh "$other"; then
    echo "[wifi-boot] $first failed; fell back to $other"
else
    echo "[wifi-boot] $first and $other both failed"
    exit 1
fi
# v200ai-bt-late.service is ordered After this oneshot by systemd.
