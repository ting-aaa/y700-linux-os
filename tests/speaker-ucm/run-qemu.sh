#!/usr/bin/env bash
# Requires the prepared Y700 ARM64 kernel build tree plus its image and root.
set -euo pipefail
if (( $# != 4 )); then
    echo 'Usage: run-qemu.sh KERNEL_BUILD ROOT.qcow2 ARM64_BUSYBOX ARM64_UV' >&2
    exit 2
fi
kernel=$(realpath -e "$1")
disk=$(realpath -e "$2")
busybox=$(realpath -e "$3")
uv=$(realpath -e "$4")
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
install -m755 "$uv" test/uv
install -m755 "$here/"{guest.sh,stage-observer.sh} test/
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -Wall -Wextra -Werror -O2 -static "$here/controls.c" -o test/controls
install -m644 "$repo/packaging/root/usr/share/alsa/ucm2/Lenovo-Y700/HiFi.conf" test/new.conf
install -m644 "$repo/scripts/speaker-calibration.py" test/speaker-calibration.py
upstream="$repo/reference/y700-linux/asphalt-upstream"
git -c safe.directory="$upstream" -C "$upstream" show 8dcb481fc2ce91794fd294630e06f15a52ec7513:pkgs/asphalt/HiFi.conf > test/old.conf
awk '
    /SPK1 Digital PCM Volume/ { print "        # UCM cset uses raw ALSA units. CS35L45 step 249 is -40.00 dB." }
    /SPK[12] Digital PCM Volume/ { sub(/ -40dB"$/, " 249\"") }
    { print }
' test/old.conf > test/previous.conf
# Keep every previous routing action and its order. The only new actions
# explicitly stop both preloads and run the helper before normal DSP boot.
awk '
    BEGIN { quote = sprintf("%c", 39) }
    /SPK1 DSP1 Firmware. Protection/ {
        print "        cset \"name=" quote "SPK1 DSP1 Preload Switch" quote " 0\""
        print "        cset \"name=" quote "SPK2 DSP1 Preload Switch" quote " 0\""
    }
    /SPK1 DSP1 Preload Switch. 1/ { print "        shell \"/usr/libexec/y700-speaker-calibration stage\"" }
    { print }
' test/previous.conf | cmp - test/new.conf
sha256sum "$disk" "$kernel/arch/arm64/boot/Image" test/{old.conf,previous.conf,new.conf,speaker-calibration.py}
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
timeout -k 4 150 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" -machine virt,gic-version=3 \
    -cpu max -m 480 -smp 2 -nodefaults -no-user-config -display none -serial stdio -monitor none -nic none -no-reboot \
    -kernel "$kernel/arch/arm64/boot/Image" -initrd "$work/initrd" \
    -append 'console=ttyAMA0 loglevel=3 panic=4 y700.speaker_fixture=1' \
    -drive "if=none,id=root,format=qcow2,readonly=on,file=$disk" -device virtio-blk-device,drive=root \
    </dev/null 2>&1 | tr -d '\r' | tee "$work/log"
grep -Fxq Y700_SPEAKER_UCM_PASS "$work/log"
grep -Fxq SPEAKER_FIXTURE_EXIT=0 "$work/log"
grep -Fxq 'SPEAKER_STAGE_RETURN case=generic rc=0 amp=off preload=off gain=249' "$work/log"
grep -Fxq 'SPEAKER_STAGE_RETURN case=calibrated rc=0 amp=off preload=off gain=361' "$work/log"
grep -Eq '^SPEAKER_INVALID_UCM_RESULT libasound=-[1-9][0-9]* active=0$' "$work/log"
grep -Fxq 'SPEAKER_INVALID_ABORT amp=off preload=off previous_samples=unchanged' "$work/log"
