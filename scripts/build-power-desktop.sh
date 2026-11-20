#!/bin/bash
set -euo pipefail
umask 022
repo=$(cd "$(dirname "$0")/.." && pwd)
src=$repo/packaging/power-desktop
out=$(realpath -m "${1:?output directory}")
mkdir -p "$out"
stage=$(mktemp -d)
archive=$(mktemp "$out/.y700-power-desktop.XXXXXXXX")
trap 'rm -rf -- "$stage"; rm -f -- "$archive"' EXIT
install -Dm644 "$src/control" "$stage/DEBIAN/control"
hook=/etc/X11/Xsession.d/62y700_battery_indicator
install -Dm644 "$src/${hook##*/}" "$stage$hook"
printf '%s\n' "$hook" >"$stage/DEBIAN/conffiles"
install -Dm644 "$src/xfce4-power-manager.xml" \
    "$stage/usr/share/y700/power-xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml"
install -Dm644 "$repo/LICENSE" "$stage/usr/share/doc/y700-power-desktop/copyright"
export SOURCE_DATE_EPOCH=1795132800
chmod 755 "$stage"
find "$stage" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
dpkg-deb --root-owner-group --uniform-compression -Zxz -z6 --build "$stage" "$archive"
version=$(dpkg-deb -f "$archive" Version)
dest=$out/y700-power-desktop_${version}_all.deb
chmod 644 "$archive"
mv -f -- "$archive" "$dest"
sha256sum "$dest"
