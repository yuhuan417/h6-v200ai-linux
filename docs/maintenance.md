# 维护与恢复

## 日常检查

```sh
python3 scripts/check-board.py --host root@192.168.60.1
```

此工具只读取 sysfs、hostapd 控制接口、HCI 和 systemd 状态，不切换网络、不写 eMMC。
WiFi 异常时保持 USB 管理通道，优先检查 dmesg、`/sys/class/net/wlan0/operstate` 和 MMC err_stats。
不要在 SDIO 可能卡住时跑 netlink dump；阻塞的 rtnl 可能连带使新 SSH 无法登录。

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
  → v200ai-bt-tether：PAN + NAT + DNS
  ```

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
| `umshold.flag` 存在 | U-Boot 进入 UMS |
| 无闩且 `noswitch` 存在 | 启动 initramfs USB 串口 shell |
| 两者均无 | 正常启动 Debian |

U-Boot 引导内核前写 UMS 闩，Debian 的 v200ai-latch 服务清除它。
`boot/uboot-env.txt` 是去掉一次实验选择器的普通封版环境文本。
本次清理已获确认；板上环境已换成上述普通路径，原载荷及待删文件已在主机备份。
不要删除当前环境仍可能需要的文件，或在 UMS 闩存在时误判为 Linux 不启动。

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
