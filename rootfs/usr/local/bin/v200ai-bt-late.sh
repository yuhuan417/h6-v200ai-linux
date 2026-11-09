#!/bin/bash
# v200ai-bt-late.sh — 等 brcmfmac attach 之后加载蓝牙；补丁会重置芯片 SDIO，随后自愈重绑
#
# 次序（2026-11-09 实测）：
#   1) brcmfmac 由 udev 在开机早期加载并 attach（wlan0 出现）—— 这是后面「重绑能恢复」的前提；
#   2) 这时才 modprobe hci_uart 下 BT 补丁：补丁最后一步启动 BT core，
#      会把整颗芯片的 SDIO/backplane 一起重置，WL 随即失联（-110）；
#   3) 立刻 sdio-reset 重绑（驱动 attach 过，这条路径能恢复），再确认 channel 行；
#   4) AP 由 v200ai-ap.service 在本服务之后拉起。
#   补丁前不再起 AP：那 5 秒是白等的，AP 贴着补丁必被打死。
set -o pipefail
export LC_ALL=C
LOG=/var/log/bt-late-load.log

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

# 固件真的在应答：必须打出 channel <n>（卡死时 iw 的退出码仍是 0，只能看内容）
wifi_alive() {
    # 卡死时这里会挂住，超时就是判据；1 s 足够（健康时 ~10 ms 就返回）
    timeout 1 iw dev wlan0 info 2>/dev/null | grep -qE "^[[:space:]]*channel [0-9]"
}

wait_wlan0() {
    local i=0
    while [ $i -lt 300 ]; do
        [ -e /sys/class/net/wlan0 ] && return 0
        sleep 0.1; i=$((i+1))
    done
    return 1
}

{
echo "=== $(date '+%F %T') 延迟加载蓝牙（WL 已 attach 之后） ==="

wait_wlan0 || { echo "  ⚠ 30s 内没有 wlan0（brcmfmac 未 attach）"; exit 1; }
echo "  brcmfmac 已 attach（wlan0 存在）"

if wifi_alive; then
    echo "  补丁前控制通道正常"
else
    echo "  ⚠ 补丁前控制通道已没有 channel 行"
fi

# ① 加载蓝牙，触发补丁下载 + BT core 启动
BEFORE=$(dmesg | grep -c "build 0353")
modprobe hci_uart || exit 1
poll_until "蓝牙补丁已加载" 30 \
    bash -c "[ \$(dmesg | grep -c 'build 0353') -gt $BEFORE ]" || exit 1

hciconfig hci0 up 2>/dev/null
poll_until "hci0 已 UP RUNNING" 20 \
    bash -c "hciconfig hci0 2>/dev/null | grep -q 'UP RUNNING'" || exit 1
echo "  MAC : $(hciconfig hci0 2>/dev/null | grep -oE 'BD Address: [0-9A-F:]+' | head -1)"

# ② 补丁之后 WL 通常已失联；确认并重绑
if wifi_alive; then
    echo "  BT 补丁后控制通道仍正常（本次未触发重置）"
else
    echo "  BT 补丁后控制通道失效（已知行为），重绑 WiFi"
    /usr/local/bin/sdio-reset.sh >/dev/null 2>&1
    for _ in 1 2 3 4 5; do
        wifi_alive && break
        sleep 1
    done
    if wifi_alive; then
        echo "  重绑后控制通道已恢复"
    else
        echo "  ✗ 重绑后仍无响应"
        exit 1
    fi
fi

echo "  data error: $(dmesg | grep -c 'data error')"
echo "=== $(date '+%F %T') 结束 ==="
} 2>&1 | tee -a "$LOG"
