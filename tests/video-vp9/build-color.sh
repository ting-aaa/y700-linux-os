#!/bin/bash
# Build the optional partial-input-color revision alongside the original trial.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: $0 DEBIAN_SOURCE_ARCHIVES NEW_DIRECTORY [MESON_CROSS_FILE]" >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
work=$(realpath -m "$2")
bash "$here/build.sh" "$@"
cd "$work"
patch --batch --fuzz=0 -d src -p1 -i "$here/iris-color.patch"
cp "$here/iris-input-color.h" src/sys/v4l2/
target=sys/v4l2/libgstvideo4linux2.so
"${NINJA:-ninja}" -C obj "$target"
mkdir -p color-r2/private
"${STRIP:-strip}" --strip-unneeded -o color-r2/private/libgstvideo4linux2.so "obj/$target"
cd color-r2
readelf -h private/libgstvideo4linux2.so | grep -q 'Machine:.*AArch64'
sha256sum private/libgstvideo4linux2.so > PRIVATE-SHA256SUMS
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - \
    PRIVATE-SHA256SUMS private/libgstvideo4linux2.so | gzip -n > iris-input-color-r2-arm64.tar.gz
