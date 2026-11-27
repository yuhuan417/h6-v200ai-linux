# FEL → DRAM eMMC 工具

在只有 FEL、没有可启动 U-Boot、也没有串口的情况下,读写这块板子 eMMC 的工具。

## 为什么不在 SPL 里做

SPL 只有 32 KiB SRAM,`sunxi_mmc` 加上写路径之后直接溢出;而且 SPL 里
`get_timer()` 不可靠,传输出错时会死循环。所以分工是:

```
FEL 主机                    板子
--------                    ----
sunxi-fel spl  ──►  SPL stub:初始化 DRAM + 导出 MMC 函数表 → 返回 FEL
sunxi-fel write ──►  DRAM:payload(读/写/切分区/降频都在这里)
sunxi-fel exe/… ──►  SPL stub 调用 payload,payload 用函数表回调 U-Boot 的
                     sunxi_mmc 驱动,完成后返回,stub 再返回 FEL
```

payload 运行在 DRAM,不受 SPL 大小限制,读和写可以放在同一份代码里。

## 组成

| 文件 | 作用 |
| --- | --- |
| `payload.c` / `link.ld` / `Makefile` | DRAM payload,链接在 `0x42000000`,`payload` 入口在 `0x42000010` |
| `fel_emmc.py` | 主机驱动:`info / read / write / flash / dump` |
| `spl/*.bin` | 由 U-Boot 树构建的 SPL stub(不提交,见下) |

SPL 侧的代码在仓库补丁 `uboot/patches/0002-v200ai-fel-payload.patch`,
对应 Kconfig 选项 `CONFIG_V200AI_FEL_PAYLOAD`(默认 `n`,只用于调试/刷写,
生产 bootloader 必须保持关闭)。

## 构建

payload(主机上交叉编译即可):

```sh
make -C tools/fel-emmc
```

SPL stub(需要 U-Boot 源码树,见 [docs/build.md](../../docs/build.md)):

```sh
git -C /path/to/u-boot checkout 03e45557e1f38a39a0c80fe30483130ff376cf92
git -C /path/to/u-boot apply /path/to/h6-v200ai-linux/uboot/patches/*.patch
cp /path/to/h6-v200ai-linux/uboot/configs/v200ai_defconfig /path/to/u-boot/configs/
make -C /path/to/u-boot v200ai_defconfig
/path/to/u-boot/scripts/config -e SPL_BOARD_INIT -e MMC_WRITE -e SPL_MMC_WRITE \
	-e V200AI_FEL_PAYLOAD -d SPL_SERIAL
make -C /path/to/u-boot olddefconfig
make -C /path/to/u-boot CROSS_COMPILE=aarch64-linux-gnu- spl/sunxi-spl.bin
cp /path/to/u-boot/spl/sunxi-spl.bin tools/fel-emmc/spl/
```

要点:

- 必须同时开 `MMC_WRITE`/`SPL_MMC_WRITE`(payload 的写路径要用
  `blk_dwrite`,且 `struct mmc` 的 `write_bl_len` 受该选项保护);
- 必须关掉 `SPL_SERIAL`,否则 32 KiB SRAM 放不下(实测带 payload 桥接的
  SPL 本体 27,928 B,开串口会溢出);
- 生产构建不要选 `V200AI_FEL_PAYLOAD`,默认配置不受影响。

## 用法

板子先进 FEL(`sunxi-fel ver` 应返回 `soc=00001728(H6)`)。

```sh
# 初始化 mmc,报告容量
./tools/fel-emmc/fel_emmc.py info

# 读 8 KiB–1 MiB 的 bootloader 区
./tools/fel-emmc/fel_emmc.py read 16 2032 bootarea.bin

# 写一段(自动按 512 块/次切分)
./tools/fel-emmc/fel_emmc.py write 16 uboot.bin

# 写整份镜像并从 LBA 0 开始,写完回读校验
./tools/fel-emmc/fel_emmc.py flash images/firmware.img --lba 0 --verify

# 读 boot0 / boot1 的第一个块(part: 0 用户区,1 boot0,2 boot1)
./tools/fel-emmc/fel_emmc.py read 0 16 boot0-head.bin --part 1

# 十六进制查看
./tools/fel-emmc/fel_emmc.py dump 0 1
```

## 参数协议

payload 参数块在 `0x400FE000`(`<14I`):

```
magic('PPR0') op sect cnt dst clock result err got lba t0 t1 dev part
```

- `op`:0 只初始化、1 单次读、2 单次写、3 分块读、4 分块写;
- 单次请求上限 512 块(主机侧自动切分);分块读写内部按 16 块一次搬运,
  因为单次传输更大时 `sunxi_mmc` 的 FIFO 通路会卡住;
- `part` 走 `mmc_switch_part`,可读 eMMC 的 boot0/boot1;
- `info` 输出的 `blocks` 来自 `mmc->capacity / read_bl_len`,本板为
  `14942208`(7,650,410,496 字节)。

## 注意

- 这是**写盘工具**:`write`/`flash` 直接改 eMMC 内容,目标 LBA 由命令行
  给出,没有二次确认。按 AGENTS.md 的规则,写之前要有人类明确确认,
  并在写后用 `read` 或 `--verify` 回读比对。
- payload 运行在 SPL 环境(MMU/缓存关闭、无 libc),只用函数表里导出的
  U-Boot 函数,不要在里面调用其它符号。
- FEL 状态下 DRAM 不可访问,必须先跑一次 stub 初始化 DRAM;
  `fel_emmc.py` 会自动做这一步,并清掉残留的 `PAYL` 魔数。
