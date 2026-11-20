#!/usr/bin/env bash
# Use a signed test-only libcamera 0.7.2 with the virtual pipeline, and the
# original qcam ELF extracted from the supplied Y700 application package.
set -euo pipefail
if (( $# != 7 )); then
    echo 'Usage: run-virtual-qemu.sh ROOT.qcow2 KERNEL QCAM.deb VIRTUAL_RUNTIME_DEBS X11_DEBS ARM64_BUSYBOX ARM64_UV' >&2
    exit 2
fi
disk=$(realpath -e "$1")
kernel=$(realpath -e "$2")
app=$(realpath -e "$3")
runtime=$(realpath -e "$4")
x11=$(realpath -e "$5")
fixture=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/y700-qcam-virtual.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/init/"{bin,proc,sys,dev,lower,runtime,guest,test/runtime,test/x11}
payload=$work/init/test
install -m755 "$6" "$work/init/bin/busybox"
install -m755 "$7" "$payload/uv"
install -m644 "$app" "$payload/qcam.deb"
install -m644 "$fixture/"{virtual-guest.sh,virtual-session.sh,virtual-shutter.py,virtual-cameras.yaml} "$payload/"
install -m644 "$runtime/"*.deb "$payload/runtime/"
install -m644 "$x11/"{libxdo3,xdotool,xvfb}_*.deb "$payload/x11/"
printf 'QCAM_VIRTUAL_ROOT '; sha256sum "$disk"
printf 'QCAM_VIRTUAL_KERNEL '; sha256sum "$kernel"
printf 'QCAM_VIRTUAL_ARCHIVE '; sha256sum "$app"
sha256sum "$runtime/"*.deb
cat > "$work/init/init" <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
finish() {
    result=$?
    trap - EXIT
    echo "QCAM_VIRTUAL_GUEST_EXIT=$result"
    poweroff -f
}
trap finish EXIT
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
grep -qw y700.qcam_virtual_fixture=1 /proc/cmdline
test "$(cat /sys/block/vda/ro)" = 1
mount -t ext4 -o ro,noload /dev/vda /lower
mount -t tmpfs tmpfs /runtime
mkdir /runtime/upper /runtime/work
mount -t overlay overlay -o lowerdir=/lower,upperdir=/runtime/upper,workdir=/runtime/work /guest
for dir in dev proc sys; do mount --bind "/$dir" "/guest/$dir"; done
mount -t tmpfs tmpfs /guest/run
mkdir -p /guest/opt/qcam-virtual
mount --bind /test /guest/opt/qcam-virtual
chroot /guest /bin/bash /opt/qcam-virtual/virtual-guest.sh
INIT
chmod 755 "$work/init/init"
(cd "$work/init" && find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$work/initrd")
args=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then args+=(-L "$QEMU_FIRMWARE_DIR"); fi
preflight=
if [[ ${QCAM_VIRTUAL_PREFLIGHT:-0} == 1 ]]; then preflight=y700.qcam_virtual_preflight=1; fi
case ${QCAM_VIRTUAL_LANGUAGE:-en} in
    en) language= ;;
    zh) language=y700.qcam_virtual_chinese=1 ;;
    *) echo 'QCAM_VIRTUAL_LANGUAGE must be en or zh' >&2; exit 2 ;;
esac
timeout -k 5 360 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" \
    -machine virt,gic-version=3 -cpu max -smp 2 -m 1152 -nodefaults -no-user-config \
    -monitor none -display none -serial stdio -nic none -no-reboot -kernel "$kernel" -initrd "$work/initrd" \
    -append "console=ttyAMA0 quiet loglevel=3 panic=4 y700.qcam_virtual_fixture=1 $preflight $language" \
    -drive "if=none,id=root,format=qcow2,readonly=on,file=$disk" -device virtio-blk-device,drive=root \
    </dev/null 2>&1 | tr -d '\r' | tee "$work/guest.log"
grep -Fxq 'QCAM_VIRTUAL_GUEST_EXIT=0' "$work/guest.log"
if [[ -n $preflight ]]; then
    grep -Fxq 'QCAM_VIRTUAL_PREFLIGHT_PASS' "$work/guest.log"
else
    grep -Fxq 'Y700_QCAM_VIRTUAL_LENS_PASS switches=3 shutters=4 published=4 same_process=yes preview_continued=yes' "$work/guest.log"
fi
