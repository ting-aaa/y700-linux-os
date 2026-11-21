#!/usr/bin/env bash
# Build the isolated camera runtime or its optional qcam desktop app on Debian 13 ARM64.
set -euo pipefail
export LC_ALL=C
umask 022

component=runtime
qcam_revision=0
case ${1:-} in
    --qcam) qcam_revision=4 ;;
    --qcam-autofocus) qcam_revision=5 ;;
    --qcam-autofocus-result) qcam_revision=6 ;;
    --qcam-rear-main) qcam_revision=7 ;;
esac
if (( qcam_revision )); then
    component=qcam
    shift
fi
autofocus=0
if [[ $component == runtime && ${1:-} == --autofocus ]]; then
    autofocus=1
    shift
fi
sdk_output=
if [[ -n ${CAMERA_SDK_OUTPUT:-} ]]; then
    [[ $component == runtime && ! -e $CAMERA_SDK_OUTPUT && ! -L $CAMERA_SDK_OUTPUT ]] || {
        echo 'CAMERA_SDK_OUTPUT must name a new directory for a runtime build.' >&2
        exit 2
    }
    sdk_output=$(realpath -m -- "$CAMERA_SDK_OUTPUT")
fi
if [[ $# != 3 ]]; then
    echo 'Usage: build-camera-backport.sh [--autofocus|--qcam|--qcam-autofocus|--qcam-autofocus-result|--qcam-rear-main] SOURCES ASPHALT_CHECKOUT OUTPUT' >&2
    exit 2
fi
sources=$(realpath -e -- "$1")
asphalt=$(realpath -e -- "$2")
output=$(realpath -m -- "$3")
repo=$(dirname -- "$(dirname -- "$(realpath -e -- "$0")")")
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

if (( autofocus )); then
    focus=$repo/packaging/camera-autofocus
    patch -p1 --batch --fuzz=0 -d source < "$focus/simple-focus.patch"
    install -m644 "$focus"/contrast_scan.{cpp,h} source/src/libcamera/pipeline/simple/
    export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1795257600}
    export CFLAGS="${CFLAGS:+$CFLAGS }-ffile-prefix-map=$build=/usr/src/y700-camera"
    export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-ffile-prefix-map=$build=/usr/src/y700-camera"
fi
prefix=/opt/y700-camera
cam=enabled
gstreamer=enabled
qcam=disabled
tests=true
if [[ $component == qcam ]]; then
    patch -p1 --batch --forward -d source < "$repo/packaging/camera-qcam/tablet-photo.patch"
    patch -p1 --batch --forward -d source < "$repo/packaging/camera-qcam/lens-selector.patch"
    if (( qcam_revision >= 5 )); then
        patch -p1 --batch --forward --fuzz=0 -d source < "$repo/packaging/camera-qcam/autofocus-ui.patch"
        cp "$repo/packaging/camera-qcam"/focus_button.{h,cpp} source/src/apps/qcam/
        if (( qcam_revision >= 6 )); then
            patch -p1 --batch --forward --fuzz=0 -d source < "$repo/packaging/camera-qcam/focus-cancel-result.patch"
        fi
    fi
    if (( qcam_revision >= 7 )); then
        patch -p1 --batch --forward --fuzz=0 -d source < "$repo/packaging/camera-qcam/preselect-rear-main.patch"
    fi
    export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1795143600}
    export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-ffile-prefix-map=$build=/usr/src/y700-camera"
    cam=disabled
    gstreamer=disabled
    qcam=enabled
    tests=false
fi
meson setup obj source --prefix="$prefix" --libdir=lib \
    --wrap-mode=nodownload -Dbuildtype=release -Doptimization=2 -Dwerror=false \
    -Dpipelines=simple -Dipas=simple -Dsoftisp-gpu=enabled -Dudev=enabled \
    -Dcam="$cam" -Dcam-output-kms=disabled -Dcam-output-sdl2=disabled \
    -Dgstreamer="$gstreamer" -Ddocumentation=disabled -Dpycamera=disabled -Dqcam="$qcam" \
    -Dtracing=disabled -Dtest="$tests" -Dv4l2=disabled -Dlc-compliance=disabled

runtime_package=y700-camera-runtime
runtime_version=0.7.2-1~bpo13+1.y7001
if (( autofocus )); then runtime_version=0.7.2-1~bpo13+1.y7002; fi
version=$runtime_version
package=$runtime_package
extra_dependencies=
summary='Private libcamera runtime for the Lenovo TB320FC'
details=$' Contains the simple pipeline, software ISP, cam and a GStreamer plugin.\n Programs and libraries in /opt/y700-camera require explicit selection.'
if [[ $component == qcam ]]; then
    package=y700-camera-qcam
    version=0.7.2-1~bpo13+1.y700$qcam_revision
    extra_dependencies="$runtime_package (= $runtime_version), "
    if (( qcam_revision >= 5 )); then
        extra_dependencies="$runtime_package (= 0.7.2-1~bpo13+1.y7001) | $runtime_package (= 0.7.2-1~bpo13+1.y7002), "
    fi
    summary='Qt desktop camera app for the Lenovo TB320FC'
    details=' Saves photos from the Qt viewfinder using the Y700 camera runtime and CPU software ISP.'
fi
stage=debian/$package
runtime=$stage$prefix
if [[ $component == qcam ]]; then
    meson compile -C obj -j "$jobs" qcam
    DESTDIR="$build/$stage" meson install -C obj --no-rebuild --tags bin
    install -Dm755 "$repo/packaging/camera-qcam/y700-camera" "$stage/usr/bin/y700-camera"
    install -Dm644 "$repo/packaging/camera-qcam/org.y700.Camera.desktop" "$stage/usr/share/applications/org.y700.Camera.desktop"
    library_paths=(-l"$build/obj/src/libcamera" -l"$build/obj/src/libcamera/base")
else
    if (( autofocus )); then
        # The enabled test suite also selects vimc. Install both IPA workers
        # and build the geometry regression without compiling every device test.
        ninja -C obj -j "$jobs" src/apps/cam/cam src/gstreamer/libgstlibcamera.so \
            src/ipa/{simple/ipa_soft_simple,vimc/ipa_vimc}.so \
            src/libcamera/proxy/worker/{soft,vimc}_ipa_proxy test/debayer-geometry
    else
        meson compile -C obj -j "$jobs"
    fi
    meson test -C obj --no-rebuild --print-errorlogs debayer-geometry
    DESTDIR="$build/$stage" meson install -C obj --no-rebuild
    if [[ -n $sdk_output ]]; then
        (
            mkdir -p -- "$(dirname "$sdk_output")"
            sdk_tmp=$(mktemp -d -- "$(dirname "$sdk_output")/.camera-sdk.XXXXXXXX")
            trap 'rm -rf -- "$sdk_tmp"' EXIT
            mkdir "$sdk_tmp/lib"
            cp -a -- "$runtime/include" "$sdk_tmp/include"
            cp -a -- "$runtime/lib/pkgconfig" "$sdk_tmp/lib/pkgconfig"
            chmod 755 "$sdk_tmp"
            mv -nT -- "$sdk_tmp" "$sdk_output"
            [[ ! -e $sdk_tmp ]] || { echo 'SDK output appeared during build.' >&2; exit 1; }
        )
    fi
    rm -rf -- "$runtime/include" "$runtime/lib/pkgconfig"
    library_paths=(-l"$runtime/lib")
fi
install -Dm644 source/debian/copyright "$stage/usr/share/doc/$package/copyright"

# Resolve ELF dependencies on Trixie. The bundled libcamera libraries are
# supplied together in this package and never entered in the system cache.
mkdir -p debian "$stage/DEBIAN" "$output"
cat > debian/control <<EOF
Source: $package

Package: $package
Architecture: arm64
EOF
cat > debian/shlibs.local <<EOF
libcamera 0.7 $runtime_package (= $runtime_version)
libcamera-base 0.7 $runtime_package (= $runtime_version)
EOF
elf=()
while IFS= read -r -d '' binary; do
    if readelf -h "$binary" >/dev/null 2>&1; then
        elf+=(-e "$binary")
    fi
done < <(find "$runtime" -type f -print0)
depends=$(dpkg-shlibdeps -x"$runtime_package" "${library_paths[@]}" -O "${elf[@]}")
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
Depends: $extra_dependencies${depends#shlibs:Depends=}
Description: $summary
$details
EOF
filename=${package}_${version}_arm64.deb
archive=$(mktemp "$output/.$filename.XXXXXXXX")
dpkg-deb --root-owner-group --build "$stage" "$archive"
chmod 644 "$archive"
mv -f -- "$archive" "$output/$filename"
