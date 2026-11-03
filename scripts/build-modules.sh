#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
: "${KERNEL_HEADERS:?Set KERNEL_HEADERS to the matching Debian 6.1.0-54-arm64 headers}"
cross=${CROSS_COMPILE:-aarch64-linux-gnu-}
for part in bluetooth iommu usb3; do
    dest="$repo/build/modules/$part"
    mkdir -p "$dest" "$repo/dist/modules/$part"
    cp "$repo/kernel/$part/"* "$dest/"
    make -C "$KERNEL_HEADERS" M="$dest" ARCH=arm64 CROSS_COMPILE="$cross" \
        CC="${cross}gcc" LD="${cross}ld" modules -j"${JOBS:-4}"
    for module in "$dest/"*.ko; do
        "${cross}strip" --strip-debug "$module"
        cp "$module" "$repo/dist/modules/$part/"
        modinfo -F vermagic "$module"
        sha256sum "$module"
    done
done
