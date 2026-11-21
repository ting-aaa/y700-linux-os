#!/bin/bash
# Build the optional diagnostic client, private IPA and device-free IPC test.
set -euo pipefail
[[ $# == 3 && $(dpkg --print-architecture) == arm64 ]] || {
    echo 'Usage on ARM64: build-bracket.sh LIBCAMERA_SOURCE LIBCAMERA_BUILD NEW_OUTPUT_DIRECTORY' >&2; exit 2;
}
here=$(dirname "$(realpath "$0")")
src=$(realpath "$1")
gen=$(realpath "$2")
out=$3
[[ ! -e $out && ! -L $out ]]
lib=/opt/y700-camera/lib
printf '%s  %s\n' \
    90dfdbf117fd844ead381f9ffc4f365f35e185a204e0768d70c2c5394fff1773 "$lib/libcamera.so.0.7.2" \
    7de9f8cf7eca33dc7cf4d14da83ed60d1240530f73f45c57484dc263f6ca5b8c "$lib/libcamera-base.so.0.7.2" \
    7786d2709aa362f36cd56da015f8667f93501e7b072285ea729f86f8f1fb6e67 "$lib/libcamera/ipa/ipa_soft_simple.so" \
    3e7411f620957a8be6822d30ecaa238b78ef89aa8d82d5abb6bb2bd82229cb40 /opt/y700-camera/libexec/libcamera/soft_ipa_proxy \
    | sha256sum --strict -c -
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
options=(-std=c++20 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -pthread -I"$src/include" -I"$gen/include")
libs=(-L"$lib" -Wl,-rpath-link,"$lib" -lcamera -lcamera-base)
g++ "${options[@]}" "$here/optical.cpp" "${libs[@]}" -o "$work/y700-bracket-measure"
g++ "${options[@]}" -DLIBCAMERA_BASE_PRIVATE -shared -fPIC "$here/bracket-ipa.cpp" "${libs[@]}" -ldl -o "$work/ipa_bracket.so"
g++ "${options[@]}" -DLIBCAMERA_BASE_PRIVATE "$here/bracket-ipa-test.cpp" "${libs[@]}" -o "$work/bracket-test"
LD_LIBRARY_PATH="$lib" "$work/y700-bracket-measure" --self-test
mkdir -- "$out"
install -m755 "$work/y700-bracket-measure" "$work/bracket-test" "$out"
install -m644 "$work/ipa_bracket.so" "$out"
(cd "$out"; sha256sum bracket-test ipa_bracket.so y700-bracket-measure > SHA256SUMS)
