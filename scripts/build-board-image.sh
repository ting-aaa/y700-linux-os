#!/usr/bin/env bash
# Linux root, private build host, regular output files only.
set -euo pipefail
if (( $# != 4 )) && { (( $# != 6 )) || [[ $5 != --gmu-queue-kernel ]]; }; then
    echo 'Usage: build-board-image.sh INTEGRATED_ROOT BOARD_DIRECTORY PRC_BOOT NEW_OUTPUT_DIRECTORY [--gmu-queue-kernel DIRECTORY]' >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
base=$(realpath -e "${1:?integrated Debian root}")
board=$(realpath -e "${2:?board component directory}")
boot=$(realpath -e "${3:?PRC U-Boot Android container}")
out=$(realpath -m "${4:?new dedicated output directory}")
kernel=$board/linux-7.3.4/arch/arm64/boot/Image
notes_digest=
if (( $# == 6 )); then
    candidate=$(realpath -e -- "$6")
    (cd "$candidate"; sha256sum --quiet -c "$repo/config/gmu-queue-kernel.sha256")
    kernel=$candidate/Image
    notes_digest=$(awk '$2=="notes" {print $1}' "$repo/config/gmu-queue-kernel.sha256")
fi
test "$(id -u)" = 0
test "$base" != /
test -f "$base/.y700-base-packages-complete"
test -f "$base/etc/y700/base-configured"
test ! -d "$base/run/systemd/system"
test -s "$base/usr/share/alsa/ucm2/ucm.conf" || {
    echo 'Missing ALSA UCM entry point. Rebuild the base with the current Debian package lock.' >&2
    exit 1
}
test -f "$boot"
for input in "$base" "$board" "$repo/reference"; do [[ "$out/" != "$input/"* ]]; done
mkdir -m700 -- "$out"
cd "$board"
sha256sum --quiet -c "$repo/config/board-components.sha256"
version=7.3.4-asphalt-prc
mods=modules/lib/modules/$version
treehash=$(find board-firmware "$mods" -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
test "$treehash" = 879f905f6423609719a2835d2a6a65f58d1ed3870e4670900646852ed2844ece
test "$(find board-firmware "$mods" -type l | LC_ALL=C sort)" = "$(printf '%s\n' board-firmware/spk2-cs35l45-dsp1-spk-prot.wmfw "$mods/build")"
test "$(readlink board-firmware/spk2-cs35l45-dsp1-spk-prot.wmfw)" = spk1-cs35l45-dsp1-spk-prot.wmfw
test "$(sha256sum "$boot" | cut -d' ' -f1)" = f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8
py=("${UV_BIN:-uv}" run --no-project --python "${UV_PYTHON:-3.13}" python)
package_receipt=$("${py[@]}" "$repo/scripts/verify-image-packages.py" "$base")
dtb="$board/linux-7.3.4/arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb"
"${py[@]}" "$repo/reference/y700-linux/asphalt-debian/verify-dtb.py" "$dtb"
src="$repo/reference/y700-linux/asphalt-upstream"
test "$(git -c safe.directory="$src" -C "$src" rev-parse HEAD)" = 8dcb481fc2ce91794fd294630e06f15a52ec7513
for name in HiFi.conf Lenovo-Y700.conf; do
    git -c safe.directory="$src" -C "$src" show "HEAD:pkgs/asphalt/$name" > "$out/$name"
done
cd "$out"
mkdir stage initrd esp
# The integrated root was freshly constructed; discard per-build/service state.
rsync -aHAX --numeric-ids --one-file-system --exclude='/run/*' --exclude='/tmp/*' \
    --exclude='/var/log/*' --exclude='/root/.config' --exclude='.ssh' --exclude='/etc/ssh/ssh_host_*' \
    --exclude='/var/lib/systemd/random-seed' --exclude='/var/lib/systemd/credential.secret' \
    --exclude='/var/lib/y700/ssh' --exclude='/var/lib/bluetooth/*' \
    --exclude='/var/lib/y700-ssc/*' --exclude='/etc/y700/bluetooth-address' --exclude='/.y700-*' "$base/" stage/
chmod 755 stage
for secret in stage/etc/y700/maintenance* stage/etc/y700/bluetooth-address stage/root/.ssh stage/etc/NetworkManager/system-connections/*; do
    test ! -e "$secret"
done
: > stage/etc/machine-id
mkdir -p "stage/usr/lib/modules/$version" stage/usr/lib/firmware
rsync -a --exclude=/build "$board/$mods/" "stage/usr/lib/modules/$version/"
depmod -b stage "$version"
cp -a "$board/board-firmware/." stage/usr/lib/firmware/
ucm=stage/usr/share/alsa/ucm2
install -d "$ucm/Lenovo-Y700" "$ucm/conf.d/sm8475"
install -m644 HiFi.conf Lenovo-Y700.conf "$ucm/Lenovo-Y700/"
ln -sfn ../../Lenovo-Y700/Lenovo-Y700.conf "$ucm/conf.d/sm8475/Lenovo-Y700.conf"
# ASoC uses the PRC firmware's DMI long name for the UCM card lookup.
ln -sfn Lenovo-Y700.conf "$ucm/conf.d/sm8475/lenovo-LenovoLegionY7002ndgen.conf"
printf '%s\n' 'ACTION=="add|change", SUBSYSTEM=="devfreq", KERNEL=="1d84000.ufshc", ATTR{max_freq}="75000000"' > stage/etc/udev/rules.d/80-asphalt-ufs.rules
printf '%s\n' 'SUBSYSTEM=="block", KERNEL=="sd*", KERNELS=="1d84000.ufshc", ENV{UDISKS_IGNORE}="1"' > stage/etc/udev/rules.d/81-asphalt-internal-ufs.rules
uuid=$(cat /proc/sys/kernel/random/uuid)
imageid="y700-prc-$uuid"
fatid=${uuid:0:8}
fatuuid="${fatid:0:4}-${fatid:4:4}"
printf '%s\n' "$imageid" > stage/etc/y700/image-id
printf 'UUID=%s / ext4 defaults 0 1\nUUID=%s /boot vfat umask=0077 0 2\n' "$uuid" "${fatuuid^^}" > stage/etc/fstab
# Populate ext4 directly from the staged filesystem, including ownership and xattrs.
truncate -s 6G root.ext4
mkfs.ext4 -q -b 4096 -L y700-debian -U "$uuid" -d stage root.ext4
e2fsck -fn root.ext4
test "$(debugfs -R 'cat /etc/y700/image-id' root.ext4 2>/dev/null)" = "$imageid"
mkdir -p initrd/{bin,dev,proc,sys,run,newroot,lib/firmware} esp/EFI/{BOOT,debian,android-devices} esp/loader/entries
install -m755 "$board/ramdisk/bin/busybox" initrd/bin/
cp -a "$board/board-firmware/." initrd/lib/firmware/
sed -e "s/@UUIDHEX@/${uuid//-/}/g" -e "s/@IMAGEID@/$imageid/g" "$repo/src/boot/init" > initrd/init
grep -Fq "${uuid//-/}" initrd/init
grep -Fq "$imageid" initrd/init
chmod 755 initrd/init
(cd initrd && find . -print0 | LC_ALL=C sort -z | cpio --quiet --null -o -H newc --owner 0:0 | gzip -n -2) > esp/EFI/debian/initrd
install -m644 "$kernel" esp/EFI/debian/kernel.efi
if [[ -n $notes_digest ]]; then
    test "$(sha256sum esp/EFI/debian/kernel.efi | cut -d' ' -f1)" = "$(awk '$2=="Image" {print $1}' "$repo/config/gmu-queue-kernel.sha256")"
fi
install -m644 "$dtb" esp/EFI/debian/board.dtb
install -m644 "$board/efi/esp/EFI/BOOT/BOOTAA64.EFI" esp/EFI/BOOT/
for name in charger mobile-boot-action; do install -m644 "$board/efi/esp/EFI/android-devices/$name.efi" esp/EFI/android-devices/; done
for name in debian android bootloader recovery-b; do install -m644 "$board/efi/esp/loader/entries/$name.conf" esp/loader/entries/; done
install -m644 "$board/efi/esp/loader/loader.conf" esp/loader/
install -m644 "$boot" asphalt-prc-u-boot.img
truncate -s 1G linux-boot.fat
mkfs.fat -S 4096 -s 1 -F 32 -i "$fatid" -n LINUX-BOOT linux-boot.fat
mcopy -s -i linux-boot.fat esp/EFI esp/loader ::/
fsck.fat -vn linux-boot.fat
mkdir esp-readback
mcopy -s -i linux-boot.fat ::/EFI ::/loader esp-readback/
diff -qr esp esp-readback
printf 'image_id=%s\nroot_uuid=%s\n%s\n' "$imageid" "$uuid" "$package_receipt" > identity.txt
if [[ -n $notes_digest ]]; then printf 'kernel_notes_sha256=%s\n' "$notes_digest" >> identity.txt; fi
sha256sum asphalt-prc-u-boot.img linux-boot.fat root.ext4 identity.txt > SHA256SUMS
echo 'Candidate files built and read back.'
