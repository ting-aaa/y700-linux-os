#!/bin/bash
# Build the player-private Iris seek revision from the original Debian sources.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: $0 DEBIAN_SOURCE_ARCHIVES NEW_DIRECTORY [MESON_CROSS_FILE]" >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
work=$(realpath -m "$2")
bash "$here/build-color.sh" "$@"
cd "$work"
patch --batch --fuzz=0 -d src -p1 -i "$here/iris-seek.patch"
target=sys/v4l2/libgstvideo4linux2.so
"${NINJA:-ninja}" -C obj "$target"
mkdir -p seek/private
"${STRIP:-strip}" --strip-unneeded -o seek/private/libgstvideo4linux2.so "obj/$target"
cd seek
readelf -h private/libgstvideo4linux2.so | grep -q 'Machine:.*AArch64'
sha256sum private/libgstvideo4linux2.so > PRIVATE-SHA256SUMS
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - \
    PRIVATE-SHA256SUMS private/libgstvideo4linux2.so | gzip -n > iris-seek-arm64.tar.gz
