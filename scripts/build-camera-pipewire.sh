#!/usr/bin/env bash
# Build the optional SPA camera backend in Debian trixie arm64. Install the
# exact y700-camera-runtime package in the build root first. Point CAMERA_SDK
# at the CAMERA_SDK_OUTPUT directory from build-camera-backport.sh.
set -euo pipefail
export LC_ALL=C
umask 022
if [[ $# != 3 ]]; then
    echo 'Usage: build-camera-pipewire.sh PIPEWIRE_SOURCE_ARCHIVES CAMERA_SDK OUTPUT' >&2
    exit 2
fi
sources=$(realpath -e -- "$1")
sdk=$(realpath -e -- "$2")
output=$(realpath -m -- "$3")
repo=$(dirname -- "$(dirname -- "$(realpath -e -- "$0")")")
assets=$repo/packaging/camera-pipewire
package=y700-camera-pipewire
version=1.4.2-1+y700.3
runtime_version=0.7.2-1~bpo13+1.y7001
if [[ $(dpkg --print-architecture) != arm64 || $(. /etc/os-release; echo "$VERSION_CODENAME") != trixie ]]; then
    echo 'Use an ARM64 Debian trixie build root.' >&2
    exit 1
fi
[[ $(dpkg-query -W -f='${db:Status-Status} ${Version}' y700-camera-runtime) == "installed $runtime_version" ]]
jobs=${JOBS:-2}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo 'JOBS must be a positive integer.' >&2; exit 2; }

(cd "$sources" && sha256sum -c <<'EOF'
602242d6287b6813c9c3f04307b438ad12cc257e5d7703afe22ace8b41b3645f  pipewire_1.4.2-1.dsc
aa9098001e1bc2f7742140727e19bcd57812b686840923afda2be6c227b88bf0  pipewire_1.4.2.orig.tar.bz2
2c9fd6e1c5507a5fd063ea97ae5b2d4a28910a4c8a5a6d97923cc5ab5204fd81  pipewire_1.4.2-1.debian.tar.xz
EOF
)
work=$(mktemp -d)
archive=
trap 'rm -rf -- "$work"; if [[ -n $archive ]]; then rm -f -- "$archive"; fi' EXIT
cd "$work"
(cd "$sdk/include"; find libcamera -type f -print0 | sort -z | xargs -0 sha256sum) > headers.sha256
echo 'a1fc872e16fc58b689e71493a4ca406358775bc62e7a2521eb58654bbb6efd5b  headers.sha256' | sha256sum -c -
(cd "$sdk/lib/pkgconfig" && sha256sum -c <<'EOF'
5d7ca9007ab8c43049c6d2d46efda0129594b3e603b4dce9975d54e81dfa9684  libcamera-base.pc
7a845ae84c1047e051abcc3c33d31ee2f5e7c046174751c2d55990b0c3f53f13  libcamera.pc
EOF
)

dpkg-source --no-check -x "$sources/pipewire_1.4.2-1.dsc" source
patch -d source -p1 --batch --forward <"$assets/libcamera-0.7.patch"
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(date -u -d "$(dpkg-parsechangelog -l source/debian/changelog -S Date)" +%s)}
# The SDK supplies headers, the installed private runtime supplies both DSOs.
mkdir -p sdk/lib/pkgconfig
ln -s -- "$sdk/include" sdk/include
for name in libcamera libcamera-base; do
    sed 's|^includedir=.*|includedir=${pcfiledir}/../../include|' \
        "$sdk/lib/pkgconfig/$name.pc" > "sdk/lib/pkgconfig/$name.pc"
done
export PKG_CONFIG_PATH="$work/sdk/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
[[ $(pkg-config --modversion libcamera) == 0.7.2 ]]
export CFLAGS="${CFLAGS:+$CFLAGS }-ffile-prefix-map=$work=/usr/src/$package"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-ffile-prefix-map=$work=/usr/src/$package"
meson setup obj source --prefix=/usr --libdir=lib/aarch64-linux-gnu \
    --wrap-mode=nodownload --buildtype=release -Doptimization=2 -Dauto_features=disabled \
    -Dspa-plugins=enabled -Dlibcamera=enabled '-Dsession-managers=[]'
plugin=spa/plugins/libcamera/libspa-libcamera.so
ninja -j "$jobs" -C obj "$plugin" spa/tools/spa-inspect
stage=$work/debian/$package
DESTDIR="$stage" meson install -C obj --no-rebuild --tags y700-camera
so=$stage/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so
strip --strip-unneeded "$so"
readelf -d "$so" > dynamic
grep -Eq '\(RUNPATH\).*\[/opt/y700-camera/lib\]$' dynamic
# libcamera.so has no RUNPATH of its own. Both libraries must be direct
# dependencies so the dynamic loader uses the plugin's RUNPATH for both.
env -u LD_LIBRARY_PATH ldd "$so" > resolved
for name in libcamera libcamera-base; do
    grep -Fq "Shared library: [$name.so.0.7]" dynamic
    grep -Fq "$name.so.0.7 => /opt/y700-camera/lib/$name.so.0.7 " resolved
done
env -u LD_LIBRARY_PATH obj/spa/tools/spa-inspect "$so" > factories 2>&1
for factory in enum.manager device source; do
    grep -Fq "'api.libcamera.$factory'" factories
done

install -Dm644 "$assets/configuration.yaml" "$stage/opt/y700-camera/etc/libcamera/configuration.yaml"
install -Dm644 "$assets/65-y700-camera.conf" "$stage/usr/share/wireplumber/wireplumber.conf.d/65-y700-camera.conf"
install -Dm644 "$assets/zz-y700-camera" "$stage/etc/chromium.d/zz-y700-camera"
install -Dm644 source/debian/copyright "$stage/usr/share/doc/$package/copyright"
mkdir -p "$stage/DEBIAN" "$output"
printf '%s\n' /etc/chromium.d/zz-y700-camera /opt/y700-camera/etc/libcamera/configuration.yaml > "$stage/DEBIAN/conffiles"
cat > debian/control <<EOF
Source: $package

Package: $package
Architecture: arm64
EOF
cat > debian/shlibs.local <<EOF
libcamera 0.7 y700-camera-runtime (= $runtime_version)
libcamera-base 0.7 y700-camera-runtime (= $runtime_version)
EOF
libs=$(dpkg-shlibdeps -O -l/opt/y700-camera/lib -xy700-camera-runtime "${so#"$work"/}")
[[ $libs == shlibs:Depends=* ]]
cat > "$stage/DEBIAN/control" <<EOF
Package: $package
Version: $version
Architecture: arm64
Maintainer: Y700 Linux OS contributors <maintainers@example.invalid>
Section: video
Priority: optional
Installed-Size: $(du -sk "$stage" | cut -f1)
Depends: libspa-0.2-modules (= 1.4.2-1), wireplumber (>= 0.5), y700-camera-runtime (= $runtime_version), ${libs#shlibs:Depends=}
Provides: libspa-0.2-libcamera (= 1.4.2-1)
Conflicts: libspa-0.2-libcamera
Replaces: libspa-0.2-libcamera
Description: PipeWire camera backend for the Lenovo Y700 TB320FC
 Uses the private libcamera simple pipeline with the CPU software ISP.
EOF
find "$stage" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
filename=${package}_${version}_arm64.deb
archive=$(mktemp -- "$output/.$filename.XXXXXXXX")
dpkg-deb --root-owner-group -Zxz -z6 --build "$stage" "$archive"
chmod 644 "$archive"
mv -f -- "$archive" "$output/$filename"
(cd "$output" && sha256sum "$filename")
