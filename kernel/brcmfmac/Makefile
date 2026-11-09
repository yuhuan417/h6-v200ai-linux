# SPDX-License-Identifier: ISC
#
# V200-AI 外置 brcmfmac：与板载 6.1.0-54-arm64 匹配，只加 sdio.c 里的 KSO 墙钟上限。
# 其余按上游 v6.1.190 的 brcmfmac 对象列表，CONFIG_* 取自 Debian headers。

ccflags-y += -I $(src)

obj-m := brcmfmac.o

brcmfmac-objs := \
	cfg80211.o chip.o fwil.o fweh.o p2p.o proto.o common.o core.o \
	firmware.o feature.o btcoex.o vendor.o pno.o xtlv.o

brcmfmac-$(CONFIG_BRCMFMAC_PROTO_BCDC)	+= bcdc.o fwsignal.o
brcmfmac-$(CONFIG_BRCMFMAC_PROTO_MSGBUF) += commonring.o flowring.o msgbuf.o
brcmfmac-$(CONFIG_BRCMFMAC_SDIO)	+= sdio.o bcmsdh.o
brcmfmac-$(CONFIG_BRCMFMAC_USB)		+= usb.o
brcmfmac-$(CONFIG_BRCMFMAC_PCIE)	+= pcie.o
brcmfmac-$(CONFIG_BRCMDBG)		+= debug.o
brcmfmac-$(CONFIG_BRCM_TRACING)		+= tracepoint.o
brcmfmac-$(CONFIG_OF)			+= of.o
brcmfmac-$(CONFIG_DMI)			+= dmi.o
