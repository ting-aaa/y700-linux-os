#!/usr/bin/env bash
# Package the board's defaults separately from Debian's input method binaries.
set -euo pipefail
umask 022
repo=$(cd "$(dirname "$0")/.." && pwd)
source_dir=$repo/packaging/input-pinyin
out=$(realpath -m "${1:?output directory}")
mkdir -p -- "$out"
stage=$(mktemp -d)
archive=
cleanup() {
    rm -rf -- "$stage"
    if [[ -n $archive ]]; then rm -f -- "$archive"; fi
}
trap cleanup EXIT
install -Dm644 "$source_dir/control" "$stage/DEBIAN/control"
install -Dm644 "$source_dir/90_y700_input_pinyin.gschema.override" "$stage/usr/share/glib-2.0/schemas/90_y700_input_pinyin.gschema.override"
install -Dm644 "$source_dir/90-y700-language.conf" "$stage/usr/share/lightdm/lightdm-gtk-greeter.conf.d/90-y700-language.conf"
install -Dm755 "$source_dir/y700-display-language" "$stage/usr/libexec/y700-display-language"
install -Dm644 "$source_dir/y700-display-language.desktop" "$stage/usr/share/applications/y700-display-language.desktop"
install -Dm644 "$repo/LICENSE" "$stage/usr/share/doc/y700-input-pinyin/copyright"
export SOURCE_DATE_EPOCH=1795046400
chmod 755 "$stage"
find "$stage" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
version=$(sed -n 's/^Version: //p' "$source_dir/control")
name="y700-input-pinyin_${version}_all.deb"
archive=$(mktemp "$out/.$name.XXXXXXXX")
dpkg-deb --root-owner-group --uniform-compression -Zxz -z6 -b "$stage" "$archive"
chmod 644 "$archive"
mv -fT -- "$archive" "$out/$name"
archive=
sha256sum "$out/$name"
