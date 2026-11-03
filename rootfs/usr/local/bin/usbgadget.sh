#!/bin/bash
# usbgadget.sh — 把 Type-C 做成复合 gadget：CDC-ACM(串口) + CDC-NCM(网卡)
#
# 设计原则：**从不拆除已有 gadget**，只在干净状态下新建。
# 原因：configfs 的 rmdir 在引用计数未归零时会永久阻塞（D 状态，kill 不掉），
#       而且会持锁阻塞后续所有 configfs 操作。踩过一次，见 notes。
#
# 用途：开机时由 usbgadget.service 调用；也可手动 `usbgadget.sh status`。
export LC_ALL=C
NET=${NETFUNC:-ncm}          # ncm（Windows 原生支持）| rndis | ecm
IFIP=192.168.60.1            # usb0 的地址
G=/sys/kernel/config/usb_gadget/v200ai

log() { echo "$@"; }

status() {
  echo "== gadget 状态 =="
  echo "  UDC        : $(ls /sys/class/udc/ 2>/dev/null | tr '\n' ' ')"
  echo "  state      : $(cat /sys/class/udc/*/state 2>/dev/null)"
  echo "  gadget dir : $([ -d $G ] && echo 存在 || echo 不存在)"
  [ -d "$G" ] && echo "  UDC(绑)    : '$(cat $G/UDC 2>/dev/null)'"
  [ -d "$G" ] && echo "  functions  : $(ls $G/functions/ 2>/dev/null | tr '\n' ' ')"
  echo "  ttyGS0     : $([ -c /dev/ttyGS0 ] && echo 存在 || echo 不存在)"
  echo "  getty      : $(systemctl is-active serial-getty@ttyGS0 2>/dev/null)"
  echo "  网卡       : $(ls /sys/class/net/ 2>/dev/null | tr '\n' ' ')"
  ip -4 -o addr show 2>/dev/null | awk '{printf "    %-8s %s\n", $2, $4}'
}

case "$1" in
  status) status; exit 0 ;;
esac

log "=== 建立 ACM+$NET gadget ==="

# --- 0. 安全检查：已有 gadget 就退出，绝不 rmdir ---
if [ -d "$G" ]; then
  log "!! $G 已存在，拒绝重建（避免 configfs rmdir 死锁）"
  log "   需要重建请先重启板子"
  status
  exit 1
fi

# --- 1. 卸掉 g_serial，让 UDC 空闲 ---
log "--- 1. 释放 UDC ---"
systemctl stop serial-getty@ttyGS0.service 2>/dev/null
modprobe -r g_serial 2>/dev/null
log "    g_serial 引用: $(lsmod | awk '/^g_serial/{print $4}')"
log "    UDC: $(ls /sys/class/udc/ 2>/dev/null | tr '\n' ' ')"

# --- 2. 建 gadget ---
log "--- 2. 建 gadget ---"
mkdir -p "$G" || { log "!! mkdir 失败"; exit 1; }
cd "$G" || exit 1

echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "V200AI0001" > strings/0x409/serialnumber
echo "V200-AI"     > strings/0x409/manufacturer
echo "V200-AI Serial + $NET" > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "ACM+$NET" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

mkdir -p functions/acm.usb0
ln -sf functions/acm.usb0 configs/c.1/ 2>/dev/null || ln -s functions/acm.usb0 configs/c.1/

mkdir -p "functions/$NET.usb0"
echo "02:00:00:00:00:01" > "functions/$NET.usb0/dev_addr"  2>/dev/null
echo "02:00:00:00:00:02" > "functions/$NET.usb0/host_addr" 2>/dev/null
ln -sf "functions/$NET.usb0" configs/c.1/ 2>/dev/null || ln -s "functions/$NET.usb0" configs/c.1/

log "    functions: $(ls functions/ | tr '\n' ' ')"
log "    c.1      : $(ls configs/c.1/ | grep -vE 'MaxPower|bmAttributes|strings' | tr '\n' ' ')"

# --- 3. 绑 UDC ---
log "--- 3. 绑定 UDC ---"
UDCNAME=$(ls /sys/class/udc | head -1)
[ -n "$UDCNAME" ] || { log "!! 没有 UDC"; exit 1; }
echo "$UDCNAME" > UDC || { log "!! 绑 UDC 失败"; exit 1; }
log "    UDC=$UDCNAME  state=$(cat /sys/class/udc/*/state 2>/dev/null)"
# Device registration is normally synchronous, but bound the asynchronous case.
for ((i=0; i<100; i++)); do
  [ -c /dev/ttyGS0 ] && { [ -d /sys/class/net/usb0 ] || [ -d /sys/class/net/usb1 ]; } && break
  sleep 0.1
done

# --- 4. 配网络 ---
log "--- 4. 配网络 ---"
IF=""
for cand in usb0 usb1; do
  [ -d "/sys/class/net/$cand" ] && { IF=$cand; break; }
done
if [ -n "$IF" ]; then
  ip addr flush dev "$IF" 2>/dev/null
  ip addr add "$IFIP/24" dev "$IF" 2>/dev/null
  ip link set "$IF" up
  log "    $IF = $(ip -4 -o addr show dev $IF | awk '{print $4}')"
else
  log "    !! 没找到 usb0/usb1"
fi

# --- 4b. 启 DHCP（独立实例，不碰 WiFi 的 192.168.50.1）---
log "--- 4b. DHCP on $IF ---"
if [ -n "$IF" ]; then
  cat > /run/usb0-dhcp.conf <<EOF
# USB gadget 网卡（Type-C）的 DHCP —— 由 usbgadget.sh 生成
interface=$IF
bind-interfaces
dhcp-range=192.168.60.10,192.168.60.100,255.255.255.0,12h
port=0
dhcp-leasefile=/run/dnsmasq-usb0.leases
# 关键：不要下发默认网关和 DNS。
# 否则 Windows 会把 192.168.60.1 当成默认路由，污染真实上网的网关
# （表现为 WSL/Windows 的 default via 192.168.60.1 抢在真网关前面）。
dhcp-option=3
dhcp-option=6
EOF
  # 用独立 pid 文件，避免和系统 dnsmasq 抢
  if [ -r /run/dnsmasq-usb0.pid ]; then
    oldpid=$(cat /run/dnsmasq-usb0.pid)
    case "$oldpid" in
      ''|*[!0-9]*) log "!! invalid USB dnsmasq pid"; exit 1 ;;
    esac
    if [ -r "/proc/$oldpid/cmdline" ] && tr '\0' ' ' < "/proc/$oldpid/cmdline" | grep -q 'usb0-dhcp.conf'; then
      kill "$oldpid" 2>/dev/null
      for ((i=0; i<50; i++)); do
        kill -0 "$oldpid" 2>/dev/null || break
        sleep 0.1
      done
    fi
  fi
  dnsmasq --conf-file=/run/usb0-dhcp.conf \
          --pid-file=/run/dnsmasq-usb0.pid
  if pgrep -f "dnsmasq.*usb0-dhcp" >/dev/null; then
    log "    dnsmasq 已起: $(pgrep -f 'dnsmasq.*usb0-dhcp' | tr '\n' ' ')"
  else
    log "    !! dnsmasq 没起来（不致命，可手动配 192.168.60.x）"
  fi
fi

# --- 5. 恢复 getty ---
log "--- 5. 起 serial-getty ---"
systemctl restart --no-block serial-getty@ttyGS0.service 2>/dev/null
log "    getty=$(systemctl is-active serial-getty@ttyGS0 2>/dev/null)"

# --- 6. 保险：串口没建出来就退回 g_serial ---
if [ ! -c /dev/ttyGS0 ]; then
  log "!! ttyGS0 没出现，退回 g_serial"
  cd /
  rm -f "$G"/configs/c.1/acm.usb0 "$G"/configs/c.1/$NET.usb0 2>/dev/null
  echo "" > "$G/UDC" 2>/dev/null
  modprobe g_serial 2>/dev/null
  sleep 2
  systemctl restart --no-block serial-getty@ttyGS0.service 2>/dev/null
  log "   回退后 ttyGS0=$([ -c /dev/ttyGS0 ] && echo 有 || echo 无) state=$(cat /sys/class/udc/*/state 2>/dev/null)"
  status
  exit 1
fi

log "=== USB serial + network ready at $(cut -d' ' -f1 /proc/uptime)s ==="
