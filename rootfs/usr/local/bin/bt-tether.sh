#!/bin/bash
# bt-tether.sh — 用已配对的 iPhone 走蓝牙 PAN（NAP）给板子提供外网。
#
# AP + BT 可以共存（WiFi 只做 AP，不做 STA）：AP 服务 192.168.50.1，
# 外网走 bnep0。AP 模式下顺带打开 IPv4 转发 + MASQUERADE，
# 让连到热点的客户端共享这条蜂窝链路。
#
# 板上没有 bluez-tools，所以用 BlueZ 的 D-Bus Network1 接口；DHCP 交给 systemd-networkd。
# 背景：芯片不支持 STA+AP 并发，但「AP 承载 + 蓝牙上行」不受此限制。
set -u

IFACE=bnep0
AP_NET=192.168.50.0/24
CONF=/etc/v200ai-bt-tether.conf
NETCONF=/run/systemd/network/25-bnep0.network

log() { echo "$(date '+%F %T') $*"; }

BT_ADDR=""
if [ -r "$CONF" ]; then
    BT_ADDR=$(sed -n 's/^BT_ADDR=//p' "$CONF" | tr -d ' \t\r' | head -1)
fi
if [ -n "${BT_ADDR_OVERRIDE:-}" ]; then BT_ADDR=$BT_ADDR_OVERRIDE; fi
[ -n "$BT_ADDR" ] || { log "缺少 $CONF 里的 BT_ADDR=<iPhone MAC>"; exit 1; }
DEV="/org/bluez/hci0/dev_$(echo "$BT_ADDR" | tr ':' '_')"

pan_connected() {
    busctl get-property org.bluez "$DEV" org.bluez.Network1 Connected 2>/dev/null | grep -q "true"
}

log "=== 蓝牙 tether 开始（$BT_ADDR） ==="
modprobe bnep || { log "modprobe bnep 失败"; exit 1; }
systemctl start bluetooth 2>/dev/null

# 蓝牙由 v200ai-bt-late.service 在 WiFi 就绪后加载，这里只等它出现
for _ in $(seq 1 100); do [ -e /sys/class/bluetooth/hci0 ] && break; sleep 0.1; done
[ -e /sys/class/bluetooth/hci0 ] || { log "hci0 不存在：蓝牙还没加载"; exit 1; }

if pan_connected && ip link show "$IFACE" >/dev/null 2>&1; then
    log "PAN 已连接，跳过 Connect"
else
    # 手机热点没开时 BlueZ 可能一直等协商（实测可达 ~60 s）；12 s 足够一次寻呼+协商，
    # 失败就交给调用方下一轮重试（守护是 20 s 一轮）
    if ! timeout 12 busctl call org.bluez "$DEV" org.bluez.Network1 Connect s nap >/dev/null 2>&1; then
        log "Network1 Connect nap 失败（iPhone 热点没开 / 不在范围？）"
        exit 1
    fi
    log "PAN nap 已建立"
fi

for _ in $(seq 1 100); do ip link show "$IFACE" >/dev/null 2>&1 && break; sleep 0.1; done
ip link show "$IFACE" >/dev/null 2>&1 || { log "$IFACE 没有出现"; exit 1; }

# DHCP 用运行态 .network，不进 eMMC
mkdir -p /run/systemd/network
if [ ! -f "$NETCONF" ]; then
    printf '[Match]\nName=%s\n[Network]\nDHCP=yes\n' "$IFACE" > "$NETCONF"
fi
networkctl reload >/dev/null 2>&1
networkctl reconfigure "$IFACE" >/dev/null 2>&1

for _ in $(seq 1 200); do
    ip -4 addr show "$IFACE" 2>/dev/null | grep -q "inet " && break
    sleep 0.1
done
if ! ip -4 addr show "$IFACE" 2>/dev/null | grep -q "inet "; then
    log "$IFACE 没拿到地址"
    exit 1
fi

# AP 模式下让客户端共享这条链路
if ip -4 addr show wlan0 2>/dev/null | grep -q "192.168.50.1/24"; then
    sysctl -q -w net.ipv4.ip_forward=1
    iptables -t nat -C POSTROUTING -s "$AP_NET" -o "$IFACE" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "$AP_NET" -o "$IFACE" -j MASQUERADE
    log "AP 客户端 NAT 就绪（$AP_NET → $IFACE）"
fi

/usr/local/bin/net-dns.sh "$IFACE" || log "DNS 设置失败"

# 开机路径才做 AP 自愈：BT 补丁下载或 PAN 流量可能把刚起来的 AP 打掉，
# 不能因为「外网通了」就把热点丢掉。手工执行本脚本时不碰 WiFi 模式。
#
# 判据：hostapd ENABLED **并且** 固件真的在应答（`iw dev wlan0 info` 要打出 channel 行）。
# 卡死时 iw 的退出码仍是 0，只有 channel 行消失 —— 只看退出码会漏判。
ap_healthy() {
    hostapd_cli -p /run/hostapd -i wlan0 status 2>/dev/null | grep -q "^state=ENABLED$" || return 1
    timeout 5 iw dev wlan0 info 2>/dev/null | grep -qE "^[[:space:]]*channel [0-9]"
}

if [ "${1:-}" = "--ensure-ap" ] && [ -e /sys/class/net/wlan0 ]; then
    PREF=$(tr -d ' \t\r\n' < /etc/v200ai-wifi-mode 2>/dev/null | tr 'A-Z' 'a-z')
    if [ "$PREF" = "ap" ] && ! ap_healthy; then
        log "AP 不健康（hostapd 状态或固件无应答），重新拉起"
        if /usr/local/bin/wifi-mode.sh ap >>/var/log/bt-tether.log 2>&1; then
            if ap_healthy; then
                log "AP 重拉后已恢复"
            else
                log "✗ AP 重拉后仍不健康"
            fi
        else
            log "✗ wifi-mode.sh ap 失败"
        fi
    fi
fi

log "地址: $(ip -4 -br addr show "$IFACE" | awk '{print $3}') 路由: $(ip route show default | head -1)"
log "=== 结束 ==="
