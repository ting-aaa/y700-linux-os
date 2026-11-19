#!/bin/bash
# Build the optional Trixie ARM64 first-boot keyboard from Debian source archives.
set -euo pipefail
export LC_ALL=C
umask 022
if [[ $# != 2 ]]; then
    echo 'Usage: build-firstboot-touch.sh DEBIAN_SOURCE_ARCHIVES OUTPUT' >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
sources=$(realpath -e "$1")
out=$(realpath -m "$2")
(cd "$sources" && sha256sum --check <<'HASHES'
56d6166179dd3aec49bd63152d50d5fbb125c423588021df3a84d41a3b6ebef5  buffybox_3.5.1+dfsg-2.dsc
f23b5ffc98fedb0691adddf817bc97210b0361d1e2f8e72603a3d6fb7fed27b3  buffybox_3.5.1+dfsg.orig.tar.xz
39bb485f8dbe804cda2f88a4dd584401dd35c42d3956be22313e342dcb0b9547  buffybox_3.5.1+dfsg-2.debian.tar.xz
HASHES
)
cross=()
if [[ -n ${MESON_CROSS_FILE:-} ]]; then
    cross=(--cross-file "$(realpath -e "$MESON_CROSS_FILE")")
elif [[ $(dpkg --print-architecture) != arm64 || $(. /etc/os-release; echo "$VERSION_CODENAME") != trixie ]]; then
    echo 'Use Debian trixie ARM64, or supply a Meson cross file targeting that environment.' >&2
    exit 1
fi
jobs=${JOBS:-2}
[[ $jobs =~ ^[1-9][0-9]*$ ]]
mkdir -p "$out"
work=$(mktemp -d)
archive=
trap 'rm -rf -- "$work"; if [[ -n $archive ]]; then rm -f -- "$archive"; fi' EXIT
cd "$work"
dpkg-source --no-check -x "$sources/buffybox_3.5.1+dfsg-2.dsc" src
export SOURCE_DATE_EPOCH=$(dpkg-parsechangelog -l src/debian/changelog -S Timestamp)
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=$work=."
meson setup obj src "${cross[@]}" --prefix=/usr --wrap-mode=nodownload \
    -Dbuildtype=release -Dman=false -Dsystemd=false -Dlvgl_backends=framebuffer \
    -Db_lto=false -Dstrip=true
meson compile -C obj -j "$jobs" buffyboard
stage=$work/package
DESTDIR="$stage" meson install -C obj --no-rebuild --tags=buffyboard
bin=$stage/usr/libexec/y700-firstboot
mkdir -p "$bin"
mv "$stage/usr/bin/buffyboard" "$bin/"
# This private executable uses its compiled defaults. No system-wide keyboard service.
rm -f -- "$stage/etc/buffyboard.conf"
rmdir -- "$stage/usr/bin" "$stage/etc"
readelf -h "$bin/buffyboard" | grep -Eq 'Machine:[[:space:]]+AArch64'
needed=$(readelf -d "$bin/buffyboard" | sed -nE 's/.*\(NEEDED\).*\[([^]]+)\].*/\1/p' | sort)
[[ $needed == "$(printf '%s\n' libc.so.6 libinih.so.1 libinput.so.10 libudev.so.1)" ]]
install -m755 "$repo/src/firstboot/with-keyboard" "$bin/"
install -Dm644 "$repo/src/firstboot/50-touch-keyboard.conf" \
    "$stage/usr/lib/systemd/system/y700-firstboot.service.d/50-touch-keyboard.conf"
install -Dm644 src/debian/copyright "$stage/usr/share/doc/y700-firstboot-touch/copyright"
mkdir -p "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<'CONTROL'
Package: y700-firstboot-touch
Version: 3.5.1+dfsg-2~bpo13+1.y7001
Architecture: arm64
Maintainer: Y700 Linux OS contributors <maintainers@example.invalid>
Section: utils
Priority: optional
Depends: bash, libc6 (>= 2.38), libinih1 (>= 40), libinput10 (>= 0.15.0), libudev1
Description: Framebuffer keyboard for the Y700 first local password prompt
 Starts a private Buffyboard process during the existing tty1 enrollment service.
CONTROL
find "$stage" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
name=y700-firstboot-touch_3.5.1+dfsg-2~bpo13+1.y7001_arm64.deb
archive=$(mktemp "$out/.$name.XXXXXXXX")
dpkg-deb --root-owner-group --uniform-compression -Zxz -z6 -b "$stage" "$archive"
chmod 644 "$archive"
mv -f -- "$archive" "$out/$name"
sha256sum "$out/$name"
