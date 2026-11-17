#!/usr/bin/env bash
# Run as root in WSL on an offline image copy.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
w=$(realpath "${1:?EFI work directory}")
out="$here/images/uefi"
mkdir -p "$out" "$w/root-mount"
cd "$w"
test ! -e debian-efi.ext4
cp --sparse=always ../root.ext4 debian-efi.ext4
test "$(sha256sum debian-efi.ext4 | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$here/images/rootfs-unpacked.sha256")"
mount -o loop debian-efi.ext4 root-mount
trap 'umount root-mount' EXIT
grep -q '^asphalt-prc-debian13-xfce-7.3.4-v1$' root-mount/etc/y700/image-id
printf '\nPARTLABEL=linux-boot /boot vfat umask=0077 0 0\n' >> root-mount/etc/fstab
umount root-mount
trap - EXIT
e2fsck -fn debian-efi.ext4
zstd --no-asyncio -T3 -4 -f debian-efi.ext4 -o "$out/debian-root.ext4.zst"
sha256sum debian-efi.ext4 > root-hash
zstd --no-asyncio -dc "$out/debian-root.ext4.zst" | sha256sum | cut -d' ' -f1 | diff - <(cut -d' ' -f1 root-hash)
