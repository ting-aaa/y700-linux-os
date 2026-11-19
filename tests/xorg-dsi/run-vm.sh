#!/usr/bin/env bash
set -euo pipefail
if (( $# != 6 )); then
    echo 'Usage: run-vm.sh ARM64_KERNEL STOCK_ROOT_EXT4 ARM64_BUSYBOX FIXTURE_VKMS_KO PACKAGE_DIR NEW_RECEIPT' >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd -P)
kernel=$(realpath -e "$1")
disk=$(realpath -e "$2")
busybox=$(realpath -e "$3")
module=$(realpath -e "$4")
packages=$(realpath -e "$5")
receipt=$(realpath -m "$6")
test ! -e "$receipt"
work=$(mktemp -d)
trap 'rm -r --one-file-system -- "$work"' EXIT
mkdir -p "$work/init"/{bin,proc,sys,dev,lower,runtime,guest,test}
install -m755 "$busybox" "$work/init/bin/busybox"
install -m755 "$here/init" "$work/init/init"
install -m644 "$here/guest.sh" "$work/init/test/guest.sh"
install -m644 "$module" "$work/init/test/vkms.ko"
for file in xserver-common_21.1.16-1.3+deb13u4+y7001_all.deb xserver-xorg-core_21.1.16-1.3+deb13u4+y7001_arm64.deb; do
    install -m644 "$packages/$file" "$work/init/test/"
done
(cd "$work/init" && find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$work/initramfs")
args=(-machine virt,gic-version=3 -cpu max -smp 2 -m 896 -nodefaults -no-user-config
      -nic none -monitor none -display none -serial stdio -no-reboot
      -kernel "$kernel" -initrd "$work/initramfs"
      -append 'console=ttyAMA0 loglevel=5 panic=5 y700.panel_fixture=1'
      -drive "if=none,id=base,format=raw,readonly=on,file=$disk" -device virtio-blk-device,drive=base)
if [[ -n ${QEMU_DATA_DIR:-} ]]; then args=(-L "$QEMU_DATA_DIR" "${args[@]}"); fi
timeout -k 10 180 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" 2>&1 | tr -d '\r' | tee "$receipt"
grep -Fxq PANEL_GEOMETRY_PASS "$receipt"
grep -Fxq PANEL_CI_EXIT=0 "$receipt"
