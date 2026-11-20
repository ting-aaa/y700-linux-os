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
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/init/"{bin,proc,sys,dev,lower,runtime,guest,test}
init=$work/init
payload=$init/test
. "$fixture/stage.sh"
stage_ssc "$work" "$payload" "$kernel" "$upstream" "$sysroot"
install -m644 "$fixture/claims.py" "$payload/"
install -m755 "$fixture/guest.sh" "$payload/"
install -m755 "$fixture/init" "$init/init"
install -m755 "$busybox" "$init/bin/busybox"
install -m755 "$uv" "$payload/uv"
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
