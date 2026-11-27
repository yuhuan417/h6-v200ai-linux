#!/usr/bin/env python3
"""Check source syntax, local Markdown links, fixed baseline and build products."""
from pathlib import Path
import hashlib
import json
import os
import re
import struct
import subprocess
import zlib

root = Path(__file__).resolve().parents[1]
for p in (root / 'rootfs/usr/local/bin').glob('*.sh'):
    subprocess.run(['bash', '-n', str(p)], check=True)
subprocess.run(['bash', '-n', str(root / 'scripts/build-modules.sh')], check=True)
subprocess.run(['bash', '-n', str(root / 'scripts/build-rootfs.sh')], check=True)
subprocess.run(['sh', '-n', str(root / 'boot/init')], check=True)
for p in [*(root / 'scripts').glob('*.py')]:
    compile(p.read_text(), str(p), 'exec')
for p in [root / 'README.md', root / 'AGENTS.md', *(root / 'docs').glob('*.md'), root / 'firmware/README.md']:
    for link in re.findall(r'\]\(([^)]+)\)', p.read_text()):
        if '://' in link or link.startswith('#'):
            continue
        assert (p.parent / link.split('#')[0]).exists(), (p, link)
baseline = json.loads((root / 'board/baseline-sha256.json').read_text())
nvram = root / 'firmware/brcmfmac4335-sdio.txt'
assert hashlib.sha256(nvram.read_bytes()).hexdigest() == baseline['/lib/firmware/brcm/brcmfmac4335-sdio.txt']
subprocess.run(['python3', str(root / 'scripts/build-boot.py')], check=True)
dtb = root / 'dist/v200ai.dtb'
roundtrip = subprocess.check_output(['dtc', '-q', '-I', 'dtb', '-O', 'dts', str(dtb)]).decode()
assert roundtrip == (root / 'board/h6-v200ai.dts').read_text()
# Bootstrap rootfs package list: 205 packages, WiFi/BT and USB gadget included.
pkgs = [line.split('#')[0].strip()
        for line in (root / 'rootfs/packages.txt').read_text().splitlines()]
pkgs = [p for p in pkgs if p]
assert len(pkgs) == 204, len(pkgs)
for required in ('firmware-brcm80211', 'hostapd', 'dnsmasq', 'bluez',
                 'wpasupplicant', 'iw', 'rfkill', 'linux-image-6.1.0-54-arm64',
                 'systemd', 'udev', 'kmod', 'initramfs-tools', 'usbutils'):
    assert required in pkgs, required
assert 'linux-image-arm64' not in pkgs, 'kernel meta would pull the newest ABI'
# Partition table: exactly two partitions, p1 128 MiB FAT32, p2 ext4 to the end.
subprocess.run(['python3', str(root / 'scripts/build-mbr.py')], check=True)
mbr = (root / 'dist/mbr.bin').read_bytes()
assert len(mbr) == 512 and mbr[510:512] == b'\x55\xaa'
assert struct.unpack('<I', mbr[440:444])[0] == 0x8d68c129, 'disk signature must keep PARTUUID 8d68c129-0x'
parts = []
for i in range(4):
    e = mbr[446 + i * 16:462 + i * 16]
    ptype = e[4]
    start, count = struct.unpack('<II', e[8:16])
    if count:
        parts.append((ptype, e[0], start, count))
assert len(parts) == 2, parts
(p1_type, p1_boot, p1_start, p1_count), (p2_type, _, p2_start, p2_count) = parts
assert (p1_type, p1_boot, p1_start, p1_count) == (0x0c, 0x80, 2048, 262144), parts[0]
assert p2_type == 0x83 and p2_start == p1_start + p1_count, parts[1]
assert p2_start + p2_count == 14942208, 'p2 must reach the end of the eMMC'
assert b'root=PARTUUID=8d68c129-02' in (root / 'boot/uboot-env.txt').read_bytes()
# p1 metadata image: empty FAT32 head only, 1 KiB clusters, reproducible.
subprocess.run(['python3', str(root / 'scripts/build-p1-meta.py')], check=True)
p1meta = (root / 'dist/p1-meta.bin').read_bytes()
assert len(p1meta) == 1057792, len(p1meta)
assert p1meta[82:90] == b'FAT32   ', p1meta[82:90]
assert p1meta[510:512] == b'\x55\xaa'
assert struct.unpack('<H', p1meta[11:13])[0] == 512 and p1meta[13] == 2, 'expect 1 KiB clusters'
assert struct.unpack('<H', p1meta[14:16])[0] == 32, 'reserved sectors'
env = (root / 'dist/uboot.env').read_bytes()
assert len(env) == 65536 and struct.unpack('<I', env[:4])[0] == zlib.crc32(env[4:])
assert all(token not in env for token in (b'once.flag', b'umshold.flag', b'fatsize'))
# guard.bin is the one-shot boot latch: created by U-Boot, cleared by v200ai-latch.service.
assert b'guard.bin' in env and b'fatwrite' in env
assert b'ums 0 mmc 1' in env
assert b'initrd.img' in env and b'v200ai.dtb' in env
# Verify the final boot script's recovery branches without touching a device.
bootcmd = next(line.split('=', 1)[1] for line in (root / 'boot/uboot-env.txt').read_text().splitlines() if line.startswith('bootcmd='))
stub = '''
fatload() { echo LOAD:"$4"; filesize=1234;
    case "$4" in
      p2ums)     test "$P2UMS" = 1; return $?;;
      guard.bin) test "$GUARD" = 1; return $?;;
    esac
    test "$4" != "$FAIL_FILE"; }
fatwrite() { echo GUARD_CREATED; return 0; }
fatrm() { echo P2UMS_CLEARED; return 0; }
setenv() { export "$1=$2"; }
booti() { if test "$BOOT_FAIL" = 1; then return 1; fi; echo BOOT; return 0; }
ums() { echo "UMS:$3"; return 0; }   # ums 0 <devtype> <devnum>[:<part>]
'''
# p2ums is consumed by fatrm before ums, so a p2-only session can never persist.
# Every case asserts an ordered subsequence of the boot script's output.
for p2ums, guard, fail, boot_fail, wanted in [
    ('1', '1', 'none', '0', ['P2UMS_CLEARED', 'UMS:1:2', 'UMS:1']),
    ('1', '0', 'none', '0', ['P2UMS_CLEARED', 'UMS:1:2', 'GUARD_CREATED', 'BOOT']),
    ('0', '1', 'none', '0', ['UMS:1']),
    ('0', '0', 'none', '0', ['GUARD_CREATED', 'BOOT']),
    ('0', '0', 'Image', '0', ['GUARD_CREATED', 'UMS:1']),
    ('0', '0', 'initrd.img', '0', ['GUARD_CREATED', 'UMS:1']),
    ('0', '0', 'v200ai.dtb', '0', ['GUARD_CREATED', 'UMS:1']),
    ('0', '0', 'none', '1', ['GUARD_CREATED', 'UMS:1']),
]:
    result = subprocess.check_output(['bash', '-c', stub + '\n' + bootcmd],
        env=dict(PATH=os.environ['PATH'], P2UMS=p2ums, GUARD=guard,
                 FAIL_FILE=fail, BOOT_FAIL=boot_fail)).decode()
    lines = result.splitlines()
    seen = iter(lines)
    assert all(any(line == want for line in seen) for want in wanted), \
        (p2ums, guard, fail, boot_fail, wanted, lines)
    if 'BOOT' not in wanted:
        assert 'BOOT' not in lines, (p2ums, guard, fail, boot_fail, lines)
    if 'UMS:1:2' not in wanted:
        assert 'UMS:1:2' not in lines, (p2ums, guard, fail, boot_fail, lines)
    assert ('GUARD_CREATED' in lines) == ('GUARD_CREATED' in wanted), lines
    assert ('P2UMS_CLEARED' in lines) == ('P2UMS_CLEARED' in wanted), lines
uart = (root / 'kernel/bluetooth/hci_bcm.c').read_text()
assert 'msleep(50)' in uart and 'v200ai_speed' in uart
assert 'v200ai_speed=1500000' in (root / 'rootfs/etc/modprobe.d/v200ai-bt-baud.conf').read_text()
# CPU 温控默认能力：源码、加载顺序与内核选项三者必须同时成立。
assert 'obj-m := v200ai_cpufreq.o' in (root / 'kernel/cpufreq/Makefile').read_text()
cooling = (root / 'kernel/cpufreq/v200ai_cpufreq.c').read_text()
assert 'CPUFREQ_IS_COOLING_DEV' in cooling
assert 'of_machine_is_compatible("custom,h6-v200ai")' in cooling
assert 'cpufreq' in (root / 'scripts/build-modules.sh').read_text()
modules_load = [line.strip() for line in (root / 'rootfs/etc/modules-load.d/v200ai-cpufreq.conf').read_text().splitlines()
                if line.strip() and not line.lstrip().startswith('#')]
assert modules_load == ['sun8i_thermal', 'v200ai_cpufreq'], modules_load
kconfig = (root / 'kernel/config-6.1.0-54-arm64').read_text().splitlines()
for option in ('CONFIG_CPU_FREQ=y', 'CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y',
               'CONFIG_CPU_FREQ_THERMAL=y', 'CONFIG_THERMAL_OF=y',
               'CONFIG_SUN8I_THERMAL=m'):
    assert option in kconfig, option
# Type-A USB 网卡固定走 CDC-NCM，r8152 不参与。
usbnet_load = [line.strip() for line in (root / 'rootfs/etc/modules-load.d/v200ai-usbnet.conf').read_text().splitlines()
               if line.strip() and not line.lstrip().startswith('#')]
assert usbnet_load == ['usbnet', 'cdc_ether', 'cdc_ncm'], usbnet_load
print('PASS: script syntax, links, DTS/NVRAM, environment CRC, guard.bin latch, one-shot p2ums p2-only UMS, Image/initrd/DTB/booti UMS fallbacks, p1 FAT32 head, '
      'fixed BT configuration, CPU frequency/thermal and USB-NIC CDC-NCM wiring')
