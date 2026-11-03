#!/bin/sh
# Wait for firmware registration, then hostapd ENABLED; no fixed grace sleeps.
set -eu
i=0
while [ ! -e /sys/class/net/wlan0 ]; do
    [ "$i" -lt 1200 ] || { echo "wlan0 did not appear in 120s"; exit 1; }
    sleep 0.1; i=$((i+1))
done
if /usr/local/bin/wifi-mode.sh ap; then
    echo "WiFi AP ready at $(cut -d' ' -f1 /proc/uptime)s"
else
    echo "AP failed; falling back to STA"
    /usr/local/bin/wifi-mode.sh sta
fi
# v200ai-bt-late.service is ordered After this oneshot by systemd.
