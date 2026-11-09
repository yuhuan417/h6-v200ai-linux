#!/bin/bash
# WiFi AP/STA 二选一维护入口；当前固件/驱动组合不支持 STA+AP 并发。
# hostapd/dnsmasq 配置由本脚本生成；调用前确认有独立管理通道。
# AP 开发默认密码已公开；不要在此提交私人 STA 凭据。
# 开机首选模式由 /etc/v200ai-wifi-mode 决定（ap|sta，缺省 ap），见 boot-mode 子命令。
set -u

IFACE=wlan0
AP_IP=192.168.50.1
AP_CIDR=${AP_IP}/24
AP_SSID=${AP_SSID:-v200ai}
AP_PSK=${AP_PSK:-v200ai1234}
HOSTAPD_CONF=/etc/hostapd/hostapd.conf
BOOT_PREF=/etc/v200ai-wifi-mode

need_root() { [ "$(id -u)" = 0 ] || { echo "需要 root"; exit 1; }; }

# hostapd 由本脚本用 `hostapd -B` 直接拉起，不走 systemd 服务
# （Debian 的 hostapd.service 依赖 /etc/default/hostapd 里的 DAEMON_CONF，默认是空的）
hostapd_pid()     { pgrep -f "hostapd .*hostapd.conf" 2>/dev/null; }

# ── LED 指示：AP=蓝灯，STA=红灯 ──
# 本板是【红+蓝】双色灯，DT 标签与实际颜色一致：
#   v200ai:red:power    → PL4 → 实际是【红】
#   v200ai:blue:status → PL7 → 实际是【蓝】
LED_RED=/sys/class/leds/v200ai:red:power/brightness
LED_BLUE=/sys/class/leds/v200ai:blue:status/brightness
led_ap()  { echo 0 > "$LED_RED" 2>/dev/null; echo 1 > "$LED_BLUE" 2>/dev/null; }   # AP  → 蓝
led_sta() { echo 1 > "$LED_RED" 2>/dev/null; echo 0 > "$LED_BLUE" 2>/dev/null; }   # STA → 红
led_off() { echo 0 > "$LED_RED" 2>/dev/null; echo 0 > "$LED_BLUE" 2>/dev/null; }   # 无模式
hostapd_running() { [ -n "$(hostapd_pid)" ]; }

# AP 拆除时固件可能卡在 SDIO 控制通道上（brcmf_sdio_bus_rxctl），
# 每条控制命令都要等满 2.5 s 超时才返回，SIGTERM 也只能排在它们后面。
# 所以这里只给 3 s 窗口：超时说明固件已经不正常，直接重绑比干等省两分钟。
stop_hostapd() {
    local i=0
    hostapd_running || return 0
    pkill -f "hostapd .*hostapd.conf" 2>/dev/null || true
    while hostapd_running; do
        [ "$i" -lt 30 ] || return 1
        sleep 0.1; i=$((i+1))
    done
    return 0
}

# sdio-reset.sh 已经 pkill 过 hostapd；若进程仍挂在 rxctl 上就 SIGKILL 收尾
stop_hostapd_hard() {
    pkill -9 -f "hostapd .*hostapd.conf" 2>/dev/null || true
    sleep 0.5
}

# 开机首选模式，由 /etc/v200ai-wifi-mode 决定；缺失或内容非法一律按 ap（历史行为）
boot_pref() {
    local m=""
    [ -r "$BOOT_PREF" ] && m=$(tr -d ' \t\r\n' < "$BOOT_PREF" 2>/dev/null | tr 'A-Z' 'a-z')
    case "$m" in ap|sta) echo "$m" ;; *) echo ap ;; esac
}

pref_hint() {
    echo "  ℹ 开机首选: $(boot_pref)（wifi-mode.sh boot-mode <ap|sta> 修改）"
}
iface_type()      { iw dev "$IFACE" info 2>/dev/null | awk '/type/{print $2}'; }

do_status() {
	echo "=== WiFi 状态 ==="
	iw dev "$IFACE" info 2>/dev/null | sed 's/^/  /'
	echo "--- 链路 ---"
	iw dev "$IFACE" link 2>/dev/null | sed 's/^/  /' || echo "  未关联"
	echo "--- IP ---"
	ip -4 addr show "$IFACE" 2>/dev/null | grep inet | sed 's/^/  /' || echo "  无"
	echo "--- 服务 ---"
	for s in wpa_supplicant@wlan0 dnsmasq systemd-networkd; do
		printf "  %-26s %s\n" "$s" "$(systemctl is-active "$s" 2>&1)"
	done
	if hostapd_running; then
		printf "  %-26s %s\n" "hostapd(手动)" "active pid=$(hostapd_pid | tr '\n' ' ')"
	else
		printf "  %-26s %s\n" "hostapd(手动)" "inactive"
	fi
	echo "--- 接口类型 ---"
	echo "  $(iface_type)"
	echo "--- 开机首选 ---"
	echo "  $(boot_pref)"
	echo "--- 蓝牙上行 ---"
	if ip -4 addr show bnep0 2>/dev/null | grep -q "inet "; then
		echo "  bnep0 $(ip -4 -br addr show bnep0 2>/dev/null | awk '{print $3}')"
	else
		echo "  未连接（bt-tether.sh 建立）"
	fi
	echo "--- 路由 ---"
	ip route | head -3 | sed 's/^/  /'
	echo "--- 外网 ---"
	ping -c 1 -W 3 223.5.5.5 >/dev/null 2>&1 && echo "  ✅ 通" || echo "  ❌ 不通"
}

do_sta() {
	need_root
	echo "→ 停止 AP 模式"
	rebind=0
	if ! stop_hostapd; then
		rebind=1
		echo "  ⚠ hostapd 3s 内未退出（固件卡在 SDIO 控制通道），跳过 ip/iw 直接重绑"
	fi
	systemctl stop dnsmasq 2>/dev/null

	if [ "$rebind" = 1 ]; then
		# 卡死的固件上再做 ip/iw 只会再叠几次 2.5 s 超时。
		# sdio-reset 会 pkill hostapd 并重绑主控，固件重载后默认就是 managed。
		/usr/local/bin/sdio-reset.sh >/dev/null 2>&1
		stop_hostapd_hard
		sleep 2
		ip addr flush dev "$IFACE" 2>/dev/null
	else
		ip addr flush dev "$IFACE" 2>/dev/null
		ip link set "$IFACE" down 2>/dev/null

		# 切到 managed。brcmfmac 在 AP 模式有残留状态时，set type 会返回
		# EAGAIN(-11)（"Resource temporarily unavailable"）。
		# 此时重绑 SDIO 主控最省事 —— 固件重新加载后默认就是 managed。
		if ! iw dev "$IFACE" set type managed 2>/dev/null; then
			echo "  ⚠ set type managed 被拒（EAGAIN），改用 SDIO 重绑"
			/usr/local/bin/sdio-reset.sh >/dev/null 2>&1
			stop_hostapd_hard
			sleep 2
			iw dev "$IFACE" set type managed 2>/dev/null || echo "  ✗ 仍无法切到 managed"
		fi
	fi
	ip link set "$IFACE" up

	echo "→ 启动 STA 模式"
	systemctl start wpa_supplicant@wlan0
	i=0
	while [ $i -lt 10 ]; do
		iw dev "$IFACE" link 2>/dev/null | grep -q SSID && break
		sleep 2; i=$((i+1))
	done
	iw dev "$IFACE" link 2>/dev/null | grep -E 'SSID|freq|signal' | sed 's/^/  /'

	# 关联成功后让 networkd 重新跑 DHCP。
	# SDIO 重绑或从 AP 切过来之后，networkd 不会自己重试，必须显式 reconfigure，
	# 否则会出现「已关联但没 IP、外网不通」。
	networkctl reconfigure "$IFACE" >/dev/null 2>&1 || systemctl restart systemd-networkd >/dev/null 2>&1
	j=0
	while [ $j -lt 12 ]; do
		ip -4 addr show "$IFACE" 2>/dev/null | grep -q "inet " && break
		sleep 1; j=$((j+1))
	done

	ip -4 addr show "$IFACE" | grep inet | sed 's/^/  /' || echo "  ⚠ 还没拿到 IP"
	led_sta
	if ping -c 1 -W 3 223.5.5.5 >/dev/null 2>&1; then
		echo "  ✅ 外网通"
	else
		echo "  ❌ 外网不通"
	fi
	echo "  🔴 LED: 红（STA 模式）"
	pref_hint
}

do_ap() {
	need_root
	echo "→ 停止 STA 模式"
	systemctl stop wpa_supplicant@wlan0 2>/dev/null
	# 直接切接口类型，不依赖 wpa_supplicant 释放
	ip link set "$IFACE" down 2>/dev/null
	iw dev "$IFACE" set type __ap 2>/dev/null
	ip addr flush dev "$IFACE" 2>/dev/null
	ip link set "$IFACE" up

	echo "→ 写 hostapd 配置（5 GHz ch36，与芯片能力匹配）"
	mkdir -p /etc/hostapd
	cat > "$HOSTAPD_CONF" <<CONF
interface=$IFACE
driver=nl80211
ctrl_interface=/run/hostapd
ssid=$AP_SSID
hw_mode=a
# 国家码：写进 ig 里才持久（直接改 /etc/hostapd/hostapd.conf 会被本脚本覆盖）
# 注意：brcmfmac 把 phy 标成 self-managed(country 99)，regdb 对它的实际限制有限，
#       但设了国家码后 beacon 里会带 Country IE，客户端选信道更规范。
country_code=CN
ieee80211d=1
channel=36
ieee80211n=1
ieee80211ac=1
# 带宽实测轨迹（iperf3，上行/下行 Mbps）：
#   20MHz         65 / 44
#   HT40          74 / 75
#   VHT80        128 / 128     ← 当前
ht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40]
vht_oper_chwidth=1
# ch36 + 80MHz 的中心信道 = 42 (5210 MHz)
vht_oper_centr_freq_seg0_idx=42
# 坑：不能加 [HTC-VHT]（驱动不支持）；不能加 [MAX-MPDU-11454]
#（驱动只支持 3895，索引 0）⇒ 只留 SHORT-GI-80
vht_capab=[SHORT-GI-80]
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=$AP_PSK
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
CONF

	echo "→ 写 dnsmasq 配置"
	mkdir -p /etc/dnsmasq.d
	# 注意 dhcp-host 那行：板子自己的 MAC 不给租约，
	# 否则 systemd-networkd 的 DHCP 客户端会向自己的 dnsmasq 要地址，
	# 可能把 192.168.50.1 顶掉。
	OWNMAC=$(cat /sys/class/net/$IFACE/address 2>/dev/null)
	cat > /etc/dnsmasq.d/v200ai-ap.conf <<CONF
interface=$IFACE
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.200,12h
dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP
dhcp-host=$OWNMAC,ignore
CONF

	echo "→ 启动 hostapd + dnsmasq"
	# 从卡死状态回滚时 hostapd 可能杀不掉：先重绑 SDIO 再来，别在这里直接放弃，
	# 否则恢复守护也没法把板子拉回 AP。
	if ! stop_hostapd; then
		echo "  ⚠ hostapd 3s 内未退出，先重绑 SDIO 主控"
		/usr/local/bin/sdio-reset.sh >/dev/null 2>&1
		stop_hostapd_hard
		sleep 2
		ip link set "$IFACE" up
		iw dev "$IFACE" set type __ap 2>/dev/null
	fi
	hostapd -B "$HOSTAPD_CONF" || { echo "  ✗ hostapd 启动失败"; exit 1; }
    # hostapd's process alone does not prove AP readiness.
    local ready=0
    for ((i=0; i<200; i++)); do
        if hostapd_cli -p /run/hostapd -i "$IFACE" status 2>/dev/null | grep -q '^state=ENABLED$'; then
            ready=1; break
        fi
        hostapd_running || break
        sleep 0.1
    done
    [ "$ready" = 1 ] || { echo "hostapd AP did not become ENABLED"; return 1; }
    # Configure IPv4 only once firmware has completed entering AP mode.
    ip addr add "$AP_CIDR" dev "$IFACE" || return 1
    systemctl start --no-block dnsmasq || return 1
    ready=0
    for ((i=0; i<100; i++)); do
        if systemctl is-active --quiet dnsmasq; then ready=1; break; fi
        systemctl is-failed --quiet dnsmasq && break
        sleep 0.1
    done
    [ "$ready" = 1 ] || { echo "AP DHCP service did not start"; return 1; }

	if hostapd_running; then
		echo "  hostapd: active pid=$(hostapd_pid | tr '\n' ' ')"
	else
		echo "  hostapd: ✗ 未运行"
	fi
	echo "  接口类型: $(iface_type)"
	iw dev "$IFACE" info 2>/dev/null | awk '/ssid|channel/{print "  " $0}'
	echo "  dnsmasq: $(systemctl is-active dnsmasq 2>&1)"
	echo "  热点: SSID=$AP_SSID  密码=$AP_PSK  IP=$AP_IP"
	echo "  ℹ WiFi 本身不提供外网；要外网用 bt-tether.sh 走蓝牙（见 docs/maintenance.md）"
	led_ap
	echo "  🔵 LED: 蓝（AP 模式）"
	pref_hint
}

# 开机首选模式；ap/sta 手工切换不改它，避免一次临时试验变成长期默认。
do_boot_mode() {
	case "${1:-}" in
	ap|sta)
		[ "$(id -u)" = 0 ] || { echo "需要 root"; return 1; }
		printf '%s\n' "$1" > "$BOOT_PREF"
		echo "开机首选模式: $(boot_pref)"
		;;
	"")
		echo "开机首选模式: $(boot_pref)"
		;;
	*)
		echo "用法: $0 boot-mode [ap|sta]"; return 1
		;;
	esac
}

case "${1:-status}" in
	status)    do_status ;;
	sta)       do_sta ;;
	ap)        do_ap ;;
	boot-mode) do_boot_mode "${2:-}" ;;
	*)         echo "用法: $0 status|sta|ap|boot-mode [ap|sta]"; exit 1 ;;
esac
