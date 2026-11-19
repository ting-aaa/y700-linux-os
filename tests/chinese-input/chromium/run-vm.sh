#!/usr/bin/env bash
set -euo pipefail
if (( $# != 7 )); then
    echo 'Usage: run-vm.sh ROOT.qcow2 ROOT_SHA256 KERNEL KERNEL_SHA256 ARM64_BUSYBOX X11_DEB_DIR ARM64_UV' >&2
    exit 2
fi
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
repo=$(cd -- "$here/../../.." && pwd -P)
leaf=$(realpath -e "$1")
kernel=$(realpath -e "$3")
busybox=$(realpath -e "$5")
assets=$(realpath -e "$6")
uv=$(realpath -e "$7")
[[ $2 =~ ^[a-f0-9]{64}$ && $4 =~ ^[a-f0-9]{64}$ ]]
printf '%s  %s\n' "$2" "$leaf" "$4" "$kernel" | sha256sum -c -
qemu=${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}
qemu_args=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then qemu_args+=(-L "$QEMU_FIRMWARE_DIR"); fi
work=$(mktemp -d /tmp/y700-ime-chromium.XXXXXXXX)
[[ $(realpath -e "$work") =~ ^/tmp/y700-ime-chromium\.[a-zA-Z0-9]{8}$ ]]
trap 'rm -r --one-file-system -- "$work"' EXIT
mkdir -p "$work/init/"{bin,proc,sys,dev,lower,runtime,guest,test/archives}
bundle=$work/init/test
install -m755 "$busybox" "$work/init/bin/busybox"
install -m755 "$uv" "$bundle/uv"
install -m755 "$here/"{desktop.sh,guest.sh} "$bundle/"
install -m644 "$here/"{browser-target.py,browser-probe.py} "$bundle/"
cp "$assets/"{xvfb,xdotool,libxdo3}_*.deb "$bundle/archives/"
install -m644 "$repo/tests/chinese-input/session.sh" "$bundle/"
install -m644 "$repo/tests/chinese-input/probe.py" "$bundle/"
cat > "$work/init/init" <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
test "$(cat /sys/block/vda/ro)" = 1
mount -t ext4 -o ro,noload /dev/vda /lower
mount -t tmpfs tmpfs /runtime
mkdir /runtime/upper /runtime/work
mount -t overlay overlay -o lowerdir=/lower,upperdir=/runtime/upper,workdir=/runtime/work /guest
for dir in dev proc sys; do mount --bind "/$dir" "/guest/$dir"; done
mount -t tmpfs tmpfs /guest/run
mount -t tmpfs -o mode=1777 tmpfs /guest/tmp
mkdir -p /guest/opt/chinese-input
cp -a /test/. /guest/opt/chinese-input/
cp /bin/busybox /guest/opt/chinese-input/
exec switch_root /guest /bin/bash -c '
    rc=0
    bash /opt/chinese-input/guest.sh || rc=$?
    printf "CHINESE_INPUT_CHROMIUM_GUEST_EXIT=%s\n" "$rc"
    /opt/chinese-input/busybox poweroff -n -f
'
INIT
chmod 755 "$work/init/init"
(cd "$work/init"; find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$work/initrd.gz")
timeout -k 5 385 "$qemu" "${qemu_args[@]}" \
    -machine virt,gic-version=3 -cpu max -smp 2 -m 1792 -nodefaults -no-user-config \
    -monitor none -display none -serial stdio -nic none -no-reboot \
    -kernel "$kernel" -initrd "$work/initrd.gz" \
    -append 'console=ttyAMA0 quiet loglevel=3 panic=5 y700.chinese_input_browser=1' \
    -drive "if=none,id=root,format=qcow2,readonly=on,file=$leaf" -device virtio-blk-device,drive=root \
    </dev/null 2>&1 | tr -d '\r' | tee "$work/guest.log"
grep -Fxq CHINESE_INPUT_UI_PASS "$work/guest.log"
grep -Fxq CHINESE_INPUT_CHROMIUM_GUEST_EXIT=0 "$work/guest.log"
grep -Fxq 'CHINESE_INPUT_CHROMIUM_SANDBOX seccomp=2 no_new_privileges=1 separate_pid_namespace=1' "$work/guest.log"
