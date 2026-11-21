#!/usr/bin/env bash
# Run with the libcamera 0.7 development files and Qt 6 Widgets installed.
set -euo pipefail
fixture=$(cd -- "$(dirname -- "$0")" && pwd)
src=$fixture/../../packaging/camera-qcam
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
mode=${1:---cancel-result}
case "$mode" in
    --cancel-result)
        mkdir -p "$work/src/apps/qcam"
        cp "$src"/focus_button.{cpp,h} "$work/src/apps/qcam/"
        patch --batch --fuzz=0 -p1 -d "$work" < "$src/focus-cancel-result.patch"
        src=$work/src/apps/qcam
        ;;
    --y7005) ;;
    *) echo 'Usage: run-focus-button.sh [--cancel-result|--y7005]' >&2; exit 2 ;;
esac
read -r -a flags <<< "$(pkg-config --cflags --libs libcamera Qt6Widgets)"
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -fPIC -I "$src" \
    "$fixture/focus-button.cpp" "$src/focus_button.cpp" "${flags[@]}" -o "$work/focus-test"
mkdir -m700 "$work/xdg"
QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR=2 XDG_RUNTIME_DIR="$work/xdg" \
    timeout -k 2 80 "$work/focus-test" "$mode"
