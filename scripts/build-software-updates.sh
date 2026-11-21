#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")/../packaging/software-updates" && pwd)
out=$(realpath -m "${1:-out/software-updates}")
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
root=$work/package
install -Dm644 "$here/control" "$root/DEBIAN/control"
install -Dm755 "$here/y700-software-updates" "$root/usr/bin/y700-software-updates"
install -Dm644 "$here/y700-software-updates.desktop" "$root/usr/share/applications/y700-software-updates.desktop"
install -Dm644 "$here/../../LICENSE" "$root/usr/share/doc/y700-software-updates/copyright"
version=$(sed -n 's/^Version: //p' "$here/control")
name=y700-software-updates_${version}_all.deb
export SOURCE_DATE_EPOCH=1795219200
dpkg-deb --root-owner-group --build "$root" "$work/$name"
mkdir -p "$out"
install -m644 "$work/$name" "$out/$name"
(cd "$out"; sha256sum "$name")
