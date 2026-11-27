#!/bin/sh
# Grow the root filesystem to fill p2 on first boot.
#
# Two cases, both handled:
#   * partition smaller than the disk  -> growpart then resize2fs
#   * partition already at the disk end -> resize2fs only
#
# The second case is the normal one now: scripts/build-mbr.py already makes p2
# span to the last sector, while the flashed ext4 image is compact (only used
# data), so the filesystem has to be grown into its partition on first boot.
#
# Failure is not fatal and is retried on the next boot, because the flag is
# only written after a successful resize.
set -u
DEV=/dev/mmcblk1
PART=2
FLAG=/var/lib/v200ai-growroot.done
log() { echo "v200ai-growroot: $*"; }

[ -e "$FLAG" ] && exit 0

if [ ! -b "${DEV}p${PART}" ]; then
    log "${DEV}p${PART} not present, skip"
    exit 0
fi

disk=$(blockdev --getsz "$DEV" 2>/dev/null) || disk=0
start=$(cat "/sys/class/block/${DEV##*/}p${PART}/start" 2>/dev/null) || start=0
size=$(cat "/sys/class/block/${DEV##*/}p${PART}/size" 2>/dev/null) || size=0
end=$((start + size))

if [ "$disk" -le 0 ]; then
    log "cannot read disk size, will retry next boot"
    exit 0
fi

if [ "$end" -lt "$disk" ]; then
    if ! command -v growpart >/dev/null 2>&1; then
        log "growpart not installed, will retry next boot"
        exit 0
    fi
    log "growing p${PART}: end=$end -> disk=$disk sectors"
    if ! growpart "$DEV" "$PART"; then
        log "growpart failed, will retry next boot"
        exit 0
    fi
    # growpart updates the kernel via BLKPG; fall back to partx/partprobe if needed.
    partx -u "$DEV" 2>/dev/null || partprobe "$DEV" 2>/dev/null || true
else
    log "p${PART} already fills the disk (end=$end disk=$disk), resize filesystem only"
fi

if ! resize2fs "${DEV}p${PART}"; then
    log "resize2fs failed, will retry next boot"
    exit 0
fi

touch "$FLAG"
log "done: p${PART} now $(cat "/sys/class/block/${DEV##*/}p${PART}/size") sectors"
