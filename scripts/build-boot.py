#!/usr/bin/env python3
"""Build host-side DTB and a CRC-checked U-Boot FAT environment only."""
from pathlib import Path
import hashlib
import struct
import subprocess
import zlib

root = Path(__file__).resolve().parents[1]
out = root / 'dist'
out.mkdir(exist_ok=True)
subprocess.run(['dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', str(out / 'v200ai.dtb'), str(root / 'board/h6-v200ai.dts')], check=True)
lines = [line for line in (root / 'boot/uboot-env.txt').read_text().splitlines() if line and not line.startswith('#')]
assert all('=' in line for line in lines)
assert len({line.split('=', 1)[0] for line in lines}) == len(lines)
data = b'\0'.join(line.encode() for line in lines) + b'\0\0'
assert len(data) <= 65532
data += b'\xff' * (65532 - len(data))
(out / 'uboot.env').write_bytes(struct.pack('<I', zlib.crc32(data)) + data)
for name in ('v200ai.dtb', 'uboot.env'):
    p = out / name
    print(hashlib.sha256(p.read_bytes()).hexdigest(), p.relative_to(root))
