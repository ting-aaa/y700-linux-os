#!/bin/bash
# Boot a read-only board root with a temporary QEMU-only SDSP device.
set -euo pipefail
if (( $# != 6 )); then
    echo 'Usage: run.sh ROOT.ext4 KERNEL_BUILD LIBSSC_0.4.4.tar.gz ARM64_BUILD_ROOT STATIC_ARM64_BUSYBOX ARM64_UV' >&2
    exit 2
fi
fixture=$(cd -- "$(dirname -- "$0")" && pwd)
disk=$(realpath -e "$1")
kernel=$(realpath -e "$2")
upstream=$(realpath -e "$3")
sysroot=$(realpath -e "$4")
busybox=$(realpath -e "$5")
uv=$(realpath -e "$6")
test -f "$disk"
test -s "$kernel/arch/arm64/boot/Image"
printf '%s  %s\n' 716d6bd6b34d2d753060c6b54c9a87e34fae75b724c763bf9ef487efa3621587 "$upstream" | sha256sum -c -
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work"/{source,mod,proto} "$work/init/"{bin,proc,sys,dev,lower,runtime,guest,test/lib,test/python/google}
init=$work/init
payload=$init/test
cp -- "$fixture/y700_ssc_qemu.c" "$work/mod/"
printf 'obj-m += y700_ssc_qemu.o\n' > "$work/mod/Makefile"
make -s -C "$kernel" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- M="$work/mod" modules
install -m644 "$work/mod/y700_ssc_qemu.ko" "$fixture/claims.py" "$payload/"
install -m755 "$fixture/guest.sh" "$payload/"
install -m755 "$fixture/init" "$init/init"
install -m755 "$busybox" "$init/bin/busybox"
install -m755 "$uv" "$payload/uv"
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
(
    cd "$init"
    find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$work/initramfs.gz"
)
qemu=( "${QEMU_BIN:-qemu-system-aarch64}" )
if [[ -n ${QEMU_DATA_DIR:-} ]]; then qemu+=( -L "$QEMU_DATA_DIR" ); fi
timeout -k 5 150 "${qemu[@]}" -machine virt,gic-version=3 -cpu max -smp 2 -m 1024 \
    -nodefaults -no-user-config -monitor none -display none -serial stdio -nic none -no-reboot \
    -kernel "$kernel/arch/arm64/boot/Image" -initrd "$work/initramfs.gz" \
    -append 'console=ttyAMA0 loglevel=5 panic=5 y700.ssc_fixture=1' \
    -drive "if=none,id=root,format=raw,readonly=on,file=$disk" -device virtio-blk-device,drive=root \
    2>&1 | tr -d '\r' | tee "$work/guest.log"
grep -Fxq SSC_CI_EXIT=0 "$work/guest.log"
grep -Fxq SSC_DESKTOP_QRTR_PASS "$work/guest.log"
