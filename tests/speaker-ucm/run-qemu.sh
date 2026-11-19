#!/usr/bin/env bash
# Requires the prepared Y700 ARM64 kernel build tree plus its image and root.
set -euo pipefail
if (( $# != 3 )); then
    echo 'Usage: run-qemu.sh KERNEL_BUILD ROOT.qcow2 ARM64_BUSYBOX' >&2
    exit 2
fi
kernel=$(realpath -e "$1")
disk=$(realpath -e "$2")
busybox=$(realpath -e "$3")
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-sound-ucm.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
mkdir -p "$work/init"/{bin,dev,guest,lower,proc,run,sys,test} "$work/module"
cd "$work/module"
cp "$kernel/sound/drivers/dummy.c" .
printf 'obj-m := snd-dummy.o\nsnd-dummy-y := dummy.o\n' > Makefile
make -s -C "$kernel" M="$PWD" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- modules
install -m644 snd-dummy.ko "$work/init/test/"
cd "$work/init"
install -m755 "$busybox" bin/busybox
install -m755 "$here/guest.sh" test/
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -Wall -Wextra -Werror -O2 -static "$here/controls.c" -o test/controls
install -m644 "$repo/packaging/root/usr/share/alsa/ucm2/Lenovo-Y700/HiFi.conf" test/new.conf
upstream="$repo/reference/y700-linux/asphalt-upstream"
git -c safe.directory="$upstream" -C "$upstream" show 8dcb481fc2ce91794fd294630e06f15a52ec7513:pkgs/asphalt/HiFi.conf > test/old.conf
# Apart from the gain and its explanation, keep every factory routing action and its order.
sed -e '/^[[:space:]]*# UCM cset uses raw ALSA units\./d' \
    -e "/name='SPK[12] Digital PCM Volume'/s/ 249\"$/ -40dB\"/" test/new.conf | cmp - test/old.conf
cat > init <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
trap 'rc=$?; echo "SPEAKER_FIXTURE_EXIT=$rc"; poweroff -f' EXIT
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
test "$(cat /sys/block/vda/ro)" = 1
mount -t ext4 -o ro,noload /dev/vda /lower
mount -t tmpfs tmpfs /run
mkdir /run/upper /run/work
mount -t overlay overlay -o lowerdir=/lower,upperdir=/run/upper,workdir=/run/work /guest
for dir in dev proc sys; do mount --bind "/$dir" "/guest/$dir"; done
mount -t tmpfs tmpfs /guest/run
mkdir -p /guest/opt/speaker-test
mount --bind /test /guest/opt/speaker-test
chroot /guest /bin/bash /opt/speaker-test/guest.sh
INIT
chmod 755 init
find . -print0 | cpio --null -o --quiet -H newc | gzip -1 > "$work/initrd"
args=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then args+=(-L "$QEMU_FIRMWARE_DIR"); fi
timeout -k 4 100 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" -machine virt,gic-version=3 \
    -cpu max -m 480 -smp 2 -nodefaults -no-user-config -display none -serial stdio -monitor none -nic none -no-reboot \
    -kernel "$kernel/arch/arm64/boot/Image" -initrd "$work/initrd" \
    -append 'console=ttyAMA0 loglevel=3 panic=4 y700.speaker_fixture=1' \
    -drive "if=none,id=root,format=qcow2,readonly=on,file=$disk" -device virtio-blk-device,drive=root \
    </dev/null 2>&1 | tr -d '\r' | tee "$work/log"
grep -Fxq Y700_SPEAKER_UCM_PASS "$work/log"
grep -Fxq SPEAKER_FIXTURE_EXIT=0 "$work/log"
