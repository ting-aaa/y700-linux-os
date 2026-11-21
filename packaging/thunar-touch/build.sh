#!/bin/bash
# Run in native Debian trixie arm64 or a matching build chroot.
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1749000000
[[ $# == 4 ]] || { echo 'Usage: build.sh STOCK.deb UPSTREAM.tar.bz2 DEBIAN.tar.xz OUTPUT_DIR' >&2; exit 2; }
[[ $(dpkg --print-architecture) == arm64 ]]
here=$(cd "$(dirname "$0")" && pwd)
stock=$(realpath "$1")
upstream=$(realpath "$2")
debian=$(realpath "$3")
mkdir -p "$4"
output=$(realpath "$4")
verify() { printf '%s  %s\n' "$1" "$2" | sha256sum -c -; }
verify f390240509b742d58c35a50bad12d31e9168e557ddb6dcf708e26724c4a33ea7 "$stock"
verify 71376f6d7ba4998943c412f374db16ec9b709610acd4d27ecb1eef3aca82af05 "$upstream"
verify dbca892cd73420dd2446c3194af52181053978fa053ef4fcd63e80457164cd63 "$debian"
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
tar -C "$work" -xf "$upstream"
cd "$work/thunar-4.20.2"
tar -xf "$debian"
while IFS= read -r patchname; do
    case "$patchname" in ''|'#'*) continue ;; esac
    patch --batch --fuzz=0 -p1 <"debian/patches/$patchname"
done <debian/patches/series
patch --batch --fuzz=0 -p1 <"$here/direct-touch.patch"
export DEB_BUILD_MAINT_OPTIONS=hardening=+all
export DEB_LDFLAGS_MAINT_APPEND='-Wl,-O1 -Wl,-z,defs'
export CFLAGS="$(dpkg-buildflags --get CFLAGS) -ffile-prefix-map=$PWD=."
export CPPFLAGS="$(dpkg-buildflags --get CPPFLAGS)"
export LDFLAGS="$(dpkg-buildflags --get LDFLAGS)"
./configure --prefix=/usr --sysconfdir=/etc --libdir=/usr/lib/aarch64-linux-gnu \
    --libexecdir=/usr/lib/aarch64-linux-gnu --disable-introspection --disable-gtk-doc \
    --disable-tpa-plugin --disable-apr-plugin --disable-sbr-plugin --disable-uca-plugin
make -j"${JOBS:-4}" -C thunarx
make -j"${JOBS:-4}" -C thunar
pkg="$work/package"
dpkg-deb -R "$stock" "$pkg"
old_bytes=$(stat -c %s "$pkg/usr/bin/thunar")
install -m755 thunar/.libs/thunar "$pkg/usr/bin/thunar"
strip --strip-unneeded "$pkg/usr/bin/thunar"
sed -i '/^Version:/s/$/+y7001/' "$pkg/DEBIAN/control"
new_bytes=$(stat -c %s "$pkg/usr/bin/thunar")
installed_kib=$(dpkg-deb -f "$stock" Installed-Size)
installed_kib=$((installed_kib + (new_bytes+1023)/1024 - (old_bytes+1023)/1024))
sed -i "s/^Installed-Size: .*/Installed-Size: $installed_kib/" "$pkg/DEBIAN/control"
digest=$(md5sum "$pkg/usr/bin/thunar" | cut -d' ' -f1)
sed -i "s/^[0-9a-f]\{32\}  usr\/bin\/thunar$/$digest  usr\/bin\/thunar/" "$pkg/DEBIAN/md5sums"
(cd "$pkg" && md5sum --quiet -c DEBIAN/md5sums)
dpkg-deb --build --root-owner-group "$pkg" "$output/thunar_4.20.2-1+deb13u1+y7001_arm64.deb"
sha256sum "$output/thunar_4.20.2-1+deb13u1+y7001_arm64.deb"
