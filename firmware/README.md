# BCM4335 封版固件

保持以下校验值；二进制不在公开仓库中。NVRAM 文本是实际可用配置，不能替换成 S4 整份 NVRAM。

| 板上路径（/lib/firmware/brcm/） | 大小 | SHA256 |
| --- | --- | --- |
| `brcmfmac4335-sdio.bin` | 617552 B | `d9fb35420872b23846a355fc56f2d60b44557d10071e41963c264caaf81fdee2` |
| `brcmfmac4335-sdio.txt` | 以文件为准 | `d3a354690b7c5d7888b7db499b66885c9fa86884ebd678c9ebfe2adcb4155e05` |
| `BCM4335A0.hcd` | 67393 B | `3e14e7f3c02e19408c5783f845329309e23305ab5f33fb19abfd24a73a84cd8a` |

WiFi 来源：Samsung Galaxy S4 / jflte 厂商文件 `etc/wifi/bcmdhd_sta.bin`：
https://github.com/flo071/proprietary_vendor_samsung_jf-common/tree/cm-14.1/proprietary
构建日期 2015-03-05，版本 6.30.171.24.64。旧 2013 版不能作为本版本的共存基线。

蓝牙 HCD 来源参考 LibreELEC 的 brcmfmac_sdio-firmware 仓库：
https://github.com/LibreELEC/brcmfmac_sdio-firmware 。文件名相同也应核对 SHA256。
来源文件许可仍适用。当前已验证副本与整盘恢复镜像只保存在本地。

板名别名是三个符号链接：

```text
brcmfmac4335-sdio.custom,h6-v200ai.bin -> brcmfmac4335-sdio.bin
brcmfmac4335-sdio.custom,h6-v200ai.txt -> brcmfmac4335-sdio.txt
BCM4335A0.custom,h6-v200ai.hcd -> BCM4335A0.hcd
```

当前无匹配的独立 CLM blob。保留缺失提示，勿创建空文件或借用其他芯片的 CLM。
NVRAM 内的默认 MAC 字段不是实际 OTP MAC，不能据此认为芯片 MAC 已改变。
