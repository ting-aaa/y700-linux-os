#!/bin/bash
# Qualify the installed ARM64 CPU ISP with anonymous synthetic buffers.
set -euo pipefail
[[ $# == 2 && $(dpkg --print-architecture) == arm64 ]] || { echo 'Usage on ARM64: check-signal-isp.sh LIBCAMERA_SOURCE LIBCAMERA_BUILD' >&2; exit 2; }
src=$(realpath "$1")
gen=$(realpath "$2")
here=$(dirname "$(realpath "$0")")
lib=/opt/y700-camera/lib
printf '%s  %s\n' 90dfdbf117fd844ead381f9ffc4f365f35e185a204e0768d70c2c5394fff1773 "$lib/libcamera.so.0.7.2" \
    7de9f8cf7eca33dc7cf4d14da83ed60d1240530f73f45c57484dc263f6ca5b8c "$lib/libcamera-base.so.0.7.2" \
    1dae9562cc72dabf757cc30a65ad437f563dafddf4c58e21a205741eab495793 "$src/src/libcamera/software_isp/debayer_cpu.cpp" | sha256sum --strict -c -
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
g++ -std=c++20 -O2 -Wall -Wextra -Werror -pthread -DLIBCAMERA_BASE_PRIVATE \
    -I"$src/include" -I"$gen/include" -I"$src/src/libcamera/software_isp" "$here/signal-isp.cpp" \
    -L"$lib" -Wl,-rpath-link,"$lib" -lcamera -lcamera-base -o "$work/signal-isp"
(ulimit -c 0; LD_LIBRARY_PATH="$lib" "$work/signal-isp")
