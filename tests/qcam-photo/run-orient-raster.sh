#!/bin/bash
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: $0 PATCHED_LIBCAMERA_SOURCE" >&2; exit 2; }
fixture=$(dirname "$(realpath "$0")")
qcam=$(realpath -e "$1/src/apps/qcam")
w=$(mktemp -d)
trap 'rm -rf -- "$w"' EXIT
moc=$(pkg-config --variable=libexecdir Qt6Core)/moc
for header in camera_orientation viewfinder_qt; do "$moc" "$qcam/$header.h" -o "$w/moc_$header.cpp"; done
c++ -std=c++20 -fPIC -O2 -Wall -Wextra -Werror -DQT_NO_KEYWORDS -I"$qcam" \
    "$fixture/orient-raster.cpp" "$qcam"/{camera_orientation,viewfinder_qt,format_converter,photo_store}.cpp \
    "$qcam/../common/image.cpp" "$w"/moc_*.cpp $(pkg-config --cflags --libs Qt6Widgets xrandr x11 libcamera) \
    -o "$w/orient-raster"
export QT_QPA_PLATFORM=offscreen
for QT_SCALE_FACTOR in 1 2; do export QT_SCALE_FACTOR; timeout -k 3 90 "$w/orient-raster"; done
