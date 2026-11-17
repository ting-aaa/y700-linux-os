#!/bin/bash
# Generates a filesystem inside a regular file. Does not write any block device.
set -Eeuo pipefail
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${Y700_BUILD_ROOT:-/home/builder/y700-linux-build}
ROOTFS="$WORK/debian-rootfs"
IMAGE="$WORK/y700-debian13-arm64-rootfs.ext4"
OUTPUT="$PROJECT/images"
[[ $EUID == 0 ]] || { echo 'Run in WSL as root.' >&2; exit 1; }
bash "$PROJECT/scripts/verify-rootfs-integration.sh" "$PROJECT" "$ROOTFS"
for virtual_fs in proc sys dev run; do
  if mountpoint -q "$ROOTFS/$virtual_fs"; then
    echo "Refusing to image rootfs with active $virtual_fs mount." >&2; exit 1
  fi
done
test ! -e "$IMAGE" || { echo "Refusing to overwrite $IMAGE" >&2; exit 1; }
mkdir -p "$OUTPUT"
test ! -e "$OUTPUT/rootfs.ext4.zst" || { echo 'Compressed output already exists.' >&2; exit 1; }
truncate -s 12G "$IMAGE"
mkfs.ext4 -F -b 4096 -m 0 -U 61ab7000-2026-4a24-9000-16b51200fc00 \
  -L Y700LINUX -d "$ROOTFS" "$IMAGE" 2>&1 | tee "$PROJECT/logs/rootfs-mkfs.log"
e2fsck -fn "$IMAGE" 2>&1 | tee "$PROJECT/logs/rootfs-fsck.log"
tune2fs -l "$IMAGE" > "$PROJECT/rootfs/filesystem.txt"
sha256sum "$IMAGE" > "$PROJECT/rootfs/uncompressed-image.sha256"
zstd -T4 -6 --check "$IMAGE" -o "$OUTPUT/rootfs.ext4.zst"
zstd -t "$OUTPUT/rootfs.ext4.zst" 2>&1 | tee "$PROJECT/logs/rootfs-zstd-check.log"
sha256sum "$OUTPUT/rootfs.ext4.zst" > "$PROJECT/rootfs/compressed-image.sha256"
echo 'Rootfs image created and checked; this does not validate Y700 boot or hardware.'
