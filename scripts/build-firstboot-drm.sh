#!/bin/bash
# Build private unl0kr with the DRM backend and the Y700 first-password PAM UI.
set -euo pipefail
export LC_ALL=C
umask 022
if [[ $# != 2 ]]; then
    echo 'Usage: build-firstboot-drm.sh DEBIAN_SOURCE_ARCHIVES OUTPUT' >&2
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
    echo 'Use a Trixie ARM64 build root, or supply MESON_CROSS_FILE.' >&2
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
patch --directory=src --strip=1 --fuzz=0 < "$repo/src/firstboot-drm/kms-output.patch"
export SOURCE_DATE_EPOCH=$(dpkg-parsechangelog -l src/debian/changelog -S Timestamp)
cp -a "$repo/src/firstboot-drm" helper
options=(--wrap-mode=nodownload --prefix=/usr -Dbuildtype=release -Db_lto=false)
meson setup obj src "${cross[@]}" "${options[@]}" -Dman=false -Dsystemd=false -Dlvgl_backends=drm
meson compile -C obj -j "$jobs" unl0kr
meson setup helper-obj helper "${cross[@]}" "${options[@]}"
meson compile -C helper-obj -j "$jobs" enroll
stage=$work/package
bin=$stage/usr/libexec/y700-firstboot-drm
install -Dm755 obj/unl0kr/unl0kr "$bin/unl0kr"
install -m755 helper-obj/enroll helper/firstboot helper/select-output "$bin/"
# Debian's target strip handles AArch64 on both native and cross builds.
strip_tool=${STRIP:-aarch64-linux-gnu-strip}
"$strip_tool" "$bin/unl0kr" "$bin/enroll"
for exe in unl0kr enroll; do
    readelf -h "$bin/$exe" | grep -Eq 'Machine:[[:space:]]+AArch64'
done
readelf -d "$bin/unl0kr" | grep -Fq '[libdrm.so.2]'
readelf -d "$bin/enroll" | grep -Fq '[libpam.so.0]'
install -Dm644 helper/60-drm-keyboard.conf \
    "$stage/usr/lib/systemd/system/y700-firstboot.service.d/60-drm-keyboard.conf"
install -Dm644 helper/unl0kr.conf "$stage/usr/share/y700-firstboot-drm/unl0kr.conf"
install -Dm644 src/debian/copyright "$stage/usr/share/doc/y700-firstboot-drm/copyright"
mkdir "$stage/DEBIAN"
cat >"$stage/DEBIAN/control" <<'CONTROL'
Package: y700-firstboot-drm
Version: 0.1.0~dev1
Architecture: arm64
Maintainer: Y700 Linux OS contributors <maintainers@example.invalid>
Section: utils
Priority: optional
Depends: y700-firstboot-touch, bash, util-linux, libc6 (>= 2.38), libinih1, libinput10, libudev1, libxkbcommon0, libdrm2, libpam0g
Description: Touch password enrollment for the Y700 DRM display
 Uses the local passwd PAM stack and a DRM keyboard on framebuffer-disabled
 boots. The existing framebuffer keyboard supports the normal boot mode.
CONTROL
find "$stage" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
name=y700-firstboot-drm_0.1.0~dev1_arm64.deb
archive=$(mktemp "$out/.$name.XXXXXXXX")
dpkg-deb --root-owner-group --uniform-compression -Zxz -z6 -b "$stage" "$archive"
chmod 644 "$archive"
mv -f -- "$archive" "$out/$name"
sha256sum "$out/$name"
