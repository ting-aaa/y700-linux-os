#!/usr/bin/env bash
# Build the Xfce unlock keyboard defaults on a Linux host.
set -euo pipefail
umask 022
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
out=$(realpath -m -- "${1:?output directory}")
mkdir -p -- "$out"
stage=$(mktemp -d)
archive=
cleanup() {
    rm -rf -- "$stage"
    if [[ -n $archive ]]; then rm -f -- "$archive"; fi
}
trap cleanup EXIT
source=$repo/packaging/touch-lock
config=/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml
install -Dm644 "$source/control" "$stage/DEBIAN/control"
install -Dm644 "$source/xfce4-screensaver.xml" "$stage$config"
printf '%s\n' "$config" > "$stage/DEBIAN/conffiles"
install -Dm644 "$repo/LICENSE" "$stage/usr/share/doc/y700-touch-lock/copyright"
export SOURCE_DATE_EPOCH=1795132800
chmod 755 "$stage"
find "$stage" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
version=$(sed -n 's/^Version: //p' "$source/control")
filename="y700-touch-lock_${version}_all.deb"
archive=$(mktemp "$out/.$filename.XXXXXXXX")
dpkg-deb --root-owner-group --uniform-compression -Zxz -z6 -b "$stage" "$archive"
chmod 644 "$archive"
mv -f -- "$archive" "$out/$filename"
archive=
sha256sum "$out/$filename"
