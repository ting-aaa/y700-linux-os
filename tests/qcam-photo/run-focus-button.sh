#!/usr/bin/env bash
# Run with the libcamera 0.7 development files and Qt 6 Widgets installed.
set -euo pipefail
fixture=$(cd -- "$(dirname -- "$0")" && pwd)
src=$fixture/../../packaging/camera-qcam
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
read -r -a flags <<< "$(pkg-config --cflags --libs libcamera Qt6Widgets)"
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -fPIC -I "$src" \
    "$fixture/focus-button.cpp" "$src/focus_button.cpp" "${flags[@]}" -o "$work/focus-test"
mkdir -m700 "$work/xdg"
QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR=2 XDG_RUNTIME_DIR="$work/xdg" \
    timeout -k 2 80 "$work/focus-test"
