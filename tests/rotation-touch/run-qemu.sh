#!/usr/bin/env bash
set -euo pipefail
if (( $# != 7 )); then
    echo 'Usage: run-qemu.sh ROOT.qcow2 KERNEL_BUILD VKMS.ko LIBSSC_0.4.4.tar.gz ARM64_BUILD_ROOT STATIC_ARM64_BUSYBOX ARM64_UV' >&2
    exit 2
fi
disk=$(realpath -e "$1")
kernel=$(realpath -e "$2")
fixture=$(cd -- "$(dirname -- "$0")" && pwd)
touch_fixture=$fixture/../touch-gestures
work=$(mktemp -d "${TMPDIR:-/tmp}/y700-rotation-touch.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
init=$work/init
payload=$init/test
mkdir -p "$init/"{bin,dev,guest,lower,proc,runtime,sys,test}
. "$fixture/../ssc-desktop/stage.sh"
stage_ssc "$work" "$payload" "$kernel" "$(realpath -e "$4")" "$(realpath -e "$5")"
install -m755 "$6" "$init/bin/busybox"
install -m755 "$7" "$payload/uv"
install -m644 "$3" "$payload/vkms.ko"
install -m644 "$touch_fixture/"{fixture.py,fixture.html} "$payload/"
install -m644 "$fixture/"{guest.sh,actor.sh,check.py} "$payload/"
if [[ -n ${SSC_DESKTOP_PROBE:-} ]]; then
    sha256sum "$SSC_DESKTOP_PROBE"
    install -m644 "$SSC_DESKTOP_PROBE" "$payload/desktop-probe.py"
fi
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -O2 -Wall -Wextra -Werror -static \
    "$touch_fixture/evdev-touch.c" -o "$payload/evdev-touch"
cat > "$payload/rotation-fixture.service" <<'UNIT'
[Unit]
Description=Isolated ARM64 Y700 automatic rotation and touch fixture
Requires=systemd-logind.service dbus.service polkit.service systemd-udevd.service
After=systemd-logind.service dbus.service polkit.service systemd-udevd.service
SuccessAction=poweroff-immediate
FailureAction=poweroff-immediate

[Service]
Type=oneshot
TTYPath=/dev/ttyAMA0
StandardOutput=tty
StandardError=tty
TimeoutStartSec=210
ExecStart=/bin/bash /opt/ssc-test/guest.sh
UNIT
cat > "$init/init" <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
trap 'echo ROTATION_INIT_FAILED; poweroff -f' EXIT
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
grep -qw y700.rotation_touch_fixture=1 /proc/cmdline
test "$(cat /sys/block/vda/ro)" = 1
mount -t ext4 -o ro,noload /dev/vda /lower
mount -t tmpfs tmpfs /runtime
mkdir /runtime/upper /runtime/work
mount -t overlay overlay -o lowerdir=/lower,upperdir=/runtime/upper,workdir=/runtime/work /guest
for dir in dev proc sys; do mount --bind "/$dir" "/guest/$dir"; done
mount -t tmpfs tmpfs /guest/run
mkdir -p /guest/opt/ssc-test
cp -a /test/. /guest/opt/ssc-test/
cp /test/rotation-fixture.service /guest/etc/systemd/system/
exec switch_root /guest /sbin/init
INIT
chmod 755 "$init/init"
(cd "$init" && find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$work/initrd")
sha256sum "$disk" "$kernel/arch/arm64/boot/Image" "$3"
args=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then args+=(-L "$QEMU_FIRMWARE_DIR"); fi
timeout -k 5 240 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" -machine virt,gic-version=3 \
    -cpu max -smp 3 -m 1536 -nodefaults -no-user-config -monitor none -display none -serial stdio -nic none -no-reboot \
    -kernel "$kernel/arch/arm64/boot/Image" -initrd "$work/initrd" \
    -append 'console=ttyAMA0 quiet loglevel=3 panic=5 y700.touch_gesture_fixture=1 y700.rotation_touch_fixture=1 fstab=no systemd.unit=rotation-fixture.service systemd.show_status=no' \
    -drive "if=none,id=root,format=qcow2,readonly=on,file=$disk" -device virtio-blk-device,drive=root \
    </dev/null 2>&1 | tr -d '\r' | tee "$work/guest.log"
grep -Fxq 'ROTATION_GUEST_EXIT=0' "$work/guest.log"
grep -Fxq 'Y700_SSC_ROTATION_TOUCH_PASS' "$work/guest.log"
