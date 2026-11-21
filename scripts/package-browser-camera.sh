#!/bin/bash
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: package-browser-camera.sh PREVIOUS.deb UPDATED.deb OUTPUT.tar' >&2; exit 2; }
old=$(realpath -e "$1")
new=$(realpath -e "$2")
out=$(realpath -m "$3")
[[ ! -e $out && -d ${out%/*} ]]
echo "9de518b05da6d4fafc26a6a284dd30d484eb47801c947c814bcfa3fe772b3e52  $old" | sha256sum --strict -c -
echo "73cfdd2a0b1dad67f02aef3efbbb54b9129fb6a918bddc33b0574a08cd343cfc  $new" | sha256sum --strict -c -
work=$(mktemp -d "${out%/*}/.browser-camera-bundle.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
pkg=browser-camera-orientation-y7005
install -d -m755 "$work/$pkg"
install -m755 "$(dirname "$0")/update-browser-camera.sh" "$work/$pkg/update.sh"
for input in "$old" "$new"; do
    name=$(dpkg-deb -W --showformat='${Package}_${Version}_${Architecture}.deb' "$input")
    install -m644 "$input" "$work/$pkg/$name"
done
tar --sort=name --format=ustar --mtime=@1795219200 --owner=0 --group=0 --numeric-owner \
    -C "$work" -cf "$work/package.tar" "$pkg"
mv -T --no-clobber "$work/package.tar" "$out"
[[ ! -e $work/package.tar ]]
sha256sum "$out"
