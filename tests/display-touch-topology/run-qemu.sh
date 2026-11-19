#!/usr/bin/env bash
# Two isolated RandR outputs and one real libinput touchscreen on the Y700 kernel.
set -euo pipefail
if (( $# != 5 )); then
    echo 'Usage: run-qemu.sh ROOT.qcow2 KERNEL BUSYBOX_ARM64 DUMMY_ARM64.deb OLD_Y700_DISPLAY' >&2
    exit 2
fi
disk=$(realpath -e "$1")
kernel=$(realpath -e "$2")
fixture=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-topology.XXXXXXXX")
trap 'rm -r -- "$work"' EXIT
printf '%s  %s\n' 5ed4d469b062060a051d7d0e5edaaf5f1d3c93d9abc3f7989e1beee018cc0c5d "$4" | sha256sum -c -
mkdir -p "$work/init/"{bin,dev,guest,lower,proc,run,sys,test}
install -m755 "$3" "$work/init/bin/busybox"
install -m644 "$4" "$work/init/test/dummy.deb"
install -m755 "$5" "$work/init/test/old-watcher"
install -m755 "$fixture/"{guest.sh,cases.sh} "$work/init/test/"
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -O2 -Wall -Wextra -Werror -static \
    "$fixture/../touch-gestures/evdev-touch.c" -o "$work/init/test/evdev-touch"
cat > "$work/init/init" <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
test "$(cat /sys/block/vda/ro)" = 1
mount -t ext4 -o ro,noload /dev/vda /lower
mount -t tmpfs tmpfs /run
mkdir /run/upper /run/work
mount -t overlay overlay -o lowerdir=/lower,upperdir=/run/upper,workdir=/run/work /guest
for dir in proc sys dev; do mount --bind "/$dir" "/guest/$dir"; done
mount -t tmpfs tmpfs /guest/run
mkdir -p /guest/opt/y700-topology
mount --bind /test /guest/opt/y700-topology
rc=0
chroot /guest /bin/bash /opt/y700-topology/guest.sh || rc=$?
echo "TOPOLOGY_GUEST_EXIT=$rc"
poweroff -f
INIT
chmod 755 "$work/init/init"
(cd "$work/init" && find . -print0 | cpio --null --quiet -o -H newc | gzip -1 > "$work/initrd")
args=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then args+=(-L "$QEMU_FIRMWARE_DIR"); fi
timeout -k 4 150 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" -machine virt,gic-version=3 \
    -cpu max -smp 2 -m 640 -nodefaults -no-user-config -monitor none -display none -serial stdio -nic none -no-reboot \
    -kernel "$kernel" -initrd "$work/initrd" \
    -append 'console=ttyAMA0 loglevel=3 y700.touch_gesture_fixture=1 y700.topology_fixture=1 panic=4' \
    -drive "if=none,id=root,format=qcow2,readonly=on,file=$disk" -device virtio-blk-device,drive=root \
    </dev/null 2>&1 | tr -d '\r' | tee "$work/console"
grep -Fxq 'TOPOLOGY_PASS' "$work/console"
grep -Fxq 'TOPOLOGY_GUEST_EXIT=0' "$work/console"
