#!/usr/bin/env bash
# Build an isolated camera runtime on Debian 13 ARM64.
set -euo pipefail
export LC_ALL=C
umask 022

if [[ $# != 3 ]]; then
    echo 'Usage: build-camera-backport.sh SOURCES ASPHALT_CHECKOUT OUTPUT' >&2
    exit 2
fi
sources=$(realpath -e -- "$1")
asphalt=$(realpath -e -- "$2")
output=$(realpath -m -- "$3")
if [[ $(dpkg --print-architecture) != arm64 || $(. /etc/os-release; printf '%s' "$VERSION_CODENAME") != trixie ]]; then
    echo 'Use an ARM64 Debian trixie build root.' >&2
    exit 1
fi
if [[ $(git -C "$asphalt" rev-parse HEAD) != 8dcb481fc2ce91794fd294630e06f15a52ec7513 ||
      -n $(git -C "$asphalt" status --porcelain --untracked-files=normal) ]]; then
    echo 'Use the exact clean Asphalt checkout from upstream.lock.json.' >&2
    exit 1
fi

(cd "$sources" && sha256sum -c <<'EOF'
b162125bb8d26641b3b71ed32d344a06ae7fb4e732043db7a081615ffd039983  libcamera_0.7.2-1.dsc
437475ac9a4266ce481430a6d7868fa3c94f2e3107729713b3df4fa10c1b0d7e  libcamera_0.7.2-1.debian.tar.xz
e27f5670fe9443eebc8e2f24235cd20b533324ef481a3684d34c78f1c3a12afb  libcamera_0.7.2.orig.tar.gz
EOF
)

jobs=${JOBS:-2}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo 'JOBS must be a positive integer.' >&2; exit 2; }
build=$(mktemp -d)
archive=
trap 'rm -rf -- "$build"; if [[ -n $archive ]]; then rm -f -- "$archive"; fi' EXIT
cd "$build"

# The dsc, diff and tarball are verified against the pinned SHA-256 values above.
dpkg-source --no-check -x "$sources/libcamera_0.7.2-1.dsc" source
patch_dir=$asphalt/pkgs/libcamera
for file in "$patch_dir/asphalt.patch" "$patch_dir"/000[1-6]-*.patch; do
    patch -p1 --batch --forward -d source < "$file"
done

prefix=/opt/y700-camera
meson setup obj source --prefix="$prefix" --libdir=lib \
    --wrap-mode=nodownload -Dbuildtype=release -Doptimization=2 -Dwerror=false \
    -Dpipelines=simple -Dipas=simple -Dsoftisp-gpu=enabled -Dudev=enabled \
    -Dcam=enabled -Dcam-output-kms=disabled -Dcam-output-sdl2=disabled \
    -Dgstreamer=enabled -Ddocumentation=disabled -Dpycamera=disabled -Dqcam=disabled \
    -Dtracing=disabled -Dtest=true -Dv4l2=disabled -Dlc-compliance=disabled
meson compile -C obj -j "$jobs"
meson test -C obj --no-rebuild --print-errorlogs debayer-geometry

package=y700-camera-runtime
stage=debian/$package
DESTDIR="$build/$stage" meson install -C obj --no-rebuild
runtime=$stage$prefix
rm -rf -- "$runtime/include" "$runtime/lib/pkgconfig"
install -Dm644 source/debian/copyright "$stage/usr/share/doc/y700-camera-runtime/copyright"

# Resolve ELF dependencies on Trixie. The bundled libcamera libraries are
# supplied together in this package and never entered in the system cache.
version=0.7.2-1~bpo13+1.y7001
mkdir -p debian "$stage/DEBIAN" "$output"
cat > debian/control <<EOF
Source: $package

Package: $package
Architecture: arm64
EOF
cat > debian/shlibs.local <<EOF
libcamera 0.7 $package (= $version)
libcamera-base 0.7 $package (= $version)
EOF
elf=()
while IFS= read -r -d '' binary; do
    if readelf -h "$binary" >/dev/null 2>&1; then
        elf+=(-e "$binary")
    fi
done < <(find "$runtime" -type f -print0)
depends=$(dpkg-shlibdeps -x"$package" -l"$runtime/lib" -O "${elf[@]}")
[[ $depends == shlibs:Depends=* ]] || { echo 'Could not resolve ELF dependencies.' >&2; exit 1; }
size=$(du -sk "$stage" | cut -f1)
cat > "$stage/DEBIAN/control" <<EOF
Package: $package
Version: $version
Architecture: arm64
Maintainer: Y700 Linux OS contributors <maintainers@example.invalid>
Section: video
Priority: optional
Installed-Size: $size
Depends: ${depends#shlibs:Depends=}
Description: Private libcamera runtime for the Lenovo TB320FC
 Contains the simple pipeline, software ISP, cam and a GStreamer plugin.
 Programs and libraries in /opt/y700-camera require explicit selection.
EOF
filename=${package}_${version}_arm64.deb
archive=$(mktemp "$output/.$filename.XXXXXXXX")
dpkg-deb --root-owner-group --build "$stage" "$archive"
chmod 644 "$archive"
mv -f -- "$archive" "$output/$filename"
