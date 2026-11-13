# H6 V200-AI 封版维护规则

当前驱动方式已封版。没有新硬件证据或用户明确要求，不再恢复 GPIO、SDIO UHS、
蓝牙波特率或 WiFi 第二 BSS 的探索实验。事实来源为 README、docs 和 board/baseline-sha256.json。

## eMMC 与重启

- 改变板上 eMMC 内容必须逐次获人类明确确认；确认前列出文件路径/SHA256、实测设备/偏移、
  耗时与风险、备份和回滚方法。一次确认只覆盖当次操作。用户明确指令优先。
- 写前确认已有完整 `images/emmc-full.img`；写后 sync 并回读校验。
- 重启、关机、断电由用户执行。读取板上状态和修改主机文件不需额外确认。
- bootloader 位于 eMMC 用户区 8 KiB 偏移；不要写 boot0/boot1，不猜测主机 /dev/sdX。
- 不因清理文档或重建仓库顺手改动设备驱动、供电、启动链或默认网络。

## 必须保留

- Linux `model="H6 V200-AI"`，首个 compatible=`custom,h6-v200ai`。
- SDIO 50 MHz 单沿、4-bit、原 sunxi-mmc；eMMC 52 MHz。
- 蓝牙 AP 就绪后加载，参数 `v200ai_speed=1500000`，切速后等待 50 ms，8N2。
- 保留 RNG、cmac、IOMMU、USB3 PHY、视频依赖及其加载顺序。
- 保留启动载荷加载失败时的 UMS 回落与 initramfs klibc chroot 恢复路径；不使用 FAT 闩控制启动。
- WiFi/BT 固件和 NVRAM 以 SHA256 为准；不要替换成名称相似的固件。

## 排查纪律

- 管理通道优先 USB NCM `192.168.60.1`，AP 是 `192.168.50.1`，两者不同。
- WiFi 可疑时不用 `ip addr show`/`iw station dump` 等 netlink dump，避免 rtnl 死锁；
  使用 sysfs、dmesg 和进程状态。不执行运行中 AP 的 `hostapd -t`。
- 不加载 btsdio、不盲扫 PM/PL GPIO、不创建第二个 BSS。
- 任何 WiFi 运行态试验先备独立 180 秒恢复守护。
- WL_REG_ON/pwrseq 重绑不能当作整板物理冷启动。
- 自建模块严格匹配内核和 vermagic；模块编译只在主机执行，未经确认不安装。

## 公开仓库

只提交最终源码、配置、文档和维护工具。不提交镜像、二进制固件、编译产物、日志、密钥、
网络凭据、配对信息或中间实验。默认 AP 开发密码已公开，不代表私人 STA 密码。
本地恢复材料在仓库外 `../h6-private/`，以及忽略的 `images/`；不得推送这些文件或旧私有历史。
