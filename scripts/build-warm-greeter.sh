#!/usr/bin/env bash
# Build the optional seat0 greeter configuration package on a Linux host.
set -euo pipefail
umask 022
repo=$(cd "$(dirname "$0")/.." && pwd)
source=$repo/packaging/warm-greeter
out=$(realpath -m "${1:?output directory}")
mkdir -p -- "$out"
stage=$(mktemp -d)
archive=
cleanup() {
    rm -rf -- "$stage"
    if [[ -n $archive ]]; then rm -f -- "$archive"; fi
}
trap cleanup EXIT
install -Dm644 "$source/control" "$stage/DEBIAN/control"
install -Dm644 "$source/90-y700-warm-greeter.conf" "$stage/usr/share/lightdm/lightdm.conf.d/90-y700-warm-greeter.conf"
install -Dm644 "$source/90_y700_warm_greeter.gschema.override" "$stage/usr/share/glib-2.0/schemas/90_y700_warm_greeter.gschema.override"
install -Dm644 "$repo/LICENSE" "$stage/usr/share/doc/y700-warm-greeter/copyright"
# Pin the first package revision's build date for the archive lock.
export SOURCE_DATE_EPOCH=1795046400
chmod 755 "$stage"
find "$stage" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
version=$(sed -n 's/^Version: //p' "$source/control")
filename="y700-warm-greeter_${version}_all.deb"
archive=$(mktemp "$out/.$filename.XXXXXXXX")
dpkg-deb --root-owner-group --uniform-compression -Zxz -z6 -b "$stage" "$archive"
chmod 644 "$archive"
mv -f -- "$archive" "$out/$filename"
archive=
sha256sum "$out/$filename"
