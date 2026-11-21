#!/bin/bash
# Optional upgrade of the sealed dev12.8 platform package used in dev12.11.
set -euo pipefail
umask 022
[[ $# == 2 ]] || { echo "Usage: $0 DEV12.8_PLATFORM_DEB OUTPUT_DIR" >&2; exit 2; }
base=$(realpath -e "$1")
printf '%s  %s\n' 95b8e4419a40080e98b78dbfe63839476c20479714ffb7257cfb7bbafc927583 "$base" |
    sha256sum --strict --status -c -
out=$(realpath -m "$2"); mkdir -p "$out"
here=$(cd "$(dirname "$0")/../packaging/chromium-graphics" && pwd -P)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
dpkg-deb -R "$base" "$work/root"
root=$work/root
version=0.1.0~dev12.8+gpu1
grep -Fxq 'Version: 0.1.0~dev12.8' "$root/DEBIAN/control"
sed -i "s/^Version: .*/Version: $version/" "$root/DEBIAN/control"
install -m644 "$here/99-y700-software-rendering" "$root/etc/chromium.d/"
install -m644 "$here/org.y700.chromium.gschema.xml" "$root/usr/share/glib-2.0/schemas/"
install -m644 "$here/y700-chromium-graphics.desktop" "$root/usr/share/applications/"
install -m755 "$here/y700-chromium-graphics" "$root/usr/libexec/"
glib-compile-schemas --strict --dry-run "$root/usr/share/glib-2.0/schemas"
export SOURCE_DATE_EPOCH=1795252753
find "$root" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
deb="y700-platform_${version}_all.deb"
dpkg-deb --root-owner-group --uniform-compression -Zxz -z6 --build "$root" "$work/$deb"
if [[ -e $out/$deb || -L $out/$deb ]]; then cmp "$work/$deb" "$out/$deb"; else install -m644 "$work/$deb" "$out/$deb"; fi
sha256sum "$out/$deb"
