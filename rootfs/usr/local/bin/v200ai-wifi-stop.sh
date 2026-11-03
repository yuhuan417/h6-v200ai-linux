#!/bin/sh
# 关机时清理 WiFi：停热点、把接口切回 managed 并 down。
# 目的是让 WiFi 芯片在下次开机时处于干净状态
# （我们遇到过：AP 模式下 systemctl reboot，下次开机 SDIO 卡不枚举）。
LOG=/root/boot-wifi-mode.log

{
	echo "=== $(date) 关机清理 WiFi ==="
	if pkill -f "hostapd .*hostapd.conf" 2>/dev/null; then
		echo "  已停 hostapd"
	fi
	systemctl stop dnsmasq 2>/dev/null && echo "  已停 dnsmasq"
	sleep 1
	if [ -e /sys/class/net/wlan0 ]; then
		ip link set wlan0 down 2>/dev/null
		iw dev wlan0 set type managed 2>/dev/null
		echo "  wlan0 已切回 managed 并 down"
	fi
	echo "  清理完成"
} >> "$LOG" 2>&1
