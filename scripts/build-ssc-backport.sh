#!/usr/bin/env bash
# Build on Debian 13 ARM64, including in an emulated build root.
set -euo pipefail
export LC_ALL=C
umask 022

if [[ $# != 4 ]]; then
    echo 'Usage: build-ssc-backport.sh {libssc|proxy|fastrpc} SOURCES ASPHALT_CHECKOUT OUTPUT' >&2
    exit 2
fi
component=$1
sources=$(realpath -e -- "$2")
asphalt=$(realpath -e -- "$3")
output=$(realpath -m -- "$4")
if [[ $(dpkg --print-architecture) != arm64 || $(. /etc/os-release; printf '%s' "$VERSION_CODENAME") != trixie ]]; then
    echo 'Use an ARM64 Debian trixie build root.' >&2
    exit 1
fi
if [[ $(git -C "$asphalt" rev-parse HEAD) != 8dcb481fc2ce91794fd294630e06f15a52ec7513 ||
      -n $(git -C "$asphalt" status --porcelain --untracked-files=normal) ]]; then
    echo 'Use the exact clean Asphalt checkout from upstream.lock.json.' >&2
    exit 1
fi

case "$component" in
    libssc)
        (cd "$sources" && sha256sum -c <<'EOF'
2cfe354bdf711552ae75f3b9c2d5c5c557a7c636caa452ac9abb86014f9409c3  libssc_0.4.4-2.1.dsc
8c1c4623366a25c62e1fbdcef3242504b56751746feaafb48160feb1eca343c8  libssc_0.4.4-2.1.debian.tar.xz
716d6bd6b34d2d753060c6b54c9a87e34fae75b724c763bf9ef487efa3621587  libssc_0.4.4.orig.tar.gz
EOF
        )
        version=0.4.4-2.1
        source_package=libssc
        coordinates=libssc-device-coordinates.patch
        ;;
    proxy)
        (cd "$sources" && sha256sum -c <<'EOF'
92fa4df9f49c8c1596dad44b44212ba30f4958acf86327dec215548ffaa716bd  iio-sensor-proxy_3.9-1.dsc
49312126d19f2249f90c760934665c1ae6fe04d7da452227a694dfd537d34c02  iio-sensor-proxy_3.9-1.debian.tar.xz
19a4ae99b1b8af603fc789841025f9747bf445418d69ec7389e75adb6c8186bf  iio-sensor-proxy_3.9.orig.tar.bz2
EOF
        )
        version=3.9-1
        source_package=iio-sensor-proxy
        coordinates=iio-ssc-device-coordinates.patch
        ;;
    fastrpc)
        (cd "$sources" && sha256sum -c <<'EOF'
49a8078007bd5eeb566e57f9df10c3438e52b1aea8a7dc8518d6894ca18866d2  fastrpc-v1.0.7.tar.gz
EOF
        )
        ;;
    *) echo "Unknown SSC component: $component" >&2; exit 2 ;;
esac

jobs=${JOBS:-2}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo 'JOBS must be a positive integer.' >&2; exit 2; }
build=$(mktemp -d)
archive=
trap 'rm -rf -- "$build"; if [[ -n $archive ]]; then rm -f -- "$archive"; fi' EXIT
cd "$build"

if [[ $component == fastrpc ]]; then
    mkdir source
    tar -xf "$sources/fastrpc-v1.0.7.tar.gz" -C source --strip-components=1
    cd source
    patches=$asphalt/pkgs/mobile/fastrpc
    for name in fastrpc-rflags listener-frame-bounds coherent-rpcmem listener-notify; do
        patch -p1 --batch --forward < "$patches/$name.patch"
    done
    mkdir -p m4
    autoreconf -fi
    CFLAGS="$(dpkg-buildflags --get CFLAGS) -ffile-prefix-map=$build=." \
        LDFLAGS="$(dpkg-buildflags --get LDFLAGS)" \
        ./configure --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu --enable-stricter
    make -j"$jobs" -C src sdsprpcd
    cc -O2 -Wall -Wextra -Iinc -Isrc "$patches/listener-frame-test.c" -o listener-frame-test
    ./listener-frame-test

    # Only stage the SDSP daemon and the libraries it dlopens. The generic
    # FastRPC units and udev policy would affect other DSP domains.
    stage=$build/stage
    libdir=$stage/usr/lib/aarch64-linux-gnu
    install -s -Dm755 src/sdsprpcd "$stage/usr/sbin/sdsprpcd"
    install -d "$libdir"
    # Install via libtool to relink the listener against the final library
    # location. Copying directly from .libs retains an unsafe build RUNPATH.
    ./libtool --mode=install install -c -m644 src/libsdsprpc.la "$libdir/"
    ./libtool --mode=install install -c -m644 src/libsdsp_default_listener.la "$libdir/"
    rm -f -- "$libdir/"*.la
    find "$libdir" -type f -name '*.so.*' -exec strip --strip-debug {} +
    dynamic=$(readelf -d "$libdir/libsdsprpc.so.1" "$libdir/libsdsp_default_listener.so.1")
    if grep -E '\((RPATH|RUNPATH)\)' <<< "$dynamic" | grep -F "$build"; then
        echo 'FastRPC artifact refers to the temporary build directory.' >&2
        exit 1
    fi
    install -Dm644 LICENSE.txt "$stage/usr/share/doc/y700-ssc-fastrpc/copyright"
    mkdir -p "$output"
    filename=y700-ssc-fastrpc_1.0.7_arm64.tar.xz
    archive=$(mktemp "$output/.$filename.XXXXXXXX")
    tar --sort=name --mtime='2026-11-19 00:00:00 UTC' --owner=0 --group=0 \
        --numeric-owner -C "$stage" -cJf "$archive" .
    chmod 644 "$archive"
    mv -f -- "$archive" "$output/$filename"
    exit 0
fi

# These source archives were acquired through Debian's authenticated Sources
# index and checked above by SHA-256, independently of the local GPG keyring.
dpkg-source --no-check -x "$sources/${source_package}_${version}.dsc" source
cd source
mkdir -p debian/patches
cp "$asphalt/overlays/$coordinates" "debian/patches/$coordinates"
printf '%s\n' "$coordinates" >> debian/patches/series
patch -p1 --batch --forward < "debian/patches/$coordinates"
{
    printf '%s (%s~bpo13+1.y7001) trixie; urgency=medium\n\n' "$source_package" "$version"
    printf '  * Build for Debian 13 with the pinned Asphalt SSC coordinate fix.\n\n'
    printf ' -- Y700 Linux OS contributors <maintainers@example.invalid>  Thu, 19 Nov 2026 00:00:00 +0000\n\n'
    cat debian/changelog
} > changelog.y700
mv changelog.y700 debian/changelog

# The in-tree libssc mock daemon needs a kernel QRTR socket. Run the pinned
# coordinate regression below without a DSP or QRTR kernel transport.
export DEB_BUILD_OPTIONS="nocheck parallel=$jobs"
dpkg-buildpackage -b -us -uc

objdir=obj-aarch64-linux-gnu
if [[ $component == libssc ]]; then
    cc -I"$objdir/src" -I"$objdir/data" -Isrc "$asphalt/tests/libssc-coordinates.c" \
        src/libssc-client.c src/libssc-common.c "$objdir"/data/*.pb-c.c \
        $(pkg-config --cflags --libs gio-unix-2.0 qmi-glib libprotobuf-c) -lm -o "$build/test-coordinates"
    "$build/test-coordinates"
else
    cc -Isrc -I"$objdir" "$asphalt/tests/iio-ssc-coordinates.c" \
        src/orientation.c src/accel-mount-matrix.c src/accel-scale.c src/accel-attributes.c src/drivers.c \
        $(pkg-config --cflags --libs gio-2.0 gudev-1.0 libssc) -lm -o "$build/test-coordinates"
    "$build/test-coordinates"
fi

mkdir -p "$output"
for package in "$build"/*.deb; do
    case $(basename "$package") in libssc-tests_*) continue ;; esac
    install -m644 "$package" "$output/"
done
