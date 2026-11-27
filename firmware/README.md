# BCM4335 封版固件

这三个文件随仓库提供，目的是**只靠仓库就能做出完整可用的 rootfs**。安装时拷到
`/lib/firmware/brcm/`，并建立三个板名别名链接。

| 仓库内文件 | 大小 | SHA256 |
| --- | --- | --- |
| `brcmfmac4335-sdio.bin` | 617552 B | `d9fb35420872b23846a355fc56f2d60b44557d10071e41963c264caaf81fdee2` |
| `brcmfmac4335-sdio.txt` | 3297 B | `d3a354690b7c5d7888b7db499b66885c9fa86884ebd678c9ebfe2adcb4155e05` |
| `BCM4335A0.hcd` | 67393 B | `3e14e7f3c02e19408c5783f845329309e23305ab5f33fb19abfd24a73a84cd8a` |

```sh
install -m 0644 brcmfmac4335-sdio.bin brcmfmac4335-sdio.txt BCM4335A0.hcd /lib/firmware/brcm/
cd /lib/firmware/brcm
ln -sf brcmfmac4335-sdio.bin 'brcmfmac4335-sdio.custom,h6-v200ai.bin'
ln -sf brcmfmac4335-sdio.txt 'brcmfmac4335-sdio.custom,h6-v200ai.txt'
ln -sf BCM4335A0.hcd         'BCM4335A0.custom,h6-v200ai.hcd'
```

板名别名由 DTB 的 `compatible = "custom,h6-v200ai"` 决定，内核按它去找
`<chip>-sdio.custom,h6-v200ai.bin/.txt` 和 `BCM4335A0.custom,h6-v200ai.hcd`，
所以三个链接缺一不可。

## 来源

- WiFi 固件来自 Samsung Galaxy S4 / jflte 厂商文件 `etc/wifi/bcmdhd_sta.bin`：
  <https://github.com/flo071/proprietary_vendor_samsung_jf-common/tree/cm-14.1/proprietary>
  构建日期 2015-03-05，版本 6.30.171.24.64。旧的 2013 版不能作为本版本的共存基线。
- 蓝牙 HCD 参考 LibreELEC 的 `brcmfmac_sdio-firmware`：
  <https://github.com/LibreELEC/brcmfmac_sdio-firmware>。同名文件也要核对 SHA256。
- NVRAM 文本（`brcmfmac4335-sdio.txt`）是本板实际可用配置，不能替换成 S4 整份 NVRAM。

来源方的许可仍然适用：这两份二进制是厂商/上游固件，仓库只是为了可复现地重建本板
rootfs 而携带，不改变其授权。

## 注意

- 当前没有匹配的独立 CLM blob。保留缺失提示，不要创建空文件或借用其他芯片的 CLM。
- NVRAM 里的默认 MAC 字段不是实际 OTP MAC，不能据此认为芯片 MAC 已改变。
- 其余 `brcmfmac*.bin`、`cypress/*` 链接和 `regulatory.db` 由 Debian 包
  `firmware-brcm80211` 提供，不需要放进仓库。
