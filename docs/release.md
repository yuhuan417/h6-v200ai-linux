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
