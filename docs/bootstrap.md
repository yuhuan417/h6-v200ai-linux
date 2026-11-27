# 从零 bootstrap:裸板到可启动系统

按操作顺序记录。每一步都能单独验证;失败时停在该步,不要跳过。
本文是仓库里唯一的流程文档,构建、刷写、板级约束和回滚都在这里。

板上 eMMC 布局(两段):

| 分区 | 位置 | 大小 | 用途 |
| --- | --- | --- | --- |
| p1 | LBA 2048 | 128 MiB FAT32 | `/boot/firmware`:`Image`、`initrd.img`、`v200ai.dtb`、`uboot.env` |
| p2 | LBA 264192 | 到盘尾(约 7.0 GiB)ext4 | `/`,`PARTUUID=8d68c129-02` |

磁盘 ID 固定 `0x8d68c129`,bootloader 写在用户区 **8 KiB** 偏移(不是 boot0/boot1)。

## 0. 主机依赖

Debian 主机:

```sh
sudo apt-get install -y python3 dtc make gcc-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu curl git gzip xz-utils cpio rsync \
    dosfstools e2fsprogs debootstrap qemu-user-static
# U-Boot 还需要
sudo apt-get install -y bison flex libssl-dev swig python3-dev
```

另外需要 `sunxi-fel`(Allwinner FEL 工具)和 **qemu-aarch64 binfmt**(构建 rootfs 与
initrd 时要在 x86 主机上运行 arm64 程序):

```sh
ls /proc/sys/fs/binfmt_misc/ | grep aarch64      # 应看到 qemu-aarch64
```

Windows 主机(UMS 直写阶段):管理员 PowerShell,`tools/flash-part.ps1` 不需要额外组件。

## 1. 进入 FEL,构建 U-Boot/SPL 并初始化 DRAM

拿到的板子先不要假设 eMMC 里有什么,直接进 FEL 观察。

### 1.1 构建 U-Boot

上游 commit `03e45557e1f38a39a0c80fe30483130ff376cf92`;Trusted Firmware-A 参考 commit
`da5a281eeb92cce4a3403f1d28c53672537d4e99`,平台 sun50i_h6。

```sh
git -C /path/to/u-boot checkout 03e45557e1f38a39a0c80fe30483130ff376cf92
git -C /path/to/u-boot apply /path/to/h6-v200ai-linux/uboot/patches/*.patch
cp uboot/configs/v200ai_defconfig /path/to/u-boot/configs/
make -C /path/to/u-boot v200ai_defconfig
make -C /path/to/u-boot CROSS_COMPILE=aarch64-linux-gnu- BL31=/path/to/bl31.bin -j4
```

产物 `u-boot-sunxi-with-spl.bin` 里 SPL 在 8 KiB、FIT 紧随其后。补丁中仍沿用上游参考板的
DTS 文件名,这是既有 bootloader 构建路径,不代表板子是 OrangePi(Linux 板名已独立改成
H6 V200-AI)。

**bootloader 必须具备的能力**:`ums`(USB mass storage)、`fatload`/`fatwrite`/`fatrm`
(p1 的启动文件和两个一次性开关),`v200ai_defconfig` 已包含;缺任何一条,第 2、4 步都不成立。

调试用的另一种构建:打开 `CONFIG_SPL_BOARD_INIT`、`CONFIG_MMC_WRITE`、
`CONFIG_V200AI_FEL_PAYLOAD` 并关掉 `SPL_SERIAL`(否则 32 KiB SRAM 放不下),
见 [tools/fel-emmc/README.md](../tools/fel-emmc/README.md)。

### 1.2 通过 FEL 加载 SPL 初始化 DRAM

板子断电后触发 FEL,主机确认:

```sh
sunxi-fel ver      # 期望 soc=00001728(H6)
sunxi-fel -l       # 1f3a:efe8
sunxi-fel spl spl/sunxi-spl.bin
```

这一步只初始化 DRAM 并返回 FEL,不写任何东西。SPL 返回后 DRAM 才可访问——FEL 状态本身
不能访问 DRAM,`sunxi-fel writel` 在 SPL 之前会超时。

### 1.3 仓库保留 SPL 读写 eMMC 的能力

读写**不塞进 SPL**,而是 offload 到 DRAM payload:SPL 只做 DRAM 初始化 + 导出
`sunxi_mmc` 函数表(`uboot/patches/0002-v200ai-fel-payload.patch`),真正的读、写、
切 boot 分区、改时钟在 [tools/fel-emmc/payload.c](../tools/fel-emmc/payload.c),
运行在 DRAM,**不受 SPL 32 KiB 限制**,读写在同一份代码里。

主机侧 [tools/fel-emmc/fel_emmc.py](../tools/fel-emmc/fel_emmc.py) 装载 payload、下发参数、
回读结果。约束(实测):

- 单次传输超过若干个块会让 `sunxi_mmc` 的 FIFO 通路卡住 → payload 内部按 16 块搬运,
  主机侧每次最多下发 512 块;
- SPL 开 `MMC_WRITE` 后超出 32 KiB SRAM,必须同时关 `SPL_SERIAL`;
- 写操作直接改 eMMC,目标 LBA 由命令行给出,写前需人类确认、写后回读比对。

## 2. 写分区表、bootloader 与 p1 骨架,再从 UMS 灌启动文件

### 2.1 用 FEL 工具写三块区域

每块写完都回读校验(工具自带 `--verify`):

```sh
./tools/fel-emmc/fel_emmc.py flash dist/mbr.bin --lba 0 --verify
./tools/fel-emmc/fel_emmc.py flash dist/bootloader-area.bin --lba 16 --verify
./tools/fel-emmc/fel_emmc.py flash dist/p1-meta.bin --lba 2048 --verify
```

| 区域 | 内容 | 大小 |
| --- | --- | --- |
| LBA 0 | `dist/mbr.bin`:p1 128 MiB FAT32(`0x0c`)、p2 ext4 到盘尾(`0x83`),磁盘 ID `0x8d68c129` | 512 B |
| LBA 16–2047 | `dist/bootloader-area.bin`,`eGON.BT0` 头 | 1,040,384 B |
| LBA 2048 起 | **p1 的 FAT32 元数据**,不是整片 | 1,057,792 B |

`bootloader-area.bin` 从 1.1 的构建产物截取:

```sh
dd if=build/src/u-boot/u-boot-sunxi-with-spl.bin \
   of=dist/bootloader-area.bin bs=512 skip=16 count=2032
```

三块的生成脚本:`scripts/build-mbr.py`、`scripts/build-p1-meta.py`(见 2.2)。

### 2.2 p1 只写元数据

空 FAT32 只需要保留扇区 + 两份 FAT + 根目录簇。128 MiB 用 1 KiB 簇时是
`32` 保留扇区 + `2×1016` 扇区 FAT + 1 KiB 根目录簇 = **1,057,792 B**,130,040 个簇。
数据区留空即可——所有簇在 FAT 里都是"空闲",没人会读。

```sh
python3 scripts/build-mbr.py        # -> dist/mbr.bin
python3 scripts/build-p1-meta.py    # -> dist/p1-meta.bin
```

两者都用固定 ID 生成、输出可复现;`scripts/check-repo.py` 校验分区表项、p2 末端、FAT32 标记、
1 KiB 簇和保留扇区数。

不要用 2 KiB 簇(`-s 4`):128 MiB 只有 65,272 簇,低于 FAT32 的 65,525 门限,
Linux 会按 FAT16 挂载。

### 2.3 上电进 UMS

此时 p1 里没有 env、没有 Image,U-Boot 读 env 失败后退到编译进二进制的默认
`bootcmd=ums 0 mmc 1`,主机侧看到 `BOOT` 卷(FAT32,127 MiB 可用)。

### 2.4 准备并拷入四个启动文件

**Image(内核,不编译)**:取 Debian bookworm 的签名包,**不在 `linux/` 目录,而在
`linux-signed-arm64/`**:

```sh
curl -LO https://security.debian.org/debian-security/pool/updates/main/l/linux-signed-arm64/linux-image-6.1.0-54-arm64_6.1.190-1_arm64.deb
dpkg-deb -x linux-image-6.1.0-54-arm64_6.1.190-1_arm64.deb build/linux-image
cp build/linux-image/boot/vmlinuz-6.1.0-54-arm64 Image
```

| 项 | 值 |
| --- | --- |
| 大小 | 32,956,352 B |
| SHA256 | `cbc7dcd22b574dee70d2ebe575a525ed7dfeb04aaccc2da67c0b1a776d971098` |
| 类型 | `Linux kernel ARM64 boot executable Image`(未压缩,`booti` 直接引导) |

**不要用 `-unsigned` 包**:`linux-image-6.1.0-54-arm64-unsigned` 里的 `vmlinuz` 是
32,954,880 B,比签名版少 1,472 字节(尾部 PKCS#7 签名),公共前缀只有 9 字节不同,哈希对不上。
包内 `boot/config-6.1.0-54-arm64` 与仓库 `kernel/config-6.1.0-54-arm64` 同为
`8d3bcecc…`,可作取包正确性的旁证。

**initrd.img**:Debian initramfs-tools 树 + 定制 `/init`,gzip + cpio newc。重建在 arm64
chroot 里完成(不需要板子):

```sh
debootstrap --arch=arm64 --variant=minbase \
    --include=klibc-utils,kmod,udev,systemd,initramfs-tools,dmsetup \
    bookworm /path/to/root http://deb.debian.org/debian
echo 'deb http://security.debian.org/debian-security bookworm-security main' \
    | sudo tee -a /path/to/root/etc/apt/sources.list
sudo chroot /path/to/root /bin/sh -c 'apt-get update && apt-get -y dist-upgrade'
# 模块直接用内核包里的(不重编),并放入 config 供 mkinitramfs 判断压缩支持
sudo cp -a /path/to/kdeb/lib/modules/6.1.0-54-arm64/. /path/to/root/lib/modules/6.1.0-54-arm64/
sudo cp /path/to/kdeb/boot/config-6.1.0-54-arm64 /path/to/root/boot/
sudo chroot /path/to/root /bin/sh -c 'depmod -a 6.1.0-54-arm64 && mkinitramfs -o /tmp/base.img 6.1.0-54-arm64'
```

`initramfs.conf` 里 `COMPRESS=zstd`,chroot 没有 zstd 时会退到 gzip——板上那版就是 gzip。
`MODULES=most` 生成约 35 MB,需要裁到 45 个模块(相对 `usr/lib/modules/6.1.0-54-arm64/`):

```
kernel/block/t10-pi.ko
kernel/crypto/crc32c_generic.ko
kernel/crypto/crc32_generic.ko
kernel/crypto/crct10dif_common.ko
kernel/drivers/leds/leds-gpio.ko
kernel/drivers/mfd/axp20x.ko
kernel/drivers/mfd/axp20x-rsb.ko
kernel/drivers/mmc/host/sunxi-mmc.ko
kernel/drivers/mmc/host/tmio_mmc_core.ko
kernel/drivers/phy/allwinner/phy-sun4i-usb.ko
kernel/drivers/regulator/axp20x-regulator.ko
kernel/drivers/regulator/fixed.ko
kernel/drivers/scsi/scsi_common.ko
kernel/drivers/scsi/scsi_mod.ko
kernel/drivers/scsi/sd_mod.ko
kernel/drivers/usb/common/usb-common.ko
kernel/drivers/usb/core/usbcore.ko
kernel/drivers/usb/gadget/function/usb_f_acm.ko
kernel/drivers/usb/gadget/function/u_serial.ko
kernel/drivers/usb/gadget/legacy/g_serial.ko
kernel/drivers/usb/gadget/libcomposite.ko
kernel/drivers/usb/gadget/udc/udc-core.ko
kernel/drivers/usb/host/ehci-hcd.ko
kernel/drivers/usb/host/ehci-platform.ko
kernel/drivers/usb/host/ohci-hcd.ko
kernel/drivers/usb/host/ohci-platform.ko
kernel/drivers/usb/musb/musb_hdrc.ko
kernel/drivers/usb/musb/sunxi.ko
kernel/drivers/usb/phy/phy-generic.ko
kernel/drivers/usb/storage/usb-storage.ko
kernel/fs/configfs/configfs.ko
kernel/fs/ext4/ext4.ko
kernel/fs/fat/fat.ko
kernel/fs/fat/vfat.ko
kernel/fs/jbd2/jbd2.ko
kernel/fs/mbcache.ko
kernel/fs/nls/nls_ascii.ko
kernel/fs/nls/nls_cp437.ko
kernel/fs/nls/nls_iso8859-1.ko
kernel/fs/nls/nls_utf8.ko
kernel/lib/crc16.ko
kernel/lib/crc64.ko
kernel/lib/crc64-rocksoft.ko
kernel/lib/crc-t10dif.ko
kernel/lib/libcrc32c.ko
```

其中 `g_serial`/`libcomposite`/`u_serial`/`usb_f_acm`(USB 串口恢复)、`fat`/`vfat`/`nls_*`
(p1 的 FAT 读取)、`leds-gpio` 是板上额外加的,`MODULES=most` 不会自动带上。

`/init` 用仓库的 `boot/init`,它挂 `/dev/mmcblk1p2`(现行两分区布局)到 `/rootfs` 后
`exec chroot`;历史封版板(2026-11-03,root 在 p3)才需要挂 `p3` 的那一版,不要混用。

```sh
cd tree && find . -print0 | cpio --null -o -H newc --owner=0:0 | gzip -9 > initrd.img
```

**v200ai.dtb 与 uboot.env**:仓库生成,不取板上副本。

```sh
python3 scripts/build-boot.py       # -> dist/v200ai.dtb, dist/uboot.env
```

DTB 来自 `board/h6-v200ai.dts`;重建会重排内部字符串,语义往返一致但 SHA256 可与盘上原文件
不同(`a6be7c52…` 是原文件指纹)。env 格式为 64 KiB、前四字节 little-endian CRC32,
其余 `0xFF` 补齐;`boot/uboot-env.txt` 是当前文本,`root=PARTUUID=8d68c129-02`。

**拷进 p1** 并校验:

```powershell
Copy-Item Image,initrd.img,v200ai.dtb,uboot.env D:\
Write-VolumeCache -DriveLetter D
Get-FileHash D:\Image,D:\initrd.img,D:\v200ai.dtb,D:\uboot.env
```

## 3. 构建 rootfs 镜像

```sh
sudo scripts/build-rootfs.sh -s 3072 -o dist/rootfs.img
```

产物是紧凑 ext4(实测 1,233 MiB,`e2fsck -fn` 通过),内容全部来自 Debian 源 + 本仓库,
**不依赖任何板子备份**:

1. `mkfs.ext4`(固定 UUID,3 GiB 起步);
2. `debootstrap --arch=arm64 bookworm`(`main,contrib,non-free,non-free-firmware`);
3. 按 [rootfs/packages.txt](../rootfs/packages.txt) 装 **204** 个包——含 WiFi/蓝牙
   (`bluez`、`hostapd`、`dnsmasq`、`wpasupplicant`、`iw`、`rfkill`、
   `firmware-brcm80211`)、USB 串口与复合 gadget(`systemd`、`udev`、`kmod`、
   `initramfs-tools`、`usbutils`)、内核(`linux-image-6.1.0-54-arm64`)和基础系统。
   **内核 ABI 固定 54**:清单刻意不装 `linux-image-arm64` meta(它总跟随最新 ABI,
   会白加约 330 MB 模块和 initrd);脚本装完断言 `/lib/modules` 只有一个 `6.1.0-54-arm64`;
4. 覆盖 `rootfs/`(配置、脚本、systemd 单元);
5. 安装 `firmware/` 三个 BCM4335 固件并建 `custom,h6-v200ai` 别名链接;
6. 写 `fstab`(`root=…-02`、`/boot/firmware=…-01`),启用 `usbgadget`、`v200ai-ap`、
   `v200ai-bt-late`、`v200ai-growroot`、`v200ai-latch`、`serial-getty@ttyGS0`、`ssh`、
   `networkd`、`bluetooth`;`v200ai-bt-tether` 只保留能力、不 enable;
   `hostapd`/`dnsmasq`/`wpa_supplicant` 三个 unit 只删开机自启链接(单元保留,运行时由
   `wifi-mode.sh` 按模式启动,原因见 6.1.4);
7. 生成 locale:`apt-get install locales` → 写 `/etc/locale.gen` → `locale-gen` →
   写 `/etc/default/locale` 为 `LANG=C.UTF-8`。**保留 `locales` 包不要 purge**:
   bookworm 的 postrm 在 purge 时会连 `/usr/lib/locale/` 下生成的数据一起删掉
   (主机上的 2.41 版不会),purge 完警告会重新出现。不做这一步,ssh 转发
   `LC_ALL=en_US.UTF-8` 时每次登录都会打 `setlocale: cannot change locale`;
8. 构建并安装外置模块(见第 7 节),`depmod -a 6.1.0-54-arm64`;
9. 清理 apt 缓存、清空 `machine-id`、`resize2fs -M`、`e2fsck -fn`。

## 4. 把镜像写进 p2

p1 的 FAT 里放一个 1 字节的 `p2ums`,上电后 U-Boot 先 `fatrm` 删掉它,再执行
`ums 0 mmc 1:2`:主机只看到 p2,一个约 **7.0 GiB、没有文件系统**的盘。

```powershell
# Windows,管理员 PowerShell;DiskNumber 用 Get-Disk 查,按容量/型号确认
powershell -ExecutionPolicy Bypass -File tools\flash-part.ps1 `
    -Image rootfs.img -DiskNumber <n> -Force -Verify
```

脚本直接写 `\\.\PhysicalDrive<n>`,4 MiB 一块,末尾 `Flush($true)`,再回读整个范围算 SHA256
与源文件比对。实测 1,233 MiB 用时 **247 s(≈5.2 MB/s)**,校验一致。

- p2-only 的盘在 Windows 里可能被误判成 FAT16 分区,所以需要 `-Force`;
- removable 盘不能 offline,但盘上没有任何可挂载的文件系统,直写不需要离线也不需锁卷;
- `p2ums` 是一次性开关:U-Boot 在进入 p2-only **之前**就 `fatrm` 掉它,所以不会残留状态。

## 5. 首次启动与验收

`p2ums` 已被消费;p1 上若有 `guard.bin` 会先进整盘 UMS:**删掉 `guard.bin` 再上电**,
这次 U-Boot 创建闩并引导 initrd → p2 上的 Debian。

### 5.1 p1 文件的行为

| p1 文件 | 行为 |
| --- | --- |
| `p2ums`(≥1 字节) | 先 `fatrm` 删掉,再 `ums 0 mmc 1:2`(只暴露 p2) |
| `guard.bin` | 直接 `ums 0 mmc 1`(整盘,p1 可见,供修启动文件) |
| 两者都没有 | 先 `fatwrite` 创建 `guard.bin`,再引导 Debian |
| `noswitch` | initramfs 停在 USB 串口 shell(Linux 启动之后生效) |

`guard.bin` 是一次性闩:U-Boot 每次启动都先创建它,只有 Linux 起来之后由
`v200ai-latch.service` 删除(`rm -f /boot/firmware/guard.bin`,`RequiresMountsFor=/boot/firmware`)。
引导失败时闩留在 p1 上,下次上电直接进 UMS;加载 `Image`、`initrd.img` 或 DTB 失败、
以及 `booti` 返回时,U-Boot 同样进 UMS。`umshold.flag` 已废弃。

### 5.2 验收(实测值)

| 检查 | 期望 |
| --- | --- |
| `uname -r` / `ls /lib/modules` | `6.1.0-54-arm64`,只有一个 ABI |
| `dpkg -l \| grep -c '^ii'` | 204 |
| `sha256sum /lib/firmware/brcm/brcmfmac4335-sdio.bin` | `d9fb3542…fdee2` |
| `lsblk /dev/mmcblk1` | p1 128M `/boot/firmware`,p2 7G `/` |
| `df -h /` | 约 6.9G,`v200ai-growroot` 已把文件系统扩到分区满尺寸 |
| `/var/lib/v200ai-growroot.done` | 存在(扩容成功后才会写) |
| `systemctl is-active v200ai-ap v200ai-bt-late v200ai-latch usbgadget` | 全部 `active` |
| `iw dev wlan0 info` | `ssid v200ai`、`type AP`、`channel 149 (5745 MHz), width: 80 MHz` |
| `hciconfig hci0` | `Bus: UART`、`UP RUNNING`;BD Address 是本地管理地址(`02:…`) |
| `cat /sys/class/net/wlan0/address` | 芯片 OTP 地址(如 `5c:f8:a1:…`) |
| `ls /boot/firmware` | 四个文件,**没有** `guard.bin`(启动成功后 latch 已删) |
| `dmesg \| grep brcmfmac` | `Firmware: BCM4335/1 … version 6.30.171.24.64`,`clm_blob` 缺失属正常 |

### 5.3 开发默认值

AP 密码 `v200ai1234`;USB NCM 管理地址 `192.168.60.1`;AP 网段 `192.168.50.1`;
串口 `ttyGS0` 是 `--autologin root`。新 rootfs **不带任何凭据**:没有 SSH 公钥、没有
STA 凭据、没有蓝牙配对记录,ssh 需要自行放公钥或设密码。

### 5.4 仍会出现的提示(不是故障)

- `brcmfmac4335-sdio.clm_blob` 缺失:可选 CLM,不阻塞已验证的 AP;不要用空文件或别的芯片的 CLM 掩盖;
- NVRAM 里的 `macaddr=00:90:4c:c5:12:38` 是模板值,不生效,实际用 OTP 地址;
- 自建模块未签名,内核带 O/E taint(未启用强制签名);
- Cedrus 属 staging 驱动;部分 regulator 是 dummy provider,DT 声明不等于物理电压;
- WiFi STA 与 AP 单独可用,**当前固件/驱动组合不支持 STA+AP 并发**;
- 红外接收不可用:DTS 里 `ir@7040000` 是 `status = "okay"`,但 Debian 未编
  `CONFIG_IR_SUNXI`,本镜像也不外置该模块(已确认不需要红外遥控);
- `CONFIG_SND_SUN4I_SPDIF` 未编,但 DTS 的 `spdif@5093000` 是 `status = "disabled"`,无影响。

## 6. 板级约束

### 6.1 WiFi 与蓝牙的初始化时序(照好板复刻,改动前必须读完)

这一节是整个 bootstrap 里最反直觉的部分:**WiFi 与蓝牙不能并行,更不能先蓝牙**。
好板上的顺序是被实测逼出来的,任何"优化"都会让 AP 起不来或蓝牙失效。

#### 6.1.1 硬件事实

BCM4335 是 combo:WL 与 BT 是两个 core,但共享 PMU 和时钟请求。BT 补丁(HCD)下载的
最后一步是把 BT core 从 RAM 里启动,这一步会**把整颗芯片的 SDIO/backplane 一起重置**——
SDIO 主机侧仍认为卡已初始化,卡侧状态已经变了。实测四种场景:

| 场景 | 结果 |
| --- | --- |
| WL 固件已跑(AP 或已关联)+ 下补丁 | WL 立即不应答(`-110`);hostapd 仍报 ENABLED、日志无 auth 帧 |
| 补丁之后才 `modprobe brcmfmac` | `brcmf_chip_recognition: chip backplane type 15 is not supported`,probe `-19` |
| 补丁之后重绑 SDIO 再加载 WL | 仍 `backplane type 15`,连试 5 次、跨 60 s 都失败 |
| WL 先成功 probe → 补丁 → 彻底重绑 | 恢复并长期稳定(曾连续 980 s 无超时) |

结论:**能恢复的只有"驱动曾 attach 过 → 下补丁 → 彻底重绑"这一条路径**,也就是
`v200ai-bt-late.sh` 做的事。

#### 6.1.2 时间线(开机到 AP)

| 时刻 | 事件 | 谁做的 | 判据 |
| --- | --- | --- | --- |
| T0 | brcmfmac 由 **udev** 按 modalias 自动加载(不是 `modules-load.d`),固件取 `brcmfmac4335-sdio.custom,h6-v200ai.bin` + `.txt`;SDIO 4-bit / SD-HS / 50 MHz | udev + 内核 | dmesg `brcmf_fw_alloc_request: using brcm/brcmfmac4335-sdio`、`Firmware: BCM4335/1 … 6.30.171.24.64` |
| T0+约 60–72 s | `wlan0` 出现,phy 被标 self-managed(country 99) | 同上 | `ls /sys/class/net/wlan0` |
| T1 | `usbgadget.service` 建 ACM+NCM,管理通道 `192.168.60.1` 先就绪(后续所有恢复的前提) | `After=systemd-modules-load local-fs` | `ip -4 addr show usb0` |
| T2 | `v200ai-bt-late.service` → `v200ai-bt-late.sh` 等 `wlan0` | 脚本 | 日志 `brcmfmac 已 attach` |
| T2 | 判活:`timeout 1 iw dev wlan0 info \| grep -E '^\s*channel [0-9]'` | 脚本 | 卡死时 `iw` 退出码仍是 0,**必须看输出内容** |
| T2 | `modprobe hci_uart`(`v200ai_speed=1500000`):115200 下载 HCD,完成后切 1.5 Mbps 8N2 并**等 50 ms** | 内核 btbcm + 补丁 | dmesg `Patch` → `build 0353` |
| T2 | `hciconfig hci0 up`,等 `UP RUNNING` | 脚本 | 日志 `hci0 已 UP RUNNING` |
| T2 | 补丁后 WiFi 通常已失联 → `sdio-reset.sh` 重绑,再等 channel 行回来 | 脚本 | 日志 `重绑后控制通道已恢复` |
| T3 | `v200ai-ap.service` → `v200ai-wifi-boot.sh` 等 `wlan0`,读 `/etc/v200ai-wifi-mode`(`ap`/`sta`,缺省 `ap`),首选失败回退另一种 | `After=v200ai-bt-late` | 日志 `[wifi-boot] ap ready` |
| T3 | `wifi-mode.sh ap`:置 `ip_forward` → 停 STA → `ip link down` → `iw set type __ap` → 写 hostapd/dnsmasq 配置 → `hostapd -B` → 轮询 `hostapd_cli status` 到 `state=ENABLED` → 起 dnsmasq → 等 `192.168.50.1` | 脚本 | `ssid v200ai`、`channel 149 (5745 MHz), width: 80 MHz` |
| T4 | `v200ai-bt-tether.service` 默认不启用,只保留"AP 守护 + iPhone PAN 重连"能力 | — | — |

脚本里的等待上限都是设计值,不要随手改大改小:等 `wlan0` 30 s(bt-late)/120 s(wifi-boot)、
等 `build 0353` 30 s、等 `hci0 UP RUNNING` 20 s、重绑后等 channel 5×1 s、判活单次超时 1 s。

#### 6.1.3 五条不可更改的不变量

1. **BT 不能在 WiFi attach 之前加载**:`/etc/modprobe.d/zz-bt-late.conf` 里 `blacklist hci_uart`,
   由 bt-late 服务显式 `modprobe`;
2. **brcmfmac 不能在 BT 补丁之后再 probe**:否则 `backplane type 15` / `-19`,只能整板断电;
3. **AP 必须在 bt-late 之后启动**:`v200ai-ap.service` 的 `After=v200ai-bt-late`,否则补丁把 AP 打死;
4. **ap 与 bt-late 不能互相 After**:只允许 bt-late 写 `Before=v200ai-ap`;互相依赖会成环,
   启动自锁到 `TimeoutStartSec`;
5. **`sdio-reset.sh` 是对 `4021000.mmc` 做 unbind/bind 重新触发 pwrseq**,不等于物理断电,
   不能当冷启动验证。

#### 6.1.4 其它必须保持的细节

- `blacklist btsdio`:它会绑 SDIO function 3 造"幽灵 hci0",`hciconfig hci0 up` 会把 WiFi 搞崩;
- `options hci_uart v200ai_speed=1500000`:保证下载前不提前切速;**切速后的 50 ms 等待不能删**;
- `cmac`、`jitterentropy_rng`、`drbg` 必须早于 bluetooth 加载(ECDH p256 自检、BLE 安全配对);
- WiFi 判活只看 `channel` 行——固件卡死时 `iw` 仍返回 0;
- AP 模式下 dnsmasq 必须 `dhcp-host=<wlan0 自身 MAC>,ignore`,否则 networkd 会向自己的
  dnsmasq 租地址、把 `192.168.50.1` 顶掉;
- STA 模式重绑或从 AP 切过来后必须 `networkctl reconfigure wlan0`,networkd 不会自己重试 DHCP;
- **这三个守护进程由 `wifi-mode.sh` 独占控制,不要 `enable`(不要开机自启)**,但它们在运行时
  都要用,只是由脚本按当前模式按需启动:
  - `dnsmasq`:AP 模式下脚本 `systemctl start --no-block dnsmasq`(单元保留,只是不 enable);
  - `wpa_supplicant`:STA 模式下启动**模板实例** `wpa_supplicant@wlan0`(读
    `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`),不是通用的 `wpa_supplicant.service`;
  - `hostapd`:脚本直接 `hostapd -B /etc/hostapd/hostapd.conf` 启动进程,绕过单元。
  为什么不能 enable:hostapd 开机启动时 wlan0 还没出现(要 60–72 s),STA 模式下还会和
  wpa_supplicant 抢接口;dnsmasq 开机启动时 `/etc/dnsmasq.d/v200ai-ap.conf` 还没生成;
  通用 `wpa_supplicant.service` 会和 `@wlan0` 实例抢同一张卡。
  `build-rootfs.sh` 去掉的只是这三个 unit 的 `multi-user.target.wants` 链接,单元文件本身保留。

### 6.2 CPU 频率与温控

`sun8i_thermal` 提供温区,`v200ai_cpufreq`(外置模块)把 CPU 时钟注册成 cooling device,
接管 DTB 里已有的 85 °C 被动降频与 100 °C critical。因为 AXP805/806 供电未验证,
**只降频不调压,也不改 DTB 和 governor**。加载顺序是硬要求:先 `sun8i_thermal`(温区),
后 `v200ai_cpufreq`(cooling device),对应 `rootfs/etc/modules-load.d/v200ai-cpufreq.conf`。

### 6.3 Type-A USB 网卡(RTL8156,CDC-NCM)

`0bda:8156` 有三个 configuration:1=vendor(r8152)、2=CDC-NCM、3=CDC-ECM。usbcore 会跳过
首接口是 vendor 类的 config,选 config 2;而 r8152 的 `cfgselector` 会 `usb_set_configuration`
切到 vendor config,然后死在读 `PLA_CONFIG34(0xe820)`:`Failed to read 4 bytes ... (-71)`。

因此**不要安装或加载 r8152**,只补 `mii`、`usbnet`、`cdc_ether`、`cdc_ncm` 四个原版模块,
由 `rootfs/etc/modules-load.d/v200ai-usbnet.conf` 开机加载。Type-A 的 USB2 信号要经过
`phy@5210000` 的 USB3 组合 PHY,Debian 内核未启用,需外置 `phy_sun50i_usb3` 模块,
且 PHY 必须先于 `dwc3` 加载。H6 IOMMU 也是外置模块,需早于 `sunxi_cedrus`/DRM。

## 7. ⚠ 外置模块构建(改动内核模块前必读)

> **⚠ 这一节不是可选内容。**
> 板上几个关键能力——WiFi 的 brcmfmac 补丁、蓝牙 `hci_bcm` 的 50 ms 等待、CPU 温控、
> Type-A 的 USB3 PHY、H6 IOMMU、RTL8156 的 CDC-NCM 依赖——都来自**外置模块**,
> 它们必须与板上内核严格对齐(vermagic),而 brcmfmac 是**替换**发行版模块。
> 装错版本不会"报错退出",而是 WiFi/蓝牙/温控静默失效,排查成本极高。
> 任何内核升级、模块重建、驱动替换,先读完这一节再动手。

必须使用板上相同内核的 Debian `6.1.0-54-arm64` / `6.1.190-1` headers、`Module.symvers` 和
kbuild;准备 arm64/common headers 与 linux-kbuild,保持相对路径和符号链接可解析。
x86 主机上 arm64 kbuild helper 需要 qemu-aarch64 binfmt。

```sh
KERNEL_HEADERS=/path/to/linux-headers-6.1.0-54-arm64 scripts/build-modules.sh
```

脚本在 `build/modules/` 复制源码后构建,避免污染源码树;输出到 `dist/modules/`。
显式设置 CC/LD,避免 Debian headers 去找主机上不存在的 `gcc-12`。同源码、不同编译器或
构建路径可能得到不同 SHA256;`board/baseline-sha256.json` 是**实际已部署文件**的指纹,
用于核对既有板子,不宣称任意主机都能逐字节复现。

从同版本 Debian 内核包补齐的原版模块至少包括:`dwc3`、`xhci-hcd`、`xhci-plat-hcd`、
`roles`、`ulpi`、V4L2/videobuf2/mc、`jitterentropy_rng`、`drbg`、`cmac`、`autofs4`、
`sun8i_thermal`、`mii`、`usbnet`、`cdc_ether`、`cdc_ncm`。**升级内核必须同步重建自建模块,
不能只复制旧 ko。**

### 7.0 安装位置(照封版板)

`build-rootfs.sh` 在装完包之后自动构建并安装这五个模块,目标路径与封版板一致:

| 产物 `dist/modules/…` | 安装到 `/lib/modules/6.1.0-54-arm64/` | 方式 |
| --- | --- | --- |
| `bluetooth/hci_uart.ko` | `kernel/drivers/bluetooth/hci_uart.ko` | 覆盖发包自带 |
| `bluetooth/btbcm.ko` | `kernel/drivers/bluetooth/btbcm.ko` | 覆盖发包自带 |
| `brcmfmac/brcmfmac.ko` | `kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko` | 覆盖 |
| `iommu/sun50i-iommu.ko` | `kernel/drivers/iommu/sun50i-iommu.ko` | 新增(Debian 未编) |
| `usb3/phy-sun50i-usb3.ko` | `kernel/drivers/phy/allwinner/phy-sun50i-usb3.ko` | 新增(Debian 未编) |
| `cpufreq/v200ai_cpufreq.ko` | `extra/v200ai_cpufreq.ko` | 新增(自建) |

装完必须 `depmod -a 6.1.0-54-arm64`,否则 `modules-load.d` 里的模块名解析不到。
headers 只用于编译:脚本从 chroot 里 `apt-get download` 同版本 headers 解到
`build/kernel-headers/`,不装进镜像,所以镜像不会因此变大。

两个容易卡住的点(实测踩过):

1. 除了 `linux-headers-6.1.0-54-arm64`、`linux-headers-6.1.0-54-common`,还需要
   **`linux-kbuild-6.1`**——`scripts/basic/fixdep` 由它提供,缺了会报
   `/bin/sh: 1: scripts/basic/fixdep: not found`;
2. Debian 的 arm64 headers 里 `Makefile` 只有一行
   `include /usr/src/linux-headers-6.1.0-54-common/Makefile`(绝对路径),所以解包出来的树
   必须在 `/usr/src` 可见;而 common 包里的 `scripts` 是指向
   `../../lib/linux-kbuild-6.1/scripts` 的相对符号链接,挂到 `/usr/src` 之后它会解析成
   `/usr/lib/linux-kbuild-6.1/scripts`,所以**两个目录都要挂**:

   ```sh
   mount --bind build/kernel-headers/usr/src /usr/src
   mount --bind build/kernel-headers/usr/lib/linux-kbuild-6.1 /usr/lib/linux-kbuild-6.1
   KERNEL_HEADERS=/usr/src/linux-headers-6.1.0-54-arm64 scripts/build-modules.sh
   ```

   构建完立刻 umount,不往主机 `/usr/src`、`/usr/lib` 写任何文件。

### 7.1 v200ai_cpufreq

`kernel/cpufreq/` 单文件、无外部依赖,产物 `dist/modules/cpufreq/v200ai_cpufreq.ko`。
它复用内核已有的 CPU 时钟驱动和 DTB 温区,**不访问 PMIC、不改 DTB、不改 governor**,
所以不需要重编内核:`kernel/config-6.1.0-54-arm64` 里 `CONFIG_CPU_FREQ`、
`CONFIG_CPU_FREQ_GOV_SCHEDUTIL`、`CONFIG_CPU_FREQ_THERMAL`、`CONFIG_THERMAL_OF` 已开启,
`CONFIG_SUN8I_THERMAL=m` 由 Debian 原包提供。

部署(属于写 eMMC,按 AGENTS.md 逐次确认;`sun8i_thermal` 已在板上,不要删):

```sh
install -D -m 644 dist/modules/cpufreq/v200ai_cpufreq.ko \
  /lib/modules/$(uname -r)/extra/v200ai_cpufreq.ko
depmod -a
install -D -m 644 rootfs/etc/modules-load.d/v200ai-cpufreq.conf \
  /etc/modules-load.d/v200ai-cpufreq.conf
modprobe v200ai_cpufreq
```

回退:

```sh
rm -f /etc/modules-load.d/v200ai-cpufreq.conf
modprobe -r v200ai_cpufreq
rm -f /lib/modules/$(uname -r)/extra/v200ai_cpufreq.ko
depmod -a
```

卸载后 CPU 停在当时频率,不会自动回升;温度传感器保持工作。重新加载会以当时的时钟作为新上限,
所以低温态重载得到更低上限,整机重新上电才回到 888 MHz。

### 7.2 brcmfmac(替换发行版模块)

`kernel/brcmfmac/` 是上游 `v6.1.190` 的源码,只加一个补丁
`0001-v200ai-sdio-teardown.patch`:默认跳过 `brcm_chip_set_passive()`
(`brcmfmac.skip_core_disable=0` 可恢复),并给 KSO 轮询补墙钟上限——CMD52 在 mmc 层没有
完成超时,死芯片上一条命令会卡约 54 s。

产物**替换** `/lib/modules/6.1.0-54-arm64/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko`:
装前备份原 ko,`depmod -a` 后重启验证;失败就在 USB NCM 管理通道上把原 ko 拷回。
vermagic 必须与板上一致(`6.1.0-54-arm64 SMP mod_unload modversions aarch64`),
构建后 `strip --strip-debug`。

### 7.3 蓝牙 hci_bcm 与 USB3 PHY / IOMMU

- `kernel/bluetooth/` 保留实际构建源码与配套 `btbcm` 修改,构建 UART 协议集合;
  切速后 50 ms 等待是行为的一部分,不要删。
- `kernel/usb3/` 提供 `phy_sun50i_usb3`(Debian 未编 `CONFIG_PHY_SUN50I_USB3`),
  顺序:PHY → `dwc3` → `xhci_plat_hcd`。
- `kernel/iommu/` 在 upstream 6.1.190 基础上加 `.owner=THIS_MODULE`,永久驻留、不引入不完整
  卸载,通过 softdep 早于 Cedrus/DRM。

## 8. 失败回滚

规则:所有 eMMC 修改按 AGENTS.md 逐次确认;写后 `sync` 并回读校验;重启/断电由人执行;
运行镜像含密钥、日志、网络与配对信息,不能作为可公开通用镜像;完整备份只在仓库外
`../h6-private/` 与忽略的 `images/`。

| 情况 | 处理 |
| --- | --- |
| p2 只写了一半(USB 掉线) | 直接重跑同一条 `flash-part.ps1`(从头覆盖写);若 LUN 已消失,重新放 `p2ums` 再上电 |
| 写错盘 | 立刻停止;`Get-Disk` 按容量/型号核对后,用该盘原有备份恢复;不要把 UMS 和其他 USB 盘同时插入 |
| 首启无串口输出 | 断电 → FEL → 重写 2.1 的三块(约 2 MiB)或重写 bootloader 区 |
| 引导载荷坏了(加载 Image/initrd/dtb 失败) | U-Boot 自动回 `ums 0 mmc 1`;主机把 `Image`/`initrd.img`/`v200ai.dtb`/`uboot.env` 重拷进 p1 |
| 系统能起但服务异常 | USB NCM `192.168.60.1` 或 `ttyGS0` 登录后 `journalctl -u <unit>`;不要用 `ip addr show`/`iw station dump` 排查 WiFi(rtnl 死锁风险),用 sysfs、dmesg、进程状态 |
| AP 掉线/失联 | `wifi-mode.sh ap` 重拉;`sdio-reset.sh` 只重绑 WiFi 主控,不等于整板冷启动 |
| 完全回滚到封版板 | 从 `../h6-private/` 的私有完整备份恢复(本地,不入库) |

FEL 通道永远可用:即使 MBR、bootloader、p1 全坏,`sunxi-fel` + 本文第 1、2 步就能重建。
