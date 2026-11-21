#!/usr/bin/env bash
# Test the Qt dialog against an empty CameraManager and explicit inventory events.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: run-chooser-hotplug.sh PATCHED_LIBCAMERA_SOURCE' >&2; exit 2; }
src=$(realpath -e "$1/src/apps/qcam")
fixture=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
read -r -a flags <<< "$(pkg-config --cflags --libs libcamera Qt6Widgets)"
"$(pkg-config --variable=libexecdir Qt6Core)/moc" "$src/cam_select_dialog.h" -o "$work/moc.cpp"
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -fPIC -I "$src" \
    "$fixture/chooser-hotplug.cpp" "$work/moc.cpp" "$src/cam_select_dialog.cpp" "${flags[@]}" -o "$work/dialog"
mkdir -m700 "$work/xdg"
XDG_RUNTIME_DIR="$work/xdg" QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR=2 timeout 15 "$work/dialog"
