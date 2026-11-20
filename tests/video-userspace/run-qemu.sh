#!/usr/bin/env bash
# Test sealed Debian userspace in an ARM guest with no V4L2 devices or network adapter.
set -euo pipefail
if (( $# < 6 || $# > 7 )); then
    echo 'Usage: run-qemu.sh ROOT.ext4 KERNEL ARM64_BUSYBOX ARM64_UV ARM64_XORG_DUMMY.deb GENERATED_CLIPS [BOARD_VP9_DIRECTORY]' >&2
    exit 2
fi
root=$(realpath -e "$1")
kernel=$(realpath -e "$2")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/y700-video-userspace.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
printf '%s  %s\n' 2d03b3d2e312f1a425c5b8f657f20fddd45f07caa54b4a937590a720fa2cf511 "$root" \
    4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1 "$kernel" \
    5ed4d469b062060a051d7d0e5edaaf5f1d3c93d9abc3f7989e1beee018cc0c5d "$5" | sha256sum -c -
mkdir -p "$work/init/"{bin,proc,sys,dev,lower,guest,ram,test}
install -m755 "$3" "$work/init/bin/busybox"
install -m755 "$4" "$work/init/test/uv"
cp "$5" "$work/init/test/dummy.deb"
cp "$here/../bluetooth-virtual/dummy.conf" "$work/init/test/"
cp "$here/"{gstreamer.py,desktop.py,player.html,guest.sh} "$work/init/test/"
cp "$6/"{expected.i420,padded.nv12,h264.mp4,hevc.mp4,vp9.webm} "$work/init/test/"
if (( $# == 7 )); then
    cp "$7/clip.webm" "$work/init/test/board-vp9.webm"
    cp "$7/reference.sha256" "$work/init/test/board-vp9.sha256"
fi
cat >"$work/init/init" <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
test "$(cat /sys/block/vda/ro)" = 1
mount -t ext4 -o ro,noload /dev/vda /lower
mount -t tmpfs tmpfs /ram
mkdir /ram/upper /ram/work
mount -t overlay overlay -o lowerdir=/lower,upperdir=/ram/upper,workdir=/ram/work /guest
for dir in dev proc sys; do mount --bind "/$dir" "/guest/$dir"; done
mount -t tmpfs tmpfs /guest/run
mount -t tmpfs -o mode=1777 tmpfs /guest/tmp
mkdir -p /guest/opt/video-userspace
cp /test/* /bin/busybox /guest/opt/video-userspace/
exec switch_root /guest /bin/bash -c '
    rc=0
    bash /opt/video-userspace/guest.sh || rc=$?
    echo VIDEO_USERSPACE_EXIT=$rc
    exec /opt/video-userspace/busybox poweroff -f
'
INIT
chmod 755 "$work/init/init"
(cd "$work/init"; find . -print0 | cpio --null --quiet -o -H newc | gzip -1 >"$work/initrd")
args=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then args+=(-L "$QEMU_FIRMWARE_DIR"); fi
timeout -k 5 240 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" \
    -machine virt,gic-version=3 -cpu max -smp 3 -m 1536 -nodefaults -no-user-config \
    -nic none -no-reboot -monitor none -display none -serial stdio \
    -kernel "$kernel" -initrd "$work/initrd" -append 'console=ttyAMA0 quiet loglevel=3 panic=4 y700.video_userspace=1' \
    -drive "if=none,id=root,format=raw,readonly=on,file=$root" -device virtio-blk-device,drive=root \
    </dev/null 2>&1 | tr -d '\r' | tee "$work/guest.log"
grep -Fxq VIDEO_USERSPACE_EXIT=0 "$work/guest.log"
