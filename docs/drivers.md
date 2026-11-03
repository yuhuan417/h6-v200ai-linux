# 封版驱动依据

封版于 2026-11-03。保持已有可用方式，不追求将已验证配置改成另一套驱动。

## WiFi 与蓝牙

WiFi 使用内核原 brcmfmac。SDIO 4-bit / SD High Speed / 50 MHz，理论总线带宽 200 Mbps。
BCM4335 CCCR 广告 SDR50/SDR104/DDR50，但本板当前驱动与默认时序下，SDR50 100 MHz、
DDR50 50 MHz 经整板冷启动都在枚举阶段报 -110。DDR50 的内部 100 MHz / div2 已确认生效。
这些结果限定于本板和当前时序，不代表所有 BCM4335 均不支持 UHS；本版本结束提速试验。

S4 2015 WiFi 固件解决了当前板上的 WiFi/BT 共存问题；保留本板 NVRAM 与既有 HCD。
WiFi STA 和 AP 单独可用，当前组合不支持 STA+AP 并发。创建第二 BSS 的旧实验已删除。
PHY 的法规域由固件管理，缺少可选 CLM blob 的提示仍存在；已验证 ch36 可用，
未验证的信道不可由此推定可用。不要用空文件或其他芯片的 CLM 隐藏提示。

蓝牙走 UART1（PG6–PG9），APB2 24 MHz，运行 1.5 Mbps / 8N2。
`kernel/bluetooth/` 保留实际构建源码及配套 btbcm 修改；与原内核一样构建 UART 协议集合。
`v200ai_speed=1500000` 保证下载前不提前切速。HCD 在 115200 下载完成后，
芯片与主机切到 1.5 Mbps，等待 50 ms 后才发后续 HCI 命令。**不要删除该等待**。
保留既有可配置驱动字段以匹配已部署模块，但不提供扫速/裸 UART 调试脚本。
`zz-bt-late.conf` 阻止自动探测，`v200ai-bt-late.service` 在 AP 就绪后显式 modprobe。
`cmac`、`jitterentropy_rng`、`drbg` 提前加载，以支持 ECDH 自检及 BLE 安全配对。

## USB 与视频

Type-C：MUSB gadget，启动 initramfs 先提供 g_serial，Debian 再建立 ACM+NCM。
不要在运行中移除 configfs gadget；重建可能等待引用计数并阻塞管理通道。

Type-A：`usb@5200000` 是 DWC3；其 USB2 信号也需要 `phy@5210000` 的 USB3 组合 PHY。
Debian 此版本未启用该 PHY，使用 `kernel/usb3/` 的外置模块。
其余 dwc3/xHCI/roles/ulpi 来自匹配 Debian 内核包。历史 USB 存储读取约 15.2 MB/s。

H6 IOMMU 使用 `kernel/iommu/` 外置模块，在 upstream 6.1.190 基础上增加 `.owner=THIS_MODULE`，
保留永久驻留生命周期，不引入不完整的卸载。通过 softdep 早于 Cedrus/DRM 加载。
Cedrus、V4L2、videobuf2、mc 等缺失依赖从同版本 Debian 包补齐；设备注册已验证，
完整编解码业务、GPU 渲染、HDMI、以太网不在本轮验证范围内。

## 仍可出现的提示

- 自建模块未签名，内核带 O/E taint；没有启用强制模块签名。
- Cedrus 属于 staging 驱动，内核打印相应提示。
- 部分 regulator 使用 dummy provider；不能将 DT 声明当成物理电压测量。
- 可选 CLM 文件缺失；不阻塞当前已验证的 AP。

这些提示不等同于启动失败；不要通过更改已封版的驱动方式仅为隐藏日志。
