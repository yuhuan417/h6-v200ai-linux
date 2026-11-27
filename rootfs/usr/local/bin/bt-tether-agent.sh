#!/bin/bash
# bt-tether-agent.sh — 常驻守护：AP 保持在线 + iPhone 蓝牙上行「来了就连」
#
# 需求（2026-11-09）：
#   · AP 一直开着，不依赖 iPhone 是否在附近；
#   · 蓝牙在开机阶段就初始化好（由 v200ai-bt-late.sh 完成）；
#   · iPhone 的蓝牙/热点什么时候可用就什么时候连，不在启动时强求。
#
# 因此这里循环做两件事：
#   1) AP 健康：期望 ap 模式时，若 hostapd 不是 ENABLED 或固件不再应答（channel 行消失）
#      就重拉一次；5 分钟内最多一次，避免和启动流程打架。
#   2) 上行：bnep0 没有地址就调 bt-tether.sh 试一次；连上后断开也会被重新发现。
# 失败日志每 5 分钟才记一条，避免手机不在时刷满日志。
set -u
LOG=/var/log/bt-tether.log
PREF_CONF=/etc/v200ai-wifi-mode
INTERVAL=20          # 固定周期：每 20 s 一轮（连不上也照这个节奏重试）
HEAL_MIN_GAP=300
FAIL_LOG_GAP=300

last_heal=0
last_fail_log=0

log() { echo "$(date '+%F %T') [agent] $*" >> "$LOG"; }

ap_healthy() {
    hostapd_cli -p /run/hostapd -i wlan0 status 2>/dev/null | grep -q "^state=ENABLED$" || return 1
    timeout 2 iw dev wlan0 info 2>/dev/null | grep -qE "^[[:space:]]*channel [0-9]"
}

pan_connected() {
    busctl get-property org.bluez /org/bluez/hci0/dev_$(echo "$BT_ADDR" | tr ':' '_') \
        org.bluez.Network1 Connected 2>/dev/null | grep -q true
}

pan_addressed() {
    pan_connected && ip -4 addr show bnep0 2>/dev/null | grep -q "inet "
}

BT_ADDR=""
[ -r /etc/v200ai-bt-tether.conf ] && \
    BT_ADDR=$(sed -n 's/^BT_ADDR=//p' /etc/v200ai-bt-tether.conf | tr -d ' \t\r' | head -1)

log "启动（BT_ADDR=${BT_ADDR:-未配置}，间隔 ${INTERVAL}s）"

while :; do
    round_start=$(date +%s)
    pref=ap
    [ -r "$PREF_CONF" ] && pref=$(tr -d ' \t\r\n' < "$PREF_CONF" 2>/dev/null | tr 'A-Z' 'a-z')

    # ① AP 健康
    if [ "$pref" = "ap" ] && [ -e /sys/class/net/wlan0 ]; then
        if ! ap_healthy; then
            now=$(date +%s)
            if [ $((now - last_heal)) -ge "$HEAL_MIN_GAP" ]; then
                log "AP 不健康（hostapd 状态或固件无应答），重拉"
                /usr/local/bin/wifi-mode.sh ap >> "$LOG" 2>&1 || log "重拉 AP 失败"
                last_heal=$(date +%s)
                if ap_healthy; then log "AP 已恢复"; else log "AP 重拉后仍不健康"; fi
            fi
        fi
    fi

    # ② 蓝牙上行：没连上就试，连上就等它断
    if [ -z "$BT_ADDR" ]; then
        sleep "$INTERVAL"
        continue
    fi
    if ! pan_addressed; then
        # 单次尝试限时 40 s（Connect 本身 12 s 超时），异常时也不拖慢 20 s 节拍
        if timeout 40 /usr/local/bin/bt-tether.sh > /tmp/bt-tether.try 2>&1; then
            cat /tmp/bt-tether.try >> "$LOG"
            log "上行就绪：$(ip -4 -br addr show bnep0 2>/dev/null | awk '{print $3}')"
        else
            now=$(date +%s)
            if [ $((now - last_fail_log)) -ge "$FAIL_LOG_GAP" ]; then
                {
                    echo "$(date '+%F %T') [agent] 上行未就绪（每 ${FAIL_LOG_GAP}s 记一次）"
                    tail -3 /tmp/bt-tether.try
                } >> "$LOG"
                last_fail_log=$now
            fi
        fi
    fi

    # 按「本轮开始时刻」对齐，保证 steady 20 s 一轮（本轮超时就立刻进下一轮）
    elapsed=$(( $(date +%s) - round_start ))
    pause=$((INTERVAL - elapsed))
    [ "$pause" -gt 0 ] && sleep "$pause"
done
