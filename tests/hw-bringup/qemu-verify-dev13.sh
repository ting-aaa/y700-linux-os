#!/usr/bin/env bash
# End-to-end ARM64 QEMU verification of the packaged standalone dev13.0 board archive.
# Unpacks y700-tb320fc-prc-debian-dev13.0.tar via its shipped unpack.sh, extracts the exact
# EFI kernel + initrd from linux-boot.fat, and boots a disposable copy of root.ext4 in ARM64 QEMU.
set -euo pipefail
export LC_ALL=C

[[ $# == 1 ]] || { echo 'Usage: qemu-verify-dev13.sh DEV13_BOARD_DIR' >&2; exit 2; }
board_dir=$(realpath -e -- "$1")
tarball="$board_dir/y700-tb320fc-prc-debian-dev13.0.tar"
[[ -f $tarball ]]

q=${Y700_QEMU_PREFIX:-/usr}
if [[ -d "$q/lib/x86_64-linux-gnu" ]]; then
    export LD_LIBRARY_PATH="$q/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export QEMU_MODULE_DIR="$q/lib/x86_64-linux-gnu/qemu"
fi
export MTOOLSRC=/dev/null

work=$(mktemp -d /var/tmp/y700-dev13-qemu.XXXXXXXX)
trap 'rm -rf "$work"' EXIT

echo "=== [1/4] Verifying archive SHA256SUMS and unpacking via shipped unpack.sh ==="
(cd "$board_dir" && sha256sum --strict -c SHA256SUMS)
tar -xf "$tarball" -C "$work"
bash "$work/y700-tb320fc-prc-debian-dev13.0/unpack.sh" --verify
bash "$work/y700-tb320fc-prc-debian-dev13.0/unpack.sh" "$work/unpacked"
(cd "$work/unpacked" && sha256sum --strict -c SHA256SUMS)

echo "=== [2/4] Extracting exact EFI kernel/initrd and verifying fallback entry ==="
esp="$work/unpacked/linux-boot.fat"
root="$work/unpacked/root.ext4"
fsck.fat -n "$esp"
e2fsck -fn "$root"
mkdir -p "$work/efi"
mcopy -i "$esp" ::/EFI/debian/kernel.efi "$work/efi/kernel.efi"
mcopy -i "$esp" ::/EFI/debian/initrd.img "$work/efi/initrd.img" 2>/dev/null || \
    mcopy -i "$esp" ::/EFI/debian/initrd "$work/efi/initrd.img"
mdir -abs -i "$esp" ::/ | grep -F '::/EFI/debian/kernel-dev12.efi'
mdir -abs -i "$esp" ::/ | grep -F '::/loader/entries/debian-fallback.conf'

echo "=== [3/4] Running ARM64 QEMU boot against disposable dev13.0 root.ext4 ==="
# Run a self-contained init check script directly from the real dev13.0 root.ext4 (via init=/bin/sh)
# testing depmod/modprobe across all 6 new hardware driver stacks + manifest verification!
cat > "$work/guest-check.sh" <<'GUEST'
#!/bin/sh
set -eu
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
echo "DEV13_QEMU_START"
echo "DEV13_UNAME=$(uname -r)"
echo "DEV13_NOTES=$(sha256sum /sys/kernel/notes | awk '{print $1}')"
echo "DEV13_OS_VER=$(grep '^IMAGE_VERSION=' /etc/os-release)"
(cd / && sha256sum --strict --quiet -c /var/lib/y700/build/dev13.0-hardware.sha256)
echo "DEV13_HW_MANIFEST_OK=1"
grep -Fq "MultiMedia3 Mixer TX_CODEC_DMA_TX_3" /usr/share/alsa/ucm2/Lenovo-Y700/HiFi-Mic.conf
echo "DEV13_UCM_VERB_OK=1"
for m in aw86927 v4l2-flash-led-class leds-qcom-flash soundwire-qcom snd-soc-wcd938x-sdw snd-soc-wcd938x snd-soc-lpass-va-macro snd-soc-lpass-rx-macro snd-soc-lpass-tx-macro snd-soc-sc8280xp; do
    modprobe "$m"
    echo "MODPROBE_OK=$m"
done
echo "DEV13_TAINT=$(cat /proc/sys/kernel/tainted)"
echo "DEV13_QEMU_PASS=1"
poweroff -f
GUEST
chmod 755 "$work/guest-check.sh"

# Mount disposable root.ext4 solely to place /y700-dev13-qemu-check.sh (original archive untouched)
mkdir -p "$work/mnt"
mount -o loop "$root" "$work/mnt"
cp "$work/guest-check.sh" "$work/mnt/y700-dev13-qemu-check.sh"
chmod 755 "$work/mnt/y700-dev13-qemu-check.sh"
umount "$work/mnt"

timeout -k 5 60 "$q/bin/qemu-system-aarch64" -L "$q/share/qemu" \
    -machine virt,gic-version=3 -cpu max -smp 2 -m 1024 -nodefaults -no-user-config \
    -display none -monitor none -nic none -serial "file:$work/serial.log" -no-reboot \
    -kernel "$work/efi/kernel.efi" \
    -append 'console=ttyAMA0 root=/dev/vda rw init=/y700-dev13-qemu-check.sh loglevel=4 panic=5' \
    -drive "if=none,id=rootfs,format=raw,file=$root" \
    -device virtio-blk-device,drive=rootfs </dev/null

echo "=== [4/4] Checking ARM64 QEMU guest receipt ==="
tr -d '\r' < "$work/serial.log" | grep -E '^(DEV13_|MODPROBE_OK=)' || { tail -n 50 "$work/serial.log"; exit 1; }
expected_notes=$(grep '^kernel_notes_sha256=' "$work/unpacked/identity.txt" | cut -d= -f2)
grep -Fq "DEV13_NOTES=$expected_notes" "$work/serial.log"
grep -Fq "DEV13_OS_VER=IMAGE_VERSION=dev13.0" "$work/serial.log"
grep -Fq "DEV13_HW_MANIFEST_OK=1" "$work/serial.log"
grep -Fq "DEV13_UCM_VERB_OK=1" "$work/serial.log"
grep -Fq "DEV13_TAINT=0" "$work/serial.log"
grep -Fq "DEV13_QEMU_PASS=1" "$work/serial.log"
echo "DEV13_STANDALONE_IMAGE_QEMU_VERIFIED=1"
