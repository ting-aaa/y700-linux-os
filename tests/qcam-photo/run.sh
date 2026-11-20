#!/usr/bin/env bash
# Compile the qcam photo store against installed Qt, with no display or camera.
set -euo pipefail
if (( $# != 1 )); then
    echo 'Usage: run.sh PATCHED_LIBCAMERA_SOURCE_DIR' >&2
    exit 2
fi
fixture=$(cd -- "$(dirname -- "$0")" && pwd)
qcam=$(realpath -e -- "$1/src/apps/qcam")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
read -r -a qt_flags <<< "$(pkg-config --cflags --libs Qt6Core Qt6Gui)"
printf 'QCAM_PHOTO_QT %s\n' "$(pkg-config --modversion Qt6Gui)"
sha256sum "$qcam/photo_store.cpp" "$qcam/photo_store.h"
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -fPIC -pthread -I "$qcam" \
    "$fixture/photo-store.cpp" "$qcam/photo_store.cpp" "${qt_flags[@]}" -o "$work/qcam-photo-test"
cd "$work"
TMPDIR="$work" timeout -k 3 120 ./qcam-photo-test
