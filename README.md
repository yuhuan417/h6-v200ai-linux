# H6 V200-AI Linux

Allwinner H6 / IT-LINK IT6335（BCM4335）主板的 Debian Linux 适配与维护基线。
**当前驱动方式已封版**：eMMC 启动、四核、WiFi、蓝牙、USB gadget、Type-A USB host 已工作。
本仓库保留最终配置、驱动源码和构建方法；不包含中间实验脚本、调试日志、个人密钥或整盘镜像。

## 已验证的配置

| 部件 | 封版配置与验证范围 |
| --- | --- |
| SoC / RAM | Allwinner H6，4× Cortex-A53，1 GiB LPDDR3 |
| 系统 | Debian 12 arm64，内核 `6.1.0-54-arm64` / `6.1.190-1` |
| eMMC | 7.13 GiB，根分区 `/dev/mmcblk1p3`，原 sunxi-mmc 驱动 |
| WiFi | brcmfmac，SDIO **50 MHz 单沿 / 4-bit / SD High Speed** |
| AP | 5 GHz ch36 / VHT80，SSID `v200ai`，地址 `192.168.50.1` |
| 蓝牙 | UART1，**1.5 Mbps / 8N2**；先在 115200 下载补丁，切速后等待 50 ms |
| Type-C | MUSB，CDC-ACM 串口 `ttyGS0` + CDC-NCM 网络 `192.168.60.1` |
| Type-A | DWC3 + H6 USB3 PHY + xHCI，历史 USB 存储枚举及读取已验证 |
| 视频 | Cedrus / V4L2，IOMMU 与依赖已加载，`/dev/video0` 注册；未做完整编解码性能认证 |
| locale | 默认 `C.UTF-8`，另提供 `en_US.UTF-8`，SSH 登录无 locale 警告 |

2026-11-03 用户重启后再次核验：AP ENABLED、蓝牙实际 1500000、HCI/SDIO 错误计数 0、
失败单元 0。Linux 启动耗时 **20.488 秒**，不含 Boot ROM / U-Boot。
当前没有客户端吞吐复测；历史 AP iperf3 约 127/129 Mbps，仅供参考。

WiFi 与蓝牙可以共存；**WiFi STA+AP 在当前固件/驱动组合下不可用**。
SDR50 100 MHz 与 DDR50 50 MHz 冷启动均未通过，封版使用单沿 50 MHz。

AP + 蓝牙上行可以同时工作：WiFi 只做热点，外网走 iPhone 的蓝牙 PAN（`bnep0`），
AP 客户端由 NAT 共享这条链路。见 [维护与恢复](docs/maintenance.md)。

## 使用

```sh
ssh root@192.168.60.1
wifi-mode.sh status
wifi-mode.sh ap
wifi-mode.sh sta
wifi-mode.sh boot-mode sta    # 开机首选模式；ap|sta 手工切换不改它
bt-tether.sh                  # 建蓝牙 PAN 上行（需 /etc/v200ai-bt-tether.conf）
```

开机首选模式记在 `/etc/v200ai-wifi-mode`，首选失败会回退另一种，见
[维护与恢复](docs/maintenance.md)。

源码快照中的 AP 密码 `v200ai1234` 是公开的开发默认值。部署到其他网络时设置自己的配置；
STA 凭据、SSH 密钥、蓝牙配对记录和完整镜像均不在仓库中。
当前 USB 串口为开发用途 root 自动登录，见 [维护与恢复](docs/maintenance.md)。

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| `board/` | 当前 Linux DTS、已部署关键文件 SHA256 |
| `rootfs/` | 板上实际使用的服务、模块参数、启动与维护脚本 |
| `kernel/` | 与封版匹配的蓝牙、H6 IOMMU、USB3 PHY 源码 |
| `boot/` | 当前 initramfs `/init`、清理后的常规 U-Boot 环境文本 |
| `uboot/` | 已有 U-Boot 适配补丁与使用的 defconfig；不重刷已工作的 bootloader |
| `firmware/` | NVRAM、固件来源和校验清单；二进制由来源获取 |
| `scripts/` | 主机端构建、静态检查和板上只读核验工具 |
| `docs/` | 构建、维护、封版状态、已知限制 |

先读 [AGENTS.md](AGENTS.md)。构建见 [build.md](docs/build.md)，恢复见
[maintenance.md](docs/maintenance.md)，驱动依据见 [drivers.md](docs/drivers.md)。
本仓库没有自动刷机或自动重启入口。`rootfs/` 是文件快照，不是完整 Debian 根文件系统。

## 许可与来源

项目维护脚本与文档按 GPL-2.0-or-later 提供；Linux、U-Boot 源码保留各文件的原始版权和 SPDX。
第三方固件的许可独立于本仓库，二进制不随源码仓库分发。见 [NOTICE](NOTICE)。
