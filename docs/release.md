# v1.0.0 封版

2026-11-03，用户重启后确认，保持当前已工作的驱动方式。

| 检查 | 结果 |
| --- | --- |
| SDIO | 原 sunxi-mmc，50 MHz 单沿、4-bit、SD High Speed；错误计数全部 0 |
| WiFi AP | ENABLED，ch36/VHT80，SSID v200ai |
| 蓝牙 | UART 实际 1500000、8N2、UP RUNNING、RX/TX errors=0 |
| USB | NCM 管理及 ACM 串口正常，DWC3/xHCI 根总线正常 |
| 视频 | IOMMU 与 Cedrus 已注册，/dev/video0 存在 |
| locale | en_US.UTF-8 持久生效 |
| systemd | 失败单元 0；本次 Linux 启动 20.488 s |

用户确认后删除 69 处旧调试脚本、日志、实验载荷及备份路径；
Image、initrd、DTB、驱动、固件及启用的服务保持不变，35 个保留文件回读校验通过。
U-Boot FAT 环境改为不含 SDR/DDR 一次性选择器的正常环境，保留 UMS 闩和加载失败回落。
未重刷 bootloader、未更改分区、未自动重启。

公开源码已通过脚本语法、Markdown 本地链接、DTS 语义往返、NVRAM 哈希和环境 CRC 校验，
六种启动分支模拟覆盖正常引导、已有 UMS 闩、三个载荷加载失败和 booti 返回失败。
蓝牙 hci_uart/btbcm、IOMMU、USB3 PHY 四个模块已用匹配 Debian headers 交叉编译通过；
构建产物没有重新部署，也不发布历史调试日志或镜像。

旧提交历史仅存主机私有 git bundle；public 仓库从本次封版快照开始。
完整 eMMC 备份、实际当前载荷、清理前备份与历史均不上传 GitHub。

## 2026-11-18 增补：CPU 频率与温控

在 v1.0.0 快照之上增加板级默认能力：外置 `kernel/cpufreq/v200ai_cpufreq`（只调时钟的
CPU 降频降温）、`/etc/modules-load.d/v200ai-cpufreq.conf`，以及板载 ko 的 SHA256 记录。
`sun8i_thermal` 使用 Debian 原包模块。

未改 DTB、内核 Image、bootloader、分区、默认网络和既有驱动；阈值仍是 DTB 里的
85 °C passive / 100 °C critical，governor 仍是 `schedutil`，CPU 供电电压不变。
设计取舍与实机读数见 [封版驱动依据](drivers.md)，构建和回退见 [主机构建](build.md)。

## 2026-11-23 增补：Type-A USB 网卡（CDC-NCM）

插在 Type-A 的 Realtek RTL8156（`0bda:8156`）用 CDC-NCM 驱动成以太口，补齐原版模块
`mii`、`usbnet`、`cdc_ether`、`cdc_ncm`，并用 `rootfs/etc/modules-load.d/v200ai-usbnet.conf`
开机加载。厂商模式 r8152 在本板初始化失败（PLA 0xe820 读 `-71`），因此**不安装 r8152**。
USB 侧为 High-Speed 480 Mbps；以太链路吞吐与稳定性尚未验证。细节见
[封版驱动依据](drivers.md)。
