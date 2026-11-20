# Shared host-side staging for guests exercising the pinned upstream SSC server.
stage_ssc() {
    local work=$1 payload=$2 kernel=$3 upstream=$4 sysroot=$5 ssc_fixture
    ssc_fixture=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    printf '%s  %s\n' 716d6bd6b34d2d753060c6b54c9a87e34fae75b724c763bf9ef487efa3621587 "$upstream" | sha256sum -c -
    mkdir -p "$work"/{source,mod,proto} "$payload/"{lib,python/google}
    cp -- "$ssc_fixture/y700_ssc_qemu.c" "$work/mod/"
    printf 'obj-m += y700_ssc_qemu.o\n' > "$work/mod/Makefile"
    make -s -C "$kernel" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- M="$work/mod" modules
    install -m644 "$work/mod/y700_ssc_qemu.ko" "$payload/"
    tar xzf "$upstream" --strip-components=1 -C "$work/source"
    cp -a "$work/source/mocking/ssc_server" "$payload/"
    sed -e 's|@LIBSSC_MOCKING_PYTHON_BUILD_PATH@|/opt/ssc-test|' -e 's/@VERSION@/0.4.4/' \
        "$payload/ssc_server/ssc-server.in" > "$payload/ssc-server"
    cp -a "$sysroot/usr/lib/python3/dist-packages/google/protobuf" "$payload/python/google/"
    cp -L -- "$sysroot/usr/lib/aarch64-linux-gnu/libqrtr.so.1" "$payload/lib/"
    cp -- "$work/source/data/"ssc-*.proto "$work/proto/"
    unshare --mount --propagation private bash -s -- "$sysroot" "$work/proto" <<'NAMESPACE'
set -eu
mount --bind "$2" "$1/mnt"
chroot "$1" /bin/sh -ec 'cd /mnt && protoc -I . --python_out=. ssc-*.proto'
NAMESPACE
    cp -- "$work/proto/"*_pb2.py "$payload/ssc_server/"
}
