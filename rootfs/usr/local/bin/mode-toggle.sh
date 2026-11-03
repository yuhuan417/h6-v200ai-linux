#!/bin/bash
# mode-toggle.sh — 在 AP 与 STA 之间切换，并同步 LED 指示
#
#   AP  ←→  蓝灯（PL7）
#   STA ←→  红灯（PL4）
#
# 用法：
#   mode-toggle.sh          切换
#   mode-toggle.sh ap       强制 AP
#   mode-toggle.sh sta      强制 STA
#   mode-toggle.sh status   只显示当前状态
#
# 本板 LED 是【红+蓝】双色，DT 标签与实际颜色一致
#   v200ai:red:power    = PL4 = 红
#   v200ai:blue:status = PL7 = 蓝
export LC_ALL=C

IFACE=wlan0
LED_RED=/sys/class/leds/v200ai:red:power/brightness
LED_BLUE=/sys/class/leds/v200ai:blue:status/brightness
LOG=/var/log/mode-toggle.log

[ "$(id -u)" = 0 ] || { echo "需要 root"; exit 1; }

cur_type() { iw dev "$IFACE" info 2>/dev/null | awk '/type/{print $2}'; }

led_ap()  { echo 0 > "$LED_RED" 2>/dev/null; echo 1 > "$LED_BLUE" 2>/dev/null; }
led_sta() { echo 1 > "$LED_RED" 2>/dev/null; echo 0 > "$LED_BLUE" 2>/dev/null; }

do_status() {
	echo "  接口类型 : $(cur_type)"
	echo "  operstate: $(cat /sys/class/net/$IFACE/operstate 2>/dev/null)"
	echo "  SSID     : $(iw dev "$IFACE" info 2>/dev/null | awk '/ssid/{print $2}')"
	echo "  信道     : $(iw dev "$IFACE" info 2>/dev/null | grep -oE 'channel [0-9]+')"
	echo "  IP       : $(ip -4 addr show "$IFACE" 2>/dev/null | grep -oE 'inet [0-9.]+/[0-9]+')"
	echo "  LED      : 红=$(cat $LED_RED 2>/dev/null) 蓝=$(cat $LED_BLUE 2>/dev/null)"
}

case "${1:-toggle}" in
	status)
		do_status
		;;
	ap)
		bash /usr/local/bin/wifi-mode.sh ap
		;;
	sta)
		bash /usr/local/bin/wifi-mode.sh sta
		;;
	toggle|"")
		t=$(cur_type)
		echo "=== $(date '+%F %T') 当前=$t 开始切换 ===" | tee -a "$LOG"
		if [ "$t" = "AP" ]; then
			echo "→ AP → STA" | tee -a "$LOG"
			bash /usr/local/bin/wifi-mode.sh sta 2>&1 | tee -a "$LOG"
		else
			echo "→ STA → AP" | tee -a "$LOG"
			bash /usr/local/bin/wifi-mode.sh ap 2>&1 | tee -a "$LOG"
		fi
		echo "--- 切换后 ---" | tee -a "$LOG"
		do_status | tee -a "$LOG"
		;;
	*)
		echo "用法: $0 [toggle|ap|sta|status]"
		exit 1
		;;
esac
