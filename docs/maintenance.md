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
