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
env = (root / 'dist/uboot.env').read_bytes()
assert len(env) == 65536 and struct.unpack('<I', env[:4])[0] == zlib.crc32(env[4:])
assert all(token not in env for token in (b'once.flag', b'umshold.flag', b'fatsize', b'fatwrite'))
assert b'ums 0 mmc 1' in env
assert b'initrd.img' in env and b'v200ai.dtb' in env
# Verify the final boot script's recovery branches without touching a device.
bootcmd = next(line.split('=', 1)[1] for line in (root / 'boot/uboot-env.txt').read_text().splitlines() if line.startswith('bootcmd='))
stub = '''
fatload() { echo LOAD:"$4"; filesize=1234; test "$4" != "$FAIL_FILE"; }
setenv() { export "$1=$2"; }
booti() { if test "$BOOT_FAIL" = 1; then return 1; fi; echo BOOT; exit 0; }
ums() { echo UMS; exit 0; }
'''
for fail, boot_fail, wanted in [
    ('none', '0', 'BOOT'),
    ('Image', '0', 'UMS'), ('initrd.img', '0', 'UMS'),
    ('v200ai.dtb', '0', 'UMS'), ('none', '1', 'UMS'),
]:
    result = subprocess.check_output(['bash', '-c', stub + '\n' + bootcmd], env=dict(PATH=os.environ['PATH'], FAIL_FILE=fail, BOOT_FAIL=boot_fail)).decode()
    assert result.splitlines()[-1] == wanted, result
    assert 'LATCH' not in result
uart = (root / 'kernel/bluetooth/hci_bcm.c').read_text()
assert 'msleep(50)' in uart and 'v200ai_speed' in uart
assert 'v200ai_speed=1500000' in (root / 'rootfs/etc/modprobe.d/v200ai-bt-baud.conf').read_text()
print('PASS: script syntax, links, DTS/NVRAM, environment CRC, four UMS boot branches without latch and fixed BT configuration')
