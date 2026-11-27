#!/usr/bin/env python3
"""Build the 512-byte MBR: p1 128 MiB FAT32, p2 ext4 to the end of the eMMC.

Layout (512-byte sectors):

    p1  start 2048     262144 sectors (128 MiB)  type 0x0c, active
    p2  start 264192   rest of the disk          type 0x83

Disk signature stays 0x8d68c129 so the kernel command line keeps using
PARTUUID=8d68c129-02 for the root filesystem (8d68c129-01 is p1).
"""
import argparse
import hashlib
from pathlib import Path
import struct

root = Path(__file__).resolve().parents[1]
out = root / 'dist'

SECTOR = 512
DISK_SIGNATURE = 0x8d68c129
P1_START = 2048
P1_SECTORS = 262144                 # 128 MiB
P2_START = P1_START + P1_SECTORS    # 264192
DEFAULT_DISK_SECTORS = 14942208     # 7.13 GiB eMMC (14,942,208 x 512 bytes)


def entry(boot, ptype, start, count):
    return struct.pack('<B3sB3sII', boot, b'\0\0\0', ptype, b'\0\0\0', start, count)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--disk-sectors', type=int, default=DEFAULT_DISK_SECTORS)
    ap.add_argument('-o', '--output', default=str(root / 'dist' / 'mbr.bin'))
    args = ap.parse_args()

    if args.disk_sectors <= P2_START:
        raise SystemExit(f'disk too small for p1: {args.disk_sectors} sectors')
    p2_sectors = args.disk_sectors - P2_START

    mbr = bytearray(SECTOR)
    mbr[440:444] = struct.pack('<I', DISK_SIGNATURE)
    mbr[446:462] = entry(0x80, 0x0c, P1_START, P1_SECTORS)
    mbr[462:478] = entry(0x00, 0x83, P2_START, p2_sectors)
    mbr[510:512] = b'\x55\xaa'

    path = Path(args.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(mbr)
    print(hashlib.sha256(mbr).hexdigest(), path.relative_to(root) if path.is_relative_to(root) else path)
    print(f'p1: start {P1_START} sectors ({P1_START * SECTOR // 1048576} MiB), '
          f'{P1_SECTORS} sectors ({P1_SECTORS * SECTOR // 1048576} MiB), FAT32 0x0c, active')
    print(f'p2: start {P2_START} sectors ({P2_START * SECTOR // 1048576} MiB), '
          f'{p2_sectors} sectors ({p2_sectors * SECTOR // 1048576} MiB), ext4 0x83')
    print(f'disk signature 0x{DISK_SIGNATURE:08x} -> PARTUUID {DISK_SIGNATURE:08x}-01 / -02')


if __name__ == '__main__':
    main()
