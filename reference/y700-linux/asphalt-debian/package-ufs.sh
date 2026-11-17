#!/usr/bin/env bash
# Repackage the verified direct boot payload for a dedicated internal linux partition.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
w=$(realpath -m "${1:?build directory}/ufs")
out="$here/images"
mkdir -p "$w/source" "$w/unpacked"
stage=$(mktemp -d "$w/stage.XXXXXXXX")
tool="$here/../tools/mkbootimg"
py=("${UV_BIN:-uv}" run --no-project --python "${UV_PYTHON:-3.12}" python)
(cd "$out" && sha256sum -c SHA256SUMS)
"${py[@]}" "$tool/unpack_bootimg.py" --boot_img "$out/asphalt-prc-boot.img" --out "$w/source" --format=mkbootimg -0 > "$w/args"
mapfile -d '' args < "$w/args"
(cd "$stage" && gzip -dc "$w/source/ramdisk" | cpio --quiet -id --no-absolute-filenames)
install -m755 "$here/init-ufs" "$stage/init"
(cd "$stage" && find . -print0 | LC_ALL=C sort -z | cpio --null --quiet -o -H newc --owner 0:0 | gzip -n -2) > "$w/source/ramdisk"
"${py[@]}" "$tool/mkbootimg.py" "${args[@]}" -o "$w/boot.img"
test "$(stat -c %s "$w/boot.img")" -le 100663296
"${py[@]}" "$tool/unpack_bootimg.py" --boot_img "$w/boot.img" --out "$w/unpacked" > "$w/header.txt"
for part in kernel dtb ramdisk; do cmp "$w/source/$part" "$w/unpacked/$part"; done
install -m644 "$w/boot.img" "$out/asphalt-prc-ufs-boot.img"
(cd "$out" && sha256sum asphalt-prc-ufs-boot.img asphalt-debian.ext4.zst > SHA256SUMS-ufs)
