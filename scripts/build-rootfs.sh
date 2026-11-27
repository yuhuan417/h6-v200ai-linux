#!/bin/bash
# Build a bootable V200-AI rootfs from Debian packages plus this repository.
#
#   scripts/build-rootfs.sh [-s SIZE_MIB] [-o OUT.img]
#
# Pipeline: mkfs.ext4 -> debootstrap bookworm arm64 -> apt-get install the
# package list in rootfs/packages.txt -> overlay rootfs/ -> install firmware/
# -> fstab + unit enabling -> resize2fs -M -> e2fsck.
#
# Needs root and qemu-aarch64 binfmt (or a native arm64 host).
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$REPO/dist/rootfs.img}
SIZE_MIB=${SIZE_MIB:-3072}
MNT=$REPO/build/rootfs-mnt
SUITE=bookworm
MIRROR=http://deb.debian.org/debian
SECURITY=http://security.debian.org/debian-security
# Fixed so repeated builds are byte-comparable; PARTUUID stays 8d68c129-0x
FS_UUID=5b1d7c1e-02b0-4d00-8f00-000000000002

while getopts "s:o:" opt; do
    case $opt in
        s) SIZE_MIB=$OPTARG ;;
        o) OUT=$OPTARG ;;
        *) echo "usage: $0 [-s size_mib] [-o out.img]" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
command -v debootstrap >/dev/null || { echo "debootstrap missing" >&2; exit 1; }
command -v qemu-aarch64-static >/dev/null || echo "warning: no qemu-aarch64-static, need native arm64 or binfmt" >&2

cleanup() {
    for d in dev/pts dev proc sys; do
        mountpoint -q "$MNT/$d" && umount "$MNT/$d"
    done
    mountpoint -q "$MNT" && umount "$MNT"
}
trap cleanup EXIT

echo "== image $OUT (${SIZE_MIB} MiB)"
mkdir -p "$(dirname "$OUT")" "$MNT"
rm -f "$OUT"
truncate -s "${SIZE_MIB}M" "$OUT"
mkfs.ext4 -q -F -L rootfs -U "$FS_UUID" "$OUT"
mount -o loop "$OUT" "$MNT"

mkdir -p "$MNT/proc" "$MNT/sys" "$MNT/dev" "$MNT/dev/pts"
for d in proc sys dev dev/pts; do
    mount --bind "/$d" "$MNT/$d"
done

echo "== debootstrap $SUITE/arm64"
debootstrap --arch=arm64 --variant=minbase \
    --components=main,contrib,non-free,non-free-firmware \
    "$SUITE" "$MNT" "$MIRROR"

printf '#!/bin/sh\nexit 101\n' > "$MNT/usr/sbin/policy-rc.d"
chmod 755 "$MNT/usr/sbin/policy-rc.d"

echo "deb $MIRROR $SUITE main contrib non-free non-free-firmware" > "$MNT/etc/apt/sources.list"
echo "deb $MIRROR $SUITE-updates main contrib non-free non-free-firmware" >> "$MNT/etc/apt/sources.list"
echo "deb $SECURITY $SUITE-security main contrib non-free non-free-firmware" >> "$MNT/etc/apt/sources.list"

echo "== packages from rootfs/packages.txt"
PKGS=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$REPO/rootfs/packages.txt" | grep -v '^$' | tr '\n' ' ')
chroot "$MNT" env DEBIAN_FRONTEND=noninteractive \
    apt-get -y -q update
# shellcheck disable=SC2086
chroot "$MNT" env DEBIAN_FRONTEND=noninteractive \
    apt-get -y -q --no-install-recommends install $PKGS

echo "== overlay rootfs/"
cp -a "$REPO/rootfs/." "$MNT/"
rm -rf "$MNT/rootfs"
chown -R 0:0 "$MNT/etc/modules-load.d" "$MNT/etc/modprobe.d" "$MNT/etc/systemd" \
    "$MNT/etc/hostapd" "$MNT/etc/dnsmasq.d" "$MNT/etc/network" \
    "$MNT/etc/wpa_supplicant" "$MNT/etc/default" "$MNT/usr/local/bin"
find "$MNT/usr/local/bin" -name '*.sh' -exec chmod 755 {} +
find "$MNT/etc/systemd" "$MNT/etc/modprobe.d" "$MNT/etc/modules-load.d" \
    "$MNT/etc/hostapd" "$MNT/etc/dnsmasq.d" "$MNT/etc/network" \
    "$MNT/etc/wpa_supplicant" -type f -exec chmod 644 {} +

echo "== firmware/ from repository"
install -d "$MNT/lib/firmware/brcm"
for f in brcmfmac4335-sdio.bin brcmfmac4335-sdio.txt BCM4335A0.hcd; do
    install -m 644 "$REPO/firmware/$f" "$MNT/lib/firmware/brcm/$f"
done
ln -sf brcmfmac4335-sdio.bin "$MNT/lib/firmware/brcm/brcmfmac4335-sdio.custom,h6-v200ai.bin"
ln -sf brcmfmac4335-sdio.txt "$MNT/lib/firmware/brcm/brcmfmac4335-sdio.custom,h6-v200ai.txt"
ln -sf BCM4335A0.hcd         "$MNT/lib/firmware/brcm/BCM4335A0.custom,h6-v200ai.hcd"

echo "== fstab, hostname, units"
cat > "$MNT/etc/fstab" <<'FSTAB'
# /etc/fstab — V200-AI (H6)，根分区在板载 eMMC 的 p2
PARTUUID=8d68c129-02  /                ext4  defaults,noatime,errors=remount-ro  0 1
PARTUUID=8d68c129-01  /boot/firmware   vfat  defaults,noatime                    0 2
FSTAB
echo v200ai > "$MNT/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tv200ai\n' > "$MNT/etc/hosts"

for unit in ssh.service systemd-networkd.service networking.service \
            bluetooth.service usbgadget.service v200ai-ap.service \
            v200ai-bt-late.service v200ai-growroot.service v200ai-latch.service \
            serial-getty@ttyGS0.service; do
    systemctl --root="$MNT" enable "$unit" >/dev/null
done
# v200ai-bt-tether is capability only: never enabled at boot.
rm -f "$MNT/etc/systemd/system/multi-user.target.wants/v200ai-bt-tether.service"
# hostapd/dnsmasq/wpa_supplicant ship enabled by their packages, but wifi-mode.sh
# starts them itself with the board configuration; leaving the package units
# enabled would race with it (and hostapd has no DAEMON_CONF).
for unit in hostapd.service dnsmasq.service wpa_supplicant.service; do
    systemctl --root="$MNT" disable "$unit" >/dev/null 2>&1 || true
    rm -f "$MNT/etc/systemd/system/multi-user.target.wants/$unit"
done

echo "== kernel ABI check"
if grep -qx 'linux-image-arm64' <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$REPO/rootfs/packages.txt"); then
    echo "rootfs/packages.txt must not carry the linux-image-arm64 meta" >&2
    exit 1
fi
MODS=$(ls "$MNT/lib/modules")
[ "$MODS" = "6.1.0-54-arm64" ] || { echo "unexpected kernel ABI: $MODS" >&2; exit 1; }

echo "== clean"
chroot "$MNT" env DEBIAN_FRONTEND=noninteractive apt-get -y -q clean
rm -rf "$MNT/var/lib/apt/lists"/* "$MNT/var/cache/apt/archives"/*.deb
rm -f "$MNT/usr/sbin/policy-rc.d"
: > "$MNT/etc/machine-id"
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$MNT/etc/localtime" 2>/dev/null || true

cleanup
trap - EXIT

echo "== shrink"
resize2fs -M "$OUT" >/dev/null
e2fsck -fn "$OUT" >/dev/null
SIZE=$(stat -c%s "$OUT")
echo "$(sha256sum "$OUT" | cut -d' ' -f1) $OUT"
echo "rootfs image: $SIZE bytes ($((SIZE / 1024 / 1024)) MiB), fs UUID $FS_UUID"
