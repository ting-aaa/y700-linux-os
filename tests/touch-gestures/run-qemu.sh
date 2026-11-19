#!/usr/bin/env bash
# Boot the reviewed Y700 kernel with the exact dev8 root and a disposable test initrd.
set -euo pipefail
if (( $# != 5 )); then
    echo 'Usage: run-qemu.sh ROOT.qcow2 KERNEL BUSYBOX_ARM64 UV_ARM64 DUMMY_ARM64.deb' >&2
    exit 2
fi
disk=$(realpath -e "$1")
kernel=$(realpath -e "$2")
busybox=$(realpath -e "$3")
uv=$(realpath -e "$4")
dummy=$(realpath -e "$5")
test -x "$busybox" && test -x "$uv"
printf '%s  %s\n' 5ed4d469b062060a051d7d0e5edaaf5f1d3c93d9abc3f7989e1beee018cc0c5d "$dummy" | sha256sum -c -
qemu=${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}
qemu_args=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then qemu_args+=(-L "$QEMU_FIRMWARE_DIR"); fi
fixture=$(cd "$(dirname -- "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/y700-gesture.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/init/"{bin,proc,sys,dev,lower,runtime,guest,test}
install -m755 "$busybox" "$work/init/bin/busybox"
install -m755 "$uv" "$work/init/test/uv"
install -m644 "$dummy" "$work/init/test/dummy.deb"
install -m644 "$fixture/"{guest.sh,fixture.py,fixture.html} "$work/init/test/"
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -O2 -Wall -Wextra -Werror -static "$fixture/evdev-touch.c" -o "$work/init/test/evdev-touch"
cat > "$work/init/init" <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
finish() {
    result=$?
    trap - EXIT
    echo "Y700_TOUCH_GUEST_EXIT=$result"
    poweroff -f
}
trap finish EXIT
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t ext4 -o ro,noload /dev/vda /lower
mount -t tmpfs tmpfs /runtime
mkdir /runtime/upper /runtime/work
mount -t overlay overlay -o lowerdir=/lower,upperdir=/runtime/upper,workdir=/runtime/work /guest
for directory in dev proc sys; do
    mount --bind "/$directory" "/guest/$directory"
done
mount -t tmpfs tmpfs /guest/run
mkdir -p /guest/opt/y700-touch-tests
mount -t tmpfs tmpfs /guest/opt/y700-touch-tests
cp -a /test/. /guest/opt/y700-touch-tests/
cp /bin/busybox /guest/opt/y700-touch-tests/busybox
# Chromium's unprivileged user-namespace sandbox is unavailable inside a chroot.
exec switch_root /guest /bin/bash -c '
    rc=0
    /bin/bash /opt/y700-touch-tests/guest.sh || rc=$?
    echo "Y700_TOUCH_GUEST_EXIT=$rc"
    /opt/y700-touch-tests/busybox poweroff -f
'
INIT
chmod 755 "$work/init/init"
(
    cd "$work/init"
    find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$work/initrd.cpio.gz"
)
timeout -k 5 240 "$qemu" "${qemu_args[@]}" -machine virt,gic-version=3 -cpu max -smp 3 -m 2304 \
    -nodefaults -no-user-config -monitor none -display none -serial stdio -nic none -no-reboot \
    -kernel "$kernel" -initrd "$work/initrd.cpio.gz" -append 'console=ttyAMA0 loglevel=5 y700.touch_gesture_fixture=1 panic=5' \
    -drive "if=none,id=root,format=qcow2,readonly=on,file=$disk" -device virtio-blk-device,drive=root \
    </dev/null 2>&1 | tr -d '\r' | tee "$work/guest.log"
grep -Fxq 'Y700_TOUCH_GUEST_EXIT=0' "$work/guest.log"
grep -Fxq 'Y700_CHROMIUM_TOUCH_GESTURES_PASS' "$work/guest.log"
