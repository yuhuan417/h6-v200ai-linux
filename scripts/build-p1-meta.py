#!/usr/bin/env python3
"""Build the p1 metadata-only FAT32 image.

An empty FAT32 needs only its reserved sectors, both FAT copies and the root
directory cluster; every other cluster is marked free in the FAT, so the data
area never has to be written. For a 128 MiB p1 with 1 KiB clusters
(`mkfs.fat -F 32 -s 2`) that is 1,057,792 bytes instead of 128 MiB.

2 KiB clusters are not an option: 128 MiB then holds only 65,272 clusters,
below the FAT32 threshold of 65,525, and Linux would mount it as FAT16.

The output is `dist/p1-meta.bin`, written with `fel_emmc.py flash` at LBA 2048;
the boot files are copied afterwards through UMS.
"""
import hashlib
from pathlib import Path
import struct
import subprocess

root = Path(__file__).resolve().parents[1]
build = root / 'build'
out = root / 'dist'

SIZE_MIB = 128
CLUSTER_SECTORS = 2          # 1 KiB clusters, keeps the cluster count above 65525
LABEL = 'BOOT'
VOLUME_ID = '8d68c129'       # fixed so the output is reproducible
SECTOR = 512


def fat_layout(image: Path):
    d = image.read_bytes()[:SECTOR]
    bps = struct.unpack('<H', d[11:13])[0]
    spc = d[13]
    reserved = struct.unpack('<H', d[14:16])[0]
    nfat = d[16]
    fatsz = struct.unpack('<I', d[36:40])[0]
    data_start = (reserved + nfat * fatsz) * bps
    clusters = (SIZE_MIB * 1024 * 1024 - data_start) // (spc * bps)
    return {
        'bps': bps, 'spc': spc, 'reserved': reserved, 'nfat': nfat,
        'fatsz': fatsz, 'data_start': data_start,
        'meta': data_start + spc * bps, 'clusters': clusters,
    }


def main():
    build.mkdir(exist_ok=True)
    out.mkdir(exist_ok=True)
    image = build / 'p1-empty.img'

    with open(image, 'wb') as f:
        f.truncate(SIZE_MIB * 1024 * 1024)
    subprocess.run(['mkfs.fat', '-F', '32', '-s', str(CLUSTER_SECTORS),
                    '-n', LABEL, '-i', VOLUME_ID, str(image)], check=True,
                   stdout=subprocess.DEVNULL)
    layout = fat_layout(image)
    if layout['clusters'] < 65525:
        raise SystemExit(f"only {layout['clusters']} clusters: Linux would treat this as FAT16")

    meta = out / 'p1-meta.bin'
    meta.write_bytes(image.read_bytes()[:layout['meta']])

    subprocess.run(['fsck.fat', '-n', str(image)], check=True,
                   stdout=subprocess.DEVNULL)
    print(hashlib.sha256(meta.read_bytes()).hexdigest(), meta.relative_to(root))
    print(f"p1 {SIZE_MIB} MiB: cluster {layout['spc'] * layout['bps']} B, "
          f"{layout['clusters']} clusters, label {LABEL}")
    print(f"meta {layout['meta']} B = {layout['reserved']} reserved sectors + "
          f"{layout['nfat']}x{layout['fatsz']} FAT sectors + 1 cluster")


if __name__ == '__main__':
    main()
