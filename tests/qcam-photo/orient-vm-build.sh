#!/bin/bash
# Build the signed-source virtual pipeline with the board's observed negotiated orientation.
set -euo pipefail
[[ $# == 2 && $(dpkg --print-architecture) == arm64 ]]
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
cp "$here/"{virtual-buffer-list.patch,orient-vm-virtual.patch} "$tmp/"
cp "$here/orient-vm-probe.cpp" "$tmp/"
old='patch --batch --fuzz=0 -p1 -d "$work/source" < "$fixture/virtual-buffer-list.patch"'
[[ $(grep -Fxc "$old" "$here/build-virtual-runtime.sh") == 1 ]]
awk -v old="$old" '{print; if ($0 == old) {sub(/virtual-buffer-list/, "orient-vm-virtual"); print}}' \
    "$here/build-virtual-runtime.sh" > "$tmp/build.sh"
cat >> "$tmp/build.sh" <<'BUILD'
g++ -std=c++17 -I"$work/source/include" -I"$work/build/include" "$fixture/orient-vm-probe.cpp" \
    -L"$output" -Wl,-rpath-link,"$output" -l:libcamera.so.0.7.2 -l:libcamera-base.so.0.7.2 -o "$output/orientation-probe"
(cd "$output"; sha256sum orientation-probe >> SHA256SUMS)
BUILD
bash "$tmp/build.sh" "$@"
