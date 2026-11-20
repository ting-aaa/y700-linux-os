#!/bin/bash
# Cross or native ARM64 build of only the Debian video4linux2 plugin.
set -eu -o pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: $0 DEBIAN_SOURCE_ARCHIVES NEW_DIRECTORY [MESON_CROSS_FILE]" >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
archives=$(realpath "$1")
work=$(realpath -m "$2")
cross=()
if [[ $# == 3 ]]; then cross=(--cross-file "$(realpath "$3")"); fi
mkdir "$work"
cd "$archives"
sha256sum -c - <<'SHA'
0bfeebc432fb07e0cf3647c301c900697ea4ff13776fe6da85a0693e2f110ca3  gst-plugins-good1.0_1.26.2-1+deb13u2.dsc
d864b9aec28c3a80895468c909dd303e5f22f92d6e2b1137f80e2a1454584339  gst-plugins-good1.0_1.26.2.orig.tar.xz
a52f49271f6831942bad02fa2d6c54675b1bda054396ed76a9f0515b3d3888c4  gst-plugins-good1.0_1.26.2.orig.tar.xz.asc
3b9fd22c35d15760164993dd80620202c74dda9592610eec59dd80257167df99  gst-plugins-good1.0_1.26.2-1+deb13u2.debian.tar.xz
SHA
cd "$work"
mkdir src
tar xf "$archives/gst-plugins-good1.0_1.26.2.orig.tar.xz" -C src --strip-components=1
tar xf "$archives/gst-plugins-good1.0_1.26.2-1+deb13u2.debian.tar.xz" -C src
cd src
while read -r name; do
    case "$name" in ''|'#'*) continue ;; esac
    patch --batch --fuzz=0 -p1 -i "debian/patches/$name"
done < debian/patches/series
cd ..
uv run --offline --no-project --python "${MESON_PYTHON:-python3}" python -B -m mesonbuild.mesonmain setup \
    --wrap-mode=nofallback "${cross[@]}" -Dauto_features=disabled -Dv4l2=enabled \
    -Dv4l2-gudev=enabled -Dv4l2-libv4l2=enabled -Dv4l2-probe=true --buildtype=release obj src

target=sys/v4l2/libgstvideo4linux2.so
for variant in stock private; do
    if [[ $variant == private ]]; then
        patch --batch --fuzz=0 -d src -p1 -i "$here/iris-vp9.patch"
        cp "$here/iris-vp9-startup.h" src/sys/v4l2/
    fi
    "${NINJA:-ninja}" -C obj "$target"
    mkdir "$variant"
    "${STRIP:-strip}" --strip-unneeded -o "$variant/libgstvideo4linux2.so" "obj/$target"
    readelf -h "$variant/libgstvideo4linux2.so" | grep -q 'Machine:.*AArch64'
done
sha256sum {stock,private}/libgstvideo4linux2.so > SHA256SUMS
sha256sum -c SHA256SUMS
sha256sum private/libgstvideo4linux2.so > PRIVATE-SHA256SUMS
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - \
    PRIVATE-SHA256SUMS private/libgstvideo4linux2.so | gzip -n > iris-vp9-arm64-trial.tar.gz
