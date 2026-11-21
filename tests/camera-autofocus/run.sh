#!/bin/bash
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
library=${CAMERA_LIBDIR:-/opt/y700-camera/lib}
[[ $# == 0 || $# == 1 ]] || { echo "Usage: $0 [OUTPUT_EXECUTABLE]" >&2; exit 2; }
[[ $(dpkg --print-architecture) == arm64 ]]
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
# Link the production implementation in the package, without another copy of the algorithm.
g++ -std=c++17 -O2 -Wall -Wextra "$here/stream.cpp" -I"$repo/packaging/camera-autofocus" \
    -L"$library" -Wl,-rpath-link,"$library" -l:libcamera.so.0.7.2 \
    $(pkg-config --cflags --libs gstreamer-app-1.0 gstreamer-video-1.0) -o "$work/check"
readelf -d "$work/check" | grep -F '[libcamera.so.0.7]' >/dev/null
export GST_REGISTRY="$work/registry.bin" GST_REGISTRY_FORK=no
LD_LIBRARY_PATH="$library" timeout 90 "$work/check"
if [[ $# == 1 ]]; then install -m755 "$work/check" "$1"; fi
