#!/bin/bash
# Use the public source and generated include directories from libcamera 0.7.2.
set -euo pipefail
[[ $# == 3 && $(dpkg --print-architecture) == arm64 ]] || { echo 'Usage on ARM64: build-optical.sh SOURCE_INCLUDE GENERATED_INCLUDE NEW_BINARY' >&2; exit 2; }
[[ ! -e $3 && ! -L $3 ]]
here=$(dirname "$(realpath "$0")")
lib=/opt/y700-camera/lib
printf '%s  %s\n' 90dfdbf117fd844ead381f9ffc4f365f35e185a204e0768d70c2c5394fff1773 "$lib/libcamera.so.0.7.2" \
    7de9f8cf7eca33dc7cf4d14da83ed60d1240530f73f45c57484dc263f6ca5b8c "$lib/libcamera-base.so.0.7.2" | sha256sum --strict -c -
work=$(mktemp -d); trap 'rm -r -- "$work"' EXIT
g++ -std=c++17 -O2 -Wall -Wextra -Werror -pthread -I"$1" -I"$2" "$here/optical.cpp" \
    -L"$lib" -Wl,-rpath-link,"$lib" -lcamera -lcamera-base -o "$work/measure"
LD_LIBRARY_PATH="$lib" "$work/measure" --self-test
install -m755 "$work/measure" "$3"
