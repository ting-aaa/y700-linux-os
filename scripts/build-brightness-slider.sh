#!/bin/bash
# Extend the qualified Chromium-enabled package used on the dev12.11 tablet.
set -euo pipefail
umask 022
[[ $# == 2 ]] || { echo "Usage: $0 GPU_PLATFORM_DEB OUTPUT_DIR" >&2; exit 2; }
base=$(realpath -e "$1")
out=$(realpath -m "$2")
repo=$(cd "$(dirname "$0")/.." && pwd)
printf '%s  %s\n' 2b6dd72510cc0a63744127cd68149ec28f4241a6acca587263ddcc8e3357e97e "$base" |
    sha256sum --strict --status -c -
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
root=$work/root
dpkg-deb -R "$base" "$root"
version=0.1.0~dev12.8+gpu1.1
sed -i "s/^Version: 0.1.0~dev12.8+gpu1$/Version: $version/" "$root/DEBIAN/control"
grep -Fxq "Version: $version" "$root/DEBIAN/control"
patch --batch --forward --fuzz=0 -d "$root" -p1 <"$repo/packaging/brightness-slider.patch"
export SOURCE_DATE_EPOCH=1795255400
find "$root" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
name="y700-platform_${version}_all.deb"
dpkg-deb --root-owner-group --uniform-compression -Zxz -z6 --build "$root" "$work/$name"
mkdir -p "$out"
if [[ -e "$out/$name" || -L "$out/$name" ]]; then cmp "$work/$name" "$out/$name"; else install -m644 "$work/$name" "$out/$name"; fi
sha256sum "$out/$name"
