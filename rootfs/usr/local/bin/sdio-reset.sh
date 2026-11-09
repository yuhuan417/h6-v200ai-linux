#!/bin/bash
# sdio-reset.sh — 重绑 WiFi 主控，重新触发 PM3/WL_REG_ON 的 pwrseq。
# 使用独立 USB 管理通道执行；这会断开 WiFi，不等于物理切断模块的全部供电。
# 不重绑 eMMC 主控，不用作整板冷启动验证。
export LC_ALL=C

MMCDEV="${1:-4021000.mmc}"
DRV=/sys/bus/platform/drivers/sunxi-mmc
LOG=/var/log/sdio-reset.log

[ "$(id -u)" = 0 ] || { echo "需要 root"; exit 1; }
[ -e "$DRV/unbind" ] || { echo "✗ 找不到 $DRV/unbind"; exit 1; }
[ -e "/sys/bus/platform/devices/$MMCDEV" ] || { echo "✗ 设备 $MMCDEV 不存在"; exit 1; }

{
echo "=== $(date '+%F %T') sdio-reset $MMCDEV ==="
echo "  重置前: wlan0=$(cat /sys/class/net/wlan0/operstate 2>/dev/null || echo 无) data_error=$(dmesg | grep -c 'data error')"

# 1. 停掉会抢接口的用户态
systemctl stop wpa_supplicant@wlan0 2>/dev/null
pkill -f "hostapd .*hostapd.conf" 2>/dev/null
sleep 1

# 2. 重绑 WiFi 主控并重新触发 pwrseq
echo "$MMCDEV" > "$DRV/unbind" 2>/dev/null
echo "  unbind 完成"
# 等 SDIO 卡真的消失再 bind（原来固定 sleep 2，白白多等）
for _ in $(seq 1 20); do
    [ -e /sys/bus/sdio/devices/mmc0:0001:1 ] || break
    sleep 0.1
done
echo "$MMCDEV" > "$DRV/bind" 2>/dev/null
echo "  bind 完成"

# 3. 等 wlan0 回来
for i in $(seq 1 25); do
    [ -e /sys/class/net/wlan0 ] && break
    sleep 1
done

if [ -e /sys/class/net/wlan0 ]; then
    echo "  ✓ wlan0 已恢复（${i}s），MAC=$(cat /sys/class/net/wlan0/address)"
    echo "  ✓ 固件: $(dmesg | grep -oE 'version [0-9.]+ .*' | tail -1)"
    echo "  重置后: data_error=$(dmesg | grep -c 'data error')"
else
    echo "  ✗ 25s 内 wlan0 未恢复 —— 需要物理断电"
fi
echo "=== $(date '+%F %T') 结束 ==="
} 2>&1 | tee -a "$LOG"
