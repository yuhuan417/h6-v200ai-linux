#!/bin/bash
# v200ai-bt-late.sh — 等 WiFi AP 真正开始工作后，再加载蓝牙
#
# 顺序必须是「WiFi → AP → 蓝牙」：
#   蓝牙补丁加载时 SDIO 控制通道会阻塞约 7-10 秒。
#   · 如果 AP 还没起：空闲的 WiFi 固件会把 SDIO 打成 "bus is down"，AP 永远起不来
#     （方案 B 实测失败，见 notes/coex-solved-2026-11-02.md）
#   · 如果 AP 已在稳定工作：总线是"热"的，补丁打完 WiFi 照常工作
#   ⇒ 所以等 AP 真的好起来再加载蓝牙。
#
# 全程事件驱动，没有固定 sleep：
#   ① 等 hostapd 控制接口报告 AP 已 ENABLED
#   ③ modprobe hci_uart
#   ④ 等 dmesg 出现补丁完成标记 "build 0353"
#   ⑤ 等 hciconfig 报 UP RUNNING
set -o pipefail
export LC_ALL=C
FW=/lib/firmware/brcm
LOG=/var/log/bt-late-load.log

# 通用轮询：poll_until <描述> <超时秒> <命令...>
poll_until() {
    local desc="$1" timeout="$2"; shift 2
    local n=$((timeout * 10)) i=0
    while [ $i -lt $n ]; do
        if "$@" >/dev/null 2>&1; then
            echo "  ${desc}（$(awk "BEGIN{printf \"%.1f\", $i/10}")s）"
            return 0
        fi
        sleep 0.1; i=$((i+1))
    done
    echo "  ⚠ ${desc} 超时（${timeout}s）"
    return 1
}

{
echo "=== $(date '+%F %T') 延迟加载蓝牙 ==="

# A confirmed AP state is required before firmware download; fail safely if absent.
poll_until "AP 已 ENABLED" 30 \
    bash -c 'hostapd_cli -p /run/hostapd -i wlan0 status 2>/dev/null | grep -q "^state=ENABLED$"' || exit 1

# ③ 加载蓝牙（触发补丁下载）
BEFORE=$(dmesg | grep -c "build 0353")
modprobe hci_uart || exit 1

# ④ 等补丁完成标记
poll_until "蓝牙补丁已加载" 30 \
    bash -c "[ \$(dmesg | grep -c 'build 0353') -gt $BEFORE ]" || exit 1

# ⑤ 拉起 hci0 并等它真进入 UP RUNNING
hciconfig hci0 up 2>/dev/null
poll_until "hci0 已 UP RUNNING" 20 \
    bash -c "hciconfig hci0 2>/dev/null | grep -q 'UP RUNNING'" || exit 1

echo "  MAC : $(hciconfig hci0 2>/dev/null | grep -oE 'BD Address: [0-9A-F:]+' | head -1)"
echo "  data error: $(dmesg | grep -c 'data error')"
echo "=== $(date '+%F %T') 结束 ==="
} 2>&1 | tee -a "$LOG"
