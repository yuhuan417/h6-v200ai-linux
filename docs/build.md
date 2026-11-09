# 主机构建

构建只写主机的 `build/` 与 `dist/`，不连接板子安装，不自动重启。

## 依赖

Debian 主机需要 Python 3、dtc、make、gcc-aarch64-linux-gnu、binutils-aarch64-linux-gnu、
curl、git、gzip；U-Boot 另需 bison/flex/libssl-dev/swig/python3-dev 与 TF-A。

## DTB 与启动环境

```sh
python3 scripts/build-boot.py
python3 scripts/check-repo.py
```

输出 `dist/v200ai.dtb`、`dist/uboot.env`；DTS 来自实际封版 DTB 的反编译快照。
DTB 重建会重新排列内部字符串，语义往返校验一致，但 SHA256 可与盘上原文件不同；
盘上原文件 SHA256 仍单独记录在 baseline 清单，恢复副本保留在本地。
环境格式为 64 KiB、前四字节 little-endian CRC32，剩余数据 FF 补齐。
`boot/init` 是当前 initrd 使用的 /init；完整 initrd 还需当前匹配模块和 klibc 文件树，
本仓库不把它冒充成完整可启动镜像。

## 外置模块

必须使用板上相同内核的 Debian `6.1.0-54-arm64` / `6.1.190-1` headers、Module.symvers 和 kbuild。
准备 arm64/common headers 以及 linux-kbuild，保持它们的相对路径和符号链接可解析。
arm64 kbuild helper 在 x86 主机上需要 qemu-aarch64 binfmt 或相应原生 helper。

```sh
KERNEL_HEADERS=/path/to/linux-headers-6.1.0-54-arm64 scripts/build-modules.sh
```

脚本在 `build/modules/` 复制源码后构建，避免污染源码树；输出至 `dist/modules/`。
显式设置 CC/LD，避免 Debian headers 默认寻找主机不存在的 gcc-12。
同源码不同编译器或构建路径可能使 SHA256 不同；`board/baseline-sha256.json` 是实际已部署文件指纹，
用于核对既有板子，不宣称任意主机都能逐字节复现。

从 Debian 同版本 `linux-image-6.1.0-54-arm64_6.1.190-1_arm64.deb` 补齐原版模块，至少包括：
dwc3、xhci-hcd、xhci-plat-hcd、roles、ulpi、V4L2/videobuf2/mc、jitterentropy_rng、drbg、cmac、autofs4。
升级内核必须同步重建自建模块，不能只复制旧 ko。

### brcmfmac（外置，含本地补丁）

`kernel/brcmfmac/` 是上游 `v6.1.190` 的 brcmfmac 源码，只加一个补丁
`0001-v200ai-sdio-teardown.patch`：默认跳过 `brcmf_chip_set_passive()`
（参数 `brcmfmac.skip_core_disable=0` 可恢复），另给 KSO 轮询补墙钟上限 ——
CMD52 在 mmc 层没有完成超时，死芯片上一条命令卡 ~54 s。
原因、栈证据和两个失败过的中间版本见 [封版驱动依据](drivers.md)。
约 62 个源文件，`include/` 里的 brcm_* 头已平铺到同目录，
`Makefile` 用 `obj-m := brcmfmac.o`，`-I $(src)`。

构建产物**替换发行版模块** `/lib/modules/6.1.0-54-arm64/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko`，
属于驱动替换：装前备份原 ko，`depmod -a` 后重启验证；失败就在 USB NCM 管理通道上把原 ko 拷回。
vermagic 必须与板上一致（`6.1.0-54-arm64 SMP mod_unload modversions aarch64`），构建后要 `strip --strip-debug`。

## U-Boot

上游 commit：`03e45557e1f38a39a0c80fe30483130ff376cf92`。
Trusted Firmware-A 参考 commit：`da5a281eeb92cce4a3403f1d28c53672537d4e99`，平台 sun50i_h6。
上游仓库为 u-boot/u-boot 和 ARM-software/arm-trusted-firmware。

```sh
git -C /path/to/u-boot checkout 03e45557e1f38a39a0c80fe30483130ff376cf92
git -C /path/to/u-boot apply /path/to/h6-v200ai-linux/uboot/patches/*.patch
cp uboot/configs/v200ai_defconfig /path/to/u-boot/configs/
make -C /path/to/u-boot v200ai_defconfig
make -C /path/to/u-boot CROSS_COMPILE=aarch64-linux-gnu- BL31=/path/to/bl31.bin -j4
```

这些补丁中仍使用上游参考板的 U-Boot DTS 文件名，这是既有 bootloader 构建路径，
不代表实际板子是 OrangePi；Linux 板名已经独立改成 H6 V200-AI。
保留上游路径是为避免改变已工作的 bootloader；不安装新的 U-Boot 优化或压缩内核方案。
当前已安装 bootloader 与历史构建件不逐字节一致，启动载荷已留本地恢复副本，
因此上述构建只说明来源与方法，不作为已验证的替代镜像自动刷入。

## 固件与 locale

固件按 [固件清单](../firmware/README.md) 获取并校验，本仓库没有旧 2013 WiFi 镜像下载脚本。
`en_US.UTF-8` 可用匹配 Debian locales 源数据和板上 localedef 生成，
已部署路径 `/usr/lib/locale/en_US.utf8/`；不必改变默认 LANG 或关闭 SSH 的语言变量转发。
