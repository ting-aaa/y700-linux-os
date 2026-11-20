#!/bin/bash
set -euo pipefail
if [[ $# != 9 ]]; then
    echo 'Usage: run.sh ROOT_IMAGE raw|qcow2 KERNEL_BUILD LIBSSC_0.4.4.tar.gz ARM64_BUILD_ROOT STATIC_ARM64_BUSYBOX ARM64_UV RUNTIME_0.1.3.deb ROLLBACK_0.1.1.deb' >&2
    exit 2
fi
fixture=$(cd -- "$(dirname -- "$0")" && pwd)
disk=$(realpath -e "$1")
format=$2
case $format in raw|qcow2) ;; *) exit 2 ;; esac
kernel=$(realpath -e "$3")
upstream=$(realpath -e "$4")
sysroot=$(realpath -e "$5")
busybox=$(realpath -e "$6")
uv=$(realpath -e "$7")
runtime=$(realpath -e "$8")
test "$(dpkg-deb -f "$runtime" Version)" = 0.1.3
rollback=$(realpath -e "$9")
printf '%s  %s\n' ffaaf6288b81582c0f35d76ae4d19e760028761b4fd7b6e48a26230fa237cecb "$rollback" | sha256sum -c -
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
init=$work/init
payload=$work/payload
mkdir -p "$init/"{bin,dev,proc,sys,lower,runtime,guest,payload} "$payload/"
. "$fixture/../ssc-desktop/stage.sh"
stage_ssc "$work" "$payload" "$kernel" "$upstream" "$sysroot"
install -m755 "$fixture/init" "$init/init"
install -m755 "$busybox" "$init/bin/busybox"
install -m755 "$uv" "$payload/uv"
install -m755 "$fixture/guest.sh" "$payload/"
install -m644 "$runtime" "$payload/runtime.deb"
install -m644 "$rollback" "$payload/rollback.deb"
(cd "$init" && find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$work/init.gz")
truncate -s 96M "$work/fixture.ext4"
mke2fs -qt ext4 -d "$payload" -F "$work/fixture.ext4"
qemu=("${QEMU_BIN:-qemu-system-aarch64}")
if [[ -n ${QEMU_DATA_DIR:-} ]]; then qemu+=(-L "$QEMU_DATA_DIR"); fi
modes=(upgrade cold late)
if [[ -n ${SSC_LIFECYCLE_CASE:-} ]]; then
    case $SSC_LIFECYCLE_CASE in upgrade|cold|late) modes=("$SSC_LIFECYCLE_CASE");; *) exit 2;; esac
fi
for mode in "${modes[@]}"; do
    timeout -k 5 240 "${qemu[@]}" -machine virt,gic-version=3 -cpu max -smp 3 -m 1024 \
        -nodefaults -no-user-config -monitor none -display none -serial stdio -nic none -no-reboot \
        -kernel "$kernel/arch/arm64/boot/Image" -initrd "$work/init.gz" \
        -append "rdinit=/init console=ttyAMA0 panic=3 y700.ssc_lifecycle=$mode systemd.unit=ssc-lifecycle.service" \
        -drive "if=none,id=root,format=$format,readonly=on,file=$disk" -device virtio-blk-device,drive=root \
        -drive "if=none,id=test,format=raw,readonly=on,file=$work/fixture.ext4" -device virtio-blk-device,drive=test \
        2>&1 | tr -d '\r' | tee "$work/$mode.log"
    grep -Fxq "SSC_LIFECYCLE_PASS $mode" "$work/$mode.log"
done
