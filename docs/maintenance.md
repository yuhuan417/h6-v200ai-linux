# 维护与恢复

## 日常检查

```sh
python3 scripts/check-board.py --host root@192.168.60.1
```

此工具只读取 sysfs、hostapd 控制接口、HCI 和 systemd 状态，不切换网络、不写 eMMC。
WiFi 异常时保持 USB 管理通道，优先检查 dmesg、`/sys/class/net/wlan0/operstate` 和 MMC err_stats。
不要在 SDIO 可能卡住时跑 netlink dump；阻塞的 rtnl 可能连带使新 SSH 无法登录。
脚本同时核对 CPU 频率与温控：`v200ai-clock` 驱动、四个频率档位、85 °C/100 °C 阈值和
`cpufreq-cpu0` cooling device。

`wifi-mode.sh ap|sta` 会重建配置并切换接口，属于有副作用的维护命令；
`sdio-reset.sh` 重绑 WiFi 主控、重新触发 WL_REG_ON，能恢复部分故障但不代表物理切断所有电源。
这两者都可能中断 WiFi。当前 `hostapd.conf` 每次由模式脚本生成，直接手改不会持久。

开机首选模式由 `/etc/v200ai-wifi-mode` 决定（内容 `ap` 或 `sta`，缺失按 `ap`），
用 `wifi-mode.sh boot-mode sta|ap` 读写；`ap`/`sta` 子命令不修改它，避免一次临时试验变成长期默认。
`v200ai-wifi-boot.sh` 先起首选模式，失败才回退另一种，所以板子不会停在「无 WiFi」状态。

AP 拆除时固件可能卡在 SDIO 控制通道（`brcmf_sdio_bus_rxctl`，dmesg 里是一串 `-110`），
hostapd 的 SIGTERM 只能排在每条约 2.5 s 的超时之后。`do_sta` 只给 3 s 退出窗口，
超时即直接 `sdio-reset.sh` 重绑并用 SIGKILL 收尾，不再干等约两分钟；`do_ap` 同样处理，
保证恢复守护回滚 AP 时能走通。

## CPU 频率与温控

CPU 的降频温控是默认能力，加载顺序由 `/etc/modules-load.d/v200ai-cpufreq.conf` 固定：
`sun8i_thermal`（温区）在前，`v200ai_cpufreq`（cooling device）在后。

```sh
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_driver            # v200ai-clock
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq          # governor 的请求，kHz
cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_cur_freq          # 实际时钟，kHz
cat /sys/class/thermal/thermal_zone0/temp                             # 毫摄氏度
cat /sys/class/thermal/cooling_device0/type /sys/class/thermal/cooling_device0/cur_state
sha256sum /lib/modules/$(uname -r)/extra/v200ai_cpufreq.ko            # 对 board/baseline-sha256.json
```

- `scaling_cur_freq` 是 schedutil 最近一次请求，`cpuinfo_cur_freq` 才是实际时钟，
  两者短暂不一致是正常的，不要据此判断模块失效。
- 温度到 85 °C 时 CPU 上限从 888 MHz 降到 816 MHz，回落到约 83 °C 后恢复；
  100 °C critical 由内核直接保护，不经过本模块。
- 只有 `sun8i_thermal` 加载成功才有 `cpu-thermal` 温区和 `/sys/class/thermal/thermal_zone0/temp`；
  模块缺失时先看 dmesg 里的 `v200ai-cpufreq:` 行和 `systemctl status systemd-modules-load`。
- 重新编译/替换 ko 属于写 eMMC，按 AGENTS.md 逐次确认；构建、部署与回退命令见
  [主机构建](build.md)，设计取舍见 [封版驱动依据](drivers.md)。

卸载模块后 CPU 停在当时的频率、不会自动升频，重新加载的新上限也是当时的时钟；
要回到 888 MHz 只能整机重新上电。加入温控没有改动电源、待机或散热相关的其它策略。

## USB 网卡（Type-A）

Type-A 上的 Realtek RTL8156 由 CDC-NCM 驱动，接口按 MAC 命名 `enx00e04c6801c2`。
开机由 `/etc/modules-load.d/v200ai-usbnet.conf` 加载 `usbnet`/`cdc_ether`/`cdc_ncm`；
热插拔时 udev 也会按 modalias 自动加载（两种情况都实测过）。

```sh
lsmod | grep -E '^(cdc_ncm|cdc_ether|usbnet|mii) '
ip -br link | grep '^enx'
dmesg | grep -E 'cdc_ncm|r8152' | tail
```

- **不要 `modprobe r8152`**：它注册的 cfgselector 会把设备切到 vendor config 1，
  随后读 PLA 0xe820 报 `-71`、设备掉线；板上也没有 `r8152.ko`。
- 接口 `DOWN` / `NO-CARRIER` 通常只是没插网线或对端没起；驱动没加载时接口不会出现。
- USB 侧是 High-Speed 480 Mbps，2.5G PHY 受此限制；以太侧吞吐与稳定性尚未验证。

## 蓝牙 tether（iPhone 上行）

芯片不支持 STA+AP 并发，但 **AP + 蓝牙 PAN 上行**可以共存：WiFi 只做热点，外网走 `bnep0`。
这就是「板子当热点，同时用手机网络上网」的形态。

```sh
/usr/local/bin/bt-tether.sh          # 建 PAN、拿 DHCP、配 NAT 和 DNS；可重复执行
wifi-mode.sh status                 # 会显示 bnep0 地址
```

- 配对：iPhone 走 numeric comparison。BlueZ 侧必须用能确认的 agent
  （`bluetoothctl` 里 `agent DisplayYesNo` 并回 `yes`），`NoInputNoOutput` 会被取消。
  iPhone 要在「设置 → 蓝牙」页面保持打开才对外可被发现，个人热点要打开。
- 配置：`/etc/v200ai-bt-tether.conf` 里写 `BT_ADDR=<iPhone MAC>`。
- 连接：板上没有 bluez-tools，用 BlueZ D-Bus 的 `org.bluez.Network1 Connect nap`；
  `bnep0` 的 DHCP 由运行态 `/run/systemd/network/25-bnep0.network` 交给 systemd-networkd。
- NAT：AP 模式下脚本会 `net.ipv4.ip_forward=1` 并加
  `iptables -t nat -A POSTROUTING -s 192.168.50.0/24 -o bnep0 -j MASQUERADE`，
  AP 客户端因此共享这条蜂窝链路。规则是运行态，重启由脚本重建。
- DNS：本板没有 systemd-resolved，`net-dns.sh <iface>` 把该链路的 DHCP DNS
  bind mount 到 `/etc/resolv.conf`（不写 eMMC），并让 AP 的 dnsmasq 也换上游。

已知代价：

- **冷启动时下载 BT 补丁会重置芯片的 SDIO/backplane**（2026-11-09 实测）：补丁最后一步
  把 BT core 从 RAM 启动，整颗芯片的 SDIO 侧随之失效 —— WL 固件哪怕没起 AP 也会立刻
  不再应答（`-110`），hostapd 仍报 `ENABLED`。开机顺序因此固定为：

  ```
  udev 加载 brcmfmac（wlan0 出现 = 驱动已 attach，这是重绑能恢复的前提）
  → v200ai-bt-late：modprobe hci_uart 下补丁
  → 探测 channel 行（1 s 超时）确认失效
  → sdio-reset 重绑（驱动 attach 过才有效）
  → v200ai-ap：wifi-mode.sh ap 起 hostapd
  → v200ai-bt-tether：常驻守护，PAN + NAT + DNS（iPhone 出现才连）
  ```

  `bt-tether-agent.sh` 固定 **20 s 一轮**（按本轮开始时刻对齐）：`bnep0` 没地址就调
  `bt-tether.sh` 试连，连上后断开也会在下一轮被发现并重连；`Connect nap` 单次 12 s 超时、
  整体尝试 40 s 超时，不会拖慢节拍。同时守着 AP（hostapd 非 ENABLED 或 `channel` 行消失时
  重拉，5 分钟最多一次）。所以 **AP 与 iPhone 是否在附近无关**，手机蓝牙/热点什么时候
  可用就什么时候建立上行；失败日志仍每 5 分钟才记一条，避免刷屏。

  实测开机到「AP + 外网齐活」**28.5 s**（各段：brcmfmac attach 6.8 s、补丁 14.6 s、
  探测 1.4 s、重绑 3.6 s、hostapd 5.7 s、tether 3.1 s）。
- **不要试「先 BT 后 WL/AP」**（三条都实测失败，2026-11-09）：补丁后 WL 根本没 attach 时，
  `modprobe brcmfmac` 会报 `chip backplane type 15 is not supported`（probe `-19`），
  重试 5 次、跨 60 s 都不行；若 WL 固件已加载但还空转，补丁会打出成片
  `data error` 且 AP 起不来。唯一可行的是「WL 先 attach → 补丁 → 整次重绑」。
- 判据只能看输出内容：固件卡死时 `iw dev wlan0 info` 的退出码仍是 0，只是不再打印
  `channel` 行。用退出码判断会得到假阳性（本项目踩过）。
- 卡死时的指纹：固件只回 `-110`（dmesg 里 `resumed on timeout` / `chanspec failed`），
  hostapd 却照旧报 `ENABLED`，客户端连不上、hostapd 日志里连 auth 帧都没有。
  这种卡死不会自愈，只能 `wifi-mode.sh ap`（内部走 `sdio-reset.sh`，实测约 2 分钟，
  BT/PAN 不受牵连）。
- 开机 dmesg 里的 `brcmf_p2p_notify_action_frame_rx` 栈越界告警（`memcpy ... size 67 / 26`）
  是 brcmfmac 已知 bug，收到 action frame 时触发；目前未观察到它单独导致卡死，但属于内存破坏点。
- AP 跑起来后再开 PAN 流量，WiFi 侧曾有掉到 `down` 的记录，重连用 `wifi-mode.sh ap`。
- 蜂窝延迟明显高于本地 WiFi（实测 40–240 ms），带宽约百 KB/s 量级；属正常。
- iPhone 热点关闭、离开范围或锁屏断开后 `bnep0` 会失效，`bt-tether.sh` 可重跑恢复。

## 启动链

| eMMC 分区 | 用途 |
| --- | --- |
| p1，256 MiB FAT32 | `/boot/firmware`，Image / initrd.img / v200ai.dtb / uboot.env |
| p2，256 MiB | 保留 |
| p3，约 6.62 GiB ext4 | `/`，PARTUUID `8d68c129-03` |

U-Boot 使用 `mmc 1`；Linux 现有编号 eMMC 为 mmc1、WiFi 为 mmc0。
bootargs 的 root PARTUUID 不应与另一块板子的分区表混用。
bootloader 写在用户区 **8 KiB 偏移**，不是 boot0/boot1。

| p1 文件 | 行为 |
| --- | --- |
| `noswitch` 存在 | 启动 initramfs USB 串口 shell |
| `noswitch` 不存在 | 正常启动 Debian |

启动不再读取、创建或清除 `umshold.flag`；加载 `Image`、`initrd.img` 或 DTB 失败，
以及 `booti` 返回时，U-Boot 仍进入 UMS 供修复启动文件。`boot/uboot-env.txt` 是当前环境文本。

initramfs 是裁剪的 klibc 环境，命令能力有限；保留 `exec chroot /rootfs /sbin/init`。
不要替换成在该控制台失败过的 run-init。保留 NLS、ext4 CRC、固定电源和 USB 依赖。

## 写入与回滚

所有 eMMC 修改必须按 AGENTS.md 逐次确认；重启、关机、断电由用户执行。
主机 `images/emmc-full.img` 是本板的私有完整备份，禁止上传公开仓库。
运行镜像含密钥、日志、网络与配对信息，不能作为可公开通用镜像。

正常能 SSH 时，先导出待改文件并校验。若不能启动，使用 FEL 加载已验证的 U-Boot，
通过 `ums 0 mmc 1` 暴露 eMMC，再在主机用 lsblk 确认实际设备和分区。
恢复启动文件或完整镜像前仍须获得本次确认，并在写后回读。
本地仓库外 `../h6-private/freeze-20261103/` 保存本次实际启动载荷、模块和清理前备份。

## 开发默认值

AP 默认密码 `v200ai1234`，USB gadget 地址 `192.168.60.1`，串口 getty 自动登录 root。
这是当前开发环境的封版快照；用于其他环境前应设置所需的认证和网络配置。
仓库不携带任何 SSH 私钥、公钥授权列表、私人 STA 凭据或蓝牙配对记录。
