# 封版驱动依据

封版于 2026-11-03。保持已有可用方式，不追求将已验证配置改成另一套驱动。

## WiFi 与蓝牙

WiFi 使用内核原 brcmfmac。SDIO 4-bit / SD High Speed / 50 MHz，理论总线带宽 200 Mbps。
BCM4335 CCCR 广告 SDR50/SDR104/DDR50，但本板当前驱动与默认时序下，SDR50 100 MHz、
DDR50 50 MHz 经整板冷启动都在枚举阶段报 -110。DDR50 的内部 100 MHz / div2 已确认生效。
这些结果限定于本板和当前时序，不代表所有 BCM4335 均不支持 UHS；本版本结束提速试验。

S4 2015 WiFi 固件解决了当前板上的 WiFi/BT 共存问题；保留本板 NVRAM 与既有 HCD。
WiFi STA 和 AP 单独可用，当前组合不支持 STA+AP 并发。创建第二 BSS 的旧实验已删除。
AP 与蓝牙 PAN 上行可以同时工作：WiFi 只做热点，外网走 `bnep0`（见[维护与恢复](maintenance.md)）。
代价是冷启动下载 BT 补丁会把 WiFi 控制通道打死一次，需要 `sdio-reset` 重拉
（`v200ai-bt-late.sh` 自动完成，开机约 +60 s）。

### 本地 brcmfmac 补丁：拆设备时的死等

`sdio-reset.sh` 拆 WiFi 主控时，`echo > .../unbind` 在「固件已死」的情况下要等约 60 秒。
实测对比：固件健康时同一操作只要 0.64 秒（`card 0001 removed` 出现在 0.4 s 后），
所以这不是拆设备的固有开销。

定位方式是开机后每 2 秒采样一次 D 状态任务的内核栈，死在同一个地方：

```
__mmc_start_request → mmc_wait_for_cmd → mmc_io_rw_direct → sdio_writeb
→ brcmf_sdiod_set_backplane_window → brcmf_sdiod_readl
→ brcmf_sdio_buscore_read32 → brcmf_chip_ai_coredisable
← brcmf_chip_set_passive ← brcmf_sdio_remove            （t=32…62 s 全程如此）
```

即 `brcmf_sdio_remove()` 收尾时要把芯片设成 passive，它会对每个 core 做 SDIO 读-改-写；
而 **CMD52 在 mmc 层没有完成超时**（`mmc_wait_for_cmd` 只是 `wait_for_completion`），
死芯片不应答就只能等控制器自己放弃，实测约 54 s。

补丁（`kernel/brcmfmac/0001-v200ai-sdio-teardown.patch`）两处：

1. `brcmf_sdio_remove()`：**默认跳过 `brcmf_chip_set_passive()`**（模块参数
   `brcmfmac.skip_core_disable=0` 可恢复上游行为）。理由是没有可靠的「芯片还活着」判据：
   任何探测本身就是那条会挂死的 CMD52。本板的恢复路径随后会用 pwrseq 给芯片重新上电并重绑总线，
   这一步没有意义。
2. `brcmf_sdio_bus_stop()`：默认跳过整段 SDIO 寄存器清理（`brcmfmac.skip_bus_stop_io=0`
   可恢复）。死芯片上 `sdio_disable_func` 等每条 CMD52 要等 ~2.5 s，整段约 6 s。
3. `brcmf_sdio_kso_control()`：轮询循环补墙钟上限（原上限是 20000 次 × 50 µs = 1 s 的
   设计意图，但没算每次迭代里的两次 SDIO 访问），放弃时打 `KSO … gave up after N tries`。

两个**失败过**的中间版本，记下来免得重走：

- 只打 (2)：卡死时仍 60 s，且没有 `gave up` 日志 —— 瓶颈不在那条循环。
- 用 `brcmf_sdio_clkctl(CLK_AVAIL)` 的返回值当归零判据：`clkctl` 开头有
  `if (bus->clkstate == target) return 0;` 的提前返回，AP 运行时 `clkstate` 本就是
  `CLK_AVAIL`，根本不会碰硬件，判据恒为真。

构建与替换方式见 [主机构建](build.md)。

### 为什么 BT 补丁会打死 WiFi（2026-11-09 实测结论）

BCM4335 是 combo：WL 与 BT 是两个 core，但共享 PMU / 时钟请求。BT 补丁下载的最后一步是
把 BT core 从 RAM 启动，这一步会**把整颗芯片的 SDIO/backplane 一起重置** —— SDIO 主机侧
仍认为卡已初始化，卡侧状态已变。三种观测都吻合：

| 场景 | 结果 |
| --- | --- |
| WL 固件已跑（AP 或仅关联）+ 下补丁 | WL 立刻不再应答 SDIO（`-110`），hostapd 仍报 ENABLED、日志无 auth 帧 |
| 补丁之后才 `modprobe brcmfmac` | `brcmf_chip_recognition: chip backplane type 15 is not supported`、probe `-19` |
| 补丁之后重绑 SDIO（unbind/bind、pwrseq 上电）+ 加载 WL | 仍然 `backplane type 15`，连试 5 次、跨 60 s 都失败 |
| WL **先成功 probe 过**、再下补丁、再整次重绑 | 恢复并长期稳定（曾连续 980 s 无超时） |

结论：单靠 mmc 重新枚举不足以把芯片恢复到可读状态；能恢复的只有「驱动曾 attach 过 →
补丁 → 彻底重绑」这条路径，也就是 `v200ai-bt-late.sh` 现在做的补丁后自愈。
**不要**再把顺序改成「先 BT 后 WL」或「先 BT 后 AP」：前者 probe 必失败，后者会打出
成片 `data error` 且 AP 起不来（两次都实测过）。

PHY 的法规域由固件管理，缺少可选 CLM blob 的提示仍存在；已验证 ch36 可用，
未验证的信道不可由此推定可用。不要用空文件或其他芯片的 CLM 隐藏提示。

蓝牙走 UART1（PG6–PG9），APB2 24 MHz，运行 1.5 Mbps / 8N2。
`kernel/bluetooth/` 保留实际构建源码及配套 btbcm 修改；与原内核一样构建 UART 协议集合。
`v200ai_speed=1500000` 保证下载前不提前切速。HCD 在 115200 下载完成后，
芯片与主机切到 1.5 Mbps，等待 50 ms 后才发后续 HCI 命令。**不要删除该等待**。
保留既有可配置驱动字段以匹配已部署模块，但不提供扫速/裸 UART 调试脚本。
`zz-bt-late.conf` 阻止自动探测，`v200ai-bt-late.service` 在 WiFi 就绪
（AP ENABLED 或 STA 已关联）后显式 modprobe。
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
