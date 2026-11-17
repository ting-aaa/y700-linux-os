#!/usr/bin/env bash
# Run as root inside the build WSL distribution with a private copy of the root image.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(realpath "${1:?build directory}")
out="$here/images"
k="$work/linux-7.3.4"
board="$here/../asphalt-upstream/pkgs/asphalt"
root="$work/mount"
stage="$work/ramdisk"
assets="$work/board-firmware"
lenovo="$work/firmware/lenovo/tb320fc"
version=$(<"$k/include/config/kernel.release")
test "$version" = 7.3.4-asphalt-prc
test -f "$work/root.ext4" && test ! -L "$work/root.ext4"
test -f "$k/arch/arm64/boot/Image"
mkdir -p "$out" "$root" "$stage"/{bin,dev,sys,proc,run,newroot} "$assets"
cd "$work/downloads"
sha256sum -c <<'HASHES'
c80a5cda04ea808e8f7235487ddacc3a47a17e5a91189d669228ab9b4cdbfc6a  firmware.tar.zst
77d8979da5c613c85550549dcef8fb8ec6fe2e5576942855ea03179a11597c1f  wcnhpbtfw21.tlv
75229ef38873a51f711c2a38f3d6adcb80e8105e8e1d5e8570aea94b33441fe0  wcnhpnv21g.bin
58e0fa0ab9702c5237b4bea1f0486bcc8af7470fafd2d4ad8d508754fd269b17  topology.tar.gz
HASHES
(cd "$work/firmware" && sha256sum -c --quiet SHA256SUMS)
install -Dm644 "$lenovo/firmware/novatek_ts_fw.bin" "$assets/novatek/lenovo-tb320fc.bin"
qcom="$assets/qcom/sm8475/lenovo/tb320fc"
wifi="$assets/ath11k/WCN6855/hw2.1"
mkdir -p "$qcom" "$wifi" "$assets/qca"
cp "$lenovo"/firmware/{a730_sqe.fw,gmu_gen70000.bin} "$assets/qcom/"
cp "$lenovo"/firmware/{a730_zap.*,vpu20_4v.mbn} "$lenovo"/audio/adsp/adsp.* "$qcom/"
cp "$lenovo"/audio/cs35l45/* "$assets/"
ln -sfn spk1-cs35l45-dsp1-spk-prot.wmfw "$assets/spk2-cs35l45-dsp1-spk-prot.wmfw"
cp "$lenovo/wifi/board-2.bin" "$work"/firmware/oneplus/negroni/WCN6855/hw2.1/{amss.bin,m3.bin,regdb.bin} "$wifi/"
cp wcnhpbtfw21.tlv wcnhpnv21g.bin "$assets/qca/"
m4 -I "$work/topology" "$board/audio/Lenovo-Y700.m4" > "$work/Lenovo-Y700.conf"
alsatplg -c "$work/Lenovo-Y700.conf" -o "$assets/qcom/sm8475/Lenovo-Y700-tplg.bin"

root_id=ef306764-2315-4235-8796-69e2c9b61946
tune2fs -U "$root_id" -L asphalt-debian "$work/root.ext4"
mount -o loop "$work/root.ext4" "$root"
trap 'umount "$root"' EXIT
cp --remove-destination -a "$assets/." "$root/usr/lib/firmware/"
cp -a "$work/modules/lib/modules/$version" "$root/usr/lib/modules/"
rm -f "$root/usr/lib/modules/$version/build" "$root/usr/lib/modules/$version/source"
depmod -b "$root" "$version"
ucm="$root/usr/share/alsa/ucm2"
install -d "$ucm/Lenovo-Y700" "$ucm/conf.d/sm8475"
install -m644 "$board/Lenovo-Y700.conf" "$board/HiFi.conf" "$ucm/Lenovo-Y700/"
ln -sfn ../../Lenovo-Y700/Lenovo-Y700.conf "$ucm/conf.d/sm8475/Lenovo-Y700.conf"
echo asphalt-prc-debian13-xfce-7.3.4-v1 > "$root/etc/y700/image-id"
install -m755 "$here/usb-status" "$root/usr/local/sbin/asphalt-usb-status"
install -m644 "$here/asphalt-usb-status.service" "$root/etc/systemd/system/"
ln -sfn ../asphalt-usb-status.service "$root/etc/systemd/system/multi-user.target.wants/asphalt-usb-status.service"
cat > "$root/etc/udev/rules.d/80-asphalt-ufs.rules" <<'RULE'
ACTION=="add|change", SUBSYSTEM=="devfreq", KERNEL=="1d84000.ufshc", ATTR{max_freq}="75000000"
RULE
# Hide Android UFS volumes from desktop automount on this SD-only installation.
echo 'SUBSYSTEM=="block", KERNEL=="sd*", KERNELS=="1d84000.ufshc", ENV{UDISKS_IGNORE}="1"' > "$root/etc/udev/rules.d/81-asphalt-internal-ufs.rules"
install -m755 "$root/usr/bin/busybox" "$stage/bin/busybox"
install -m755 "$here/init" "$stage/init"
mkdir -p "$stage/lib/firmware"
cp -a "$assets/." "$stage/lib/firmware/"
test -x "$root/usr/bin/startxfce4" && test -x "$root/usr/sbin/lightdm"
chroot "$root" dpkg --audit > "$out/dpkg-audit.txt"
test ! -s "$out/dpkg-audit.txt"
chroot "$root" dpkg-query -W systemd xfce4 lightdm network-manager bluez > "$out/packages.txt"
umount "$root"
trap - EXIT
e2fsck -fn "$work/root.ext4"
(cd "$stage" && find . -print0 | LC_ALL=C sort -z | cpio --null --quiet -o -H newc --owner 0:0 | gzip -n -2) > "$work/initramfs.cpio.gz"
cmdline='rdinit=/init console=ttyMSM0,115200n8 console=tty0 androidboot.hardware=qcom androidboot.usbcontroller=a600000.usb clk_ignore_unused pd_ignore_unused mem_sleep_default=s2idle'
dtb="$k/arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb"
"${UV_BIN:-uv}" run --no-project --python "${UV_PYTHON:-3.12}" python "$here/../tools/mkbootimg/mkbootimg.py" \
  --header_version 2 --pagesize 4096 --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x01000000 \
  --second_offset 0 --tags_offset 0x100 --dtb_offset 0x01f00000 --dtb "$dtb" --cmdline "$cmdline" \
  --kernel "$k/arch/arm64/boot/Image" --ramdisk "$work/initramfs.cpio.gz" --output "$out/asphalt-prc-boot.img"
test "$(stat -c %s "$out/asphalt-prc-boot.img")" -le 100663296
"${UV_BIN:-uv}" run --no-project --python "${UV_PYTHON:-3.12}" python "$here/../tools/mkbootimg/unpack_bootimg.py" \
  --boot_img "$out/asphalt-prc-boot.img" --out "$work/unpacked" > "$out/boot-header.txt"
cmp "$work/unpacked/kernel" "$k/arch/arm64/boot/Image"
cmp "$work/unpacked/ramdisk" "$work/initramfs.cpio.gz"
cmp "$work/unpacked/dtb" "$dtb"
"${UV_BIN:-uv}" run --no-project --python "${UV_PYTHON:-3.12}" python "$here/verify-dtb.py" "$work/unpacked/dtb"
zstd -T4 -4 -f "$work/root.ext4" -o "$out/asphalt-debian.ext4.zst"
cd "$out"
sha256sum asphalt-prc-boot.img asphalt-debian.ext4.zst > SHA256SUMS
zstd --no-asyncio -dc asphalt-debian.ext4.zst | sha256sum > "$work/decoded.sha256"
test "$(cut -d' ' -f1 "$work/decoded.sha256")" = "$(sha256sum "$work/root.ext4" | cut -d' ' -f1)"
install -m644 "$work/decoded.sha256" rootfs-unpacked.sha256
