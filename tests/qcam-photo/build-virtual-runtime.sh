#!/usr/bin/env bash
# Build the ARM64 virtual-camera-only libraries for the desktop regression.
set -euo pipefail
[[ ( $# == 2 || ( $# == 3 && $3 == --rear-config-only ) ) && $(dpkg --print-architecture) == arm64 ]] || {
    echo 'Usage on Debian ARM64: build-virtual-runtime.sh libcamera_0.7.2.orig.tar.gz NEW_OUTPUT_DIR [--rear-config-only]' >&2
    exit 2
}
archive=$(realpath -e "$1")
output=$(realpath -m "$2")
[[ ! -e $output && ! -L $output ]]
fixture=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
printf '%s  %s\n' e27f5670fe9443eebc8e2f24235cd20b533324ef481a3684d34c78f1c3a12afb "$archive" | sha256sum --strict -c -
mkdir "$work/source"
tar -xzf "$archive" -C "$work/source" --strip-components=1
patch --batch --fuzz=0 -p1 -d "$work/source" < "$fixture/virtual-buffer-list.patch"
if [[ ${3:-} == --rear-config-only ]]; then
    patch --batch --fuzz=0 -p1 -d "$work/source" < "$fixture/../camera-autofocus/virtual-config-only.patch"
    printf '%s  %s\n' 6b67c9bd191bb3391f232f8d55a916d9dd887c70e5a383148fcfcb09e776b843 \
        "$work/source/src/libcamera/pipeline/virtual/virtual.cpp" | sha256sum --strict -c -
fi
meson setup "$work/build" "$work/source" --prefix=/usr --libdir=lib/aarch64-linux-gnu \
    --wrap-mode=nodownload --buildtype=release -Dwerror=false -Dpipelines=virtual -Dipas= \
    -Dcam=disabled -Dqcam=disabled -Dgstreamer=disabled -Ddocumentation=disabled \
    -Dpycamera=disabled -Dtest=false -Dv4l2=disabled -Dlc-compliance=disabled -Dtracing=disabled
cm=src/libcamera
ninja -C "$work/build" -j "${JOBS:-2}" "$cm/libcamera.so.0.7.2" "$cm/base/libcamera-base.so.0.7.2"
mkdir "$output"
install -m755 "$work/build/$cm/libcamera.so.0.7.2" "$work/build/$cm/base/libcamera-base.so.0.7.2" "$output"
(cd "$output" && sha256sum libcamera*.so.0.7.2 > SHA256SUMS)
