#!/bin/bash
# Run in Debian trixie/arm64 with the original source package's Build-Depends
# (profiles nocheck,nodoc,noinsttest). Only the tray panel is replaced.
set -euo pipefail
if (( $# != 3 )); then
    echo "Usage: $0 SOURCE_ARCHIVE_DIR ibus_1.5.32-2_arm64.deb OUTPUT_DIR" >&2
    exit 2
fi
test "$(dpkg --print-architecture)" = arm64
here=$(cd -- "$(dirname -- "$0")"/.. && pwd -P)
src=$(realpath -e "$1")
stock=$(realpath -e "$2")
out=$(realpath -e "$3")
test -d "$out"
dsc=ibus_1.5.32-2.dsc
printf '%s  %s\n' \
    a032bd54034203242cb3ad1037d450948a262ffd1f6d6b438ddec5bf9e02db1c "$src/$dsc" \
    b24f41ae38b236b254c09f1a8f53c2354b69b0789e89cea888d0494b09d15d67 "$src/ibus_1.5.32.orig.tar.gz" \
    37c4ea6b6014481df774d98b2ecca5172f66207edafbd555c317ba22f55577da "$src/ibus_1.5.32-2.debian.tar.xz" \
    5c0ce52da04c5f74baba3d7d4491e6e5eb9b674a81dadcf0fd9b58b254664ab6 "$stock" | sha256sum --strict -c -
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1795190400
export DEB_BUILD_PROFILES='nocheck nodoc noinsttest'
export DEB_HOST_ARCH_OS
DEB_HOST_ARCH_OS=$(dpkg-architecture -qDEB_HOST_ARCH_OS)
test "$DEB_HOST_ARCH_OS" = linux
export DEB_BUILD_MAINT_OPTIONS=hardening=+all
export DEB_CFLAGS_MAINT_APPEND="-Wall -pedantic -ffile-prefix-map=$work/src=. -fdebug-prefix-map=$work/src=."
dpkg-source -x --no-check "$src/$dsc" "$work/src"
cd "$work/src"
patch --batch --forward --fuzz=0 -p1 <"$here/packaging/ibus-tray/status-icon-single-menu.patch"
# Use Debian's paths and feature switches and regenerate the Vala/C with the
# packaged toolchain, just as debian/rules override_dh_auto_build does.
debian/rules override_dh_auto_configure
make -C ui/gtk3 maintainer-clean-generic
jobs=${JOBS:-4}
make -j"$jobs" -C src libibus-1.0.la
make -j"$jobs" -C client/wayland libibuswaylandim.la
make -j"$jobs" -C ui/gtk3 ibus-ui-gtk3
dpkg-deb -R "$stock" "$work/pkg"
frontend=usr/libexec/ibus-ui-gtk3
needed() { readelf -d "$1" | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p' | sort; }
needed "$work/pkg/$frontend" > "$work/stock.sonames"
needed ui/gtk3/.libs/ibus-ui-gtk3 > "$work/new.sonames"
diff -u "$work/stock.sonames" "$work/new.sonames"
strip --strip-unneeded -o "$work/pkg/$frontend" ui/gtk3/.libs/ibus-ui-gtk3
version=1.5.32-2+0y7001
sed -i "s/^Version: 1[.]5[.]32-2$/Version: $version/" "$work/pkg/DEBIAN/control"
cd "$work/pkg"
hash=$(md5sum "$frontend" | cut -d' ' -f1)
test "$(grep -Fc "  $frontend" DEBIAN/md5sums)" = 1
sed -i "\%  $frontend\$%s/^[0-9a-f]\{32\}/$hash/" DEBIAN/md5sums
md5sum --quiet -c DEBIAN/md5sums
archive=ibus_${version}_arm64.deb
dpkg-deb --root-owner-group -Zxz -z9 --build "$work/pkg" "$work/$archive"
test "$(dpkg-deb -f "$work/$archive" Version)" = "$version"
if [[ -e $out/$archive ]]; then
    cmp "$work/$archive" "$out/$archive"
else
    install -m644 "$work/$archive" "$out/$archive"
fi
sha256sum "$out/$archive" "$frontend"
