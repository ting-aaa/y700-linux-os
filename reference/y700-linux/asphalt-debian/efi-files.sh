#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
w=$(realpath "${1:?EFI work directory}")
cd "$w"
up="$here/../asphalt-upstream"
out="$here/images/uefi"
efi="$w/esp"
sdk="$w/gnu-efi"
py="$w/build-venv/bin/python"
kernel="$w/../ufs/unpacked"
mkdir -p "$out" "$efi"/{EFI/{BOOT,debian,android-devices},loader/entries}
# Preserve the upstream B-slot padding, raw U-Boot payload and board DTB.
cp board-src/u-boot-nodtb.bin u-boot-padded.bin
if [ "$(stat -c %s u-boot-padded.bin)" -lt 41289792 ]; then truncate -s 41289792 u-boot-padded.bin; fi
printf unused | gzip -n > unused.gz
"$py" "$here/../tools/mkbootimg/mkbootimg.py" --header_version 2 --pagesize 4096 --base 0 \
  --kernel_offset 0x8000 --ramdisk_offset 0x01000000 --second_offset 0 --tags_offset 0x100 \
  --dtb_offset 0x01f00000 --dtb board-src/u-boot.dtb --kernel u-boot-padded.bin \
  --ramdisk unused.gz --cmdline '' -o "$out/asphalt-u-boot.img"
test "$(stat -c %s "$out/asphalt-u-boot.img")" -le 100663296
"$py" "$here/../tools/mkbootimg/unpack_bootimg.py" --boot_img "$out/asphalt-u-boot.img" --out extracted-uboot > uboot-header.txt
cmp extracted-uboot/kernel u-boot-padded.bin
cmp extracted-uboot/dtb board-src/u-boot.dtb
cmp extracted-uboot/ramdisk unused.gz

loader=systemd/lib/systemd/boot/efi
echo "76a5bba20322d4929f35c608199f21f80317ae006805315ca215382cdef4c75b  $loader/systemd-bootaa64.efi" | sha256sum -c -
install -m644 "$loader/systemd-bootaa64.efi" "$efi/EFI/BOOT/BOOTAA64.EFI"
install -m644 "$kernel/kernel" "$efi/EFI/debian/kernel.efi"
install -m644 "$kernel/ramdisk" "$efi/EFI/debian/initrd"
install -m644 "$kernel/dtb" "$efi/EFI/debian/board.dtb"
params='androidboot.hardware=qcom androidboot.console=ttyMSM0 androidboot.usbcontroller=a600000.usb androidboot.boot_devices=soc/1d84000.ufshc clk_ignore_unused pd_ignore_unused mem_sleep_default=s2idle'
cat > "$efi/loader/entries/debian.conf" <<ENTRY
title Debian 13 Xfce (Lenovo Y700)
sort-key debian
linux /EFI/debian/kernel.efi
initrd /EFI/debian/initrd
devicetree /EFI/debian/board.dtb
options rdinit=/init root=PARTLABEL=linux rw console=ttyMSM0,115200n8 console=tty0 $params
ENTRY
printf 'default debian.conf\ntimeout 5\neditor no\nauto-reboot yes\nauto-poweroff yes\n' > "$efi/loader/loader.conf"
aarch64-linux-gnu-gcc -I"$sdk/include/efi" -I"$sdk/include/efi/aarch64" -fpic -ffreestanding \
  -fno-stack-protector -fshort-wchar -fno-strict-aliasing -Wall -Wextra -Werror \
  -c "$up/pkgs/mobile-boot-action/main.c" -o action.o
aarch64-linux-gnu-ld -nostdlib --no-undefined -znocombreloc -shared -Bsymbolic --defsym=EFI_SUBSYSTEM=10 \
  -T "$sdk/lib/elf_aarch64_efi_local.lds" "$sdk/lib/crt0-efi-aarch64-local.o" action.o \
  -L"$sdk/lib" -lefi -lgnuefi -o action.so
aarch64-linux-gnu-objcopy -j .text -j .sdata -j .data -j .dynamic -j .dynsym -j .rodata -j .rel \
  -j .rela -j '.rel.*' -j '.rela.*' -j .reloc -O binary action.so "$efi/EFI/android-devices/mobile-boot-action.efi"
for action in android bootloader recovery-b; do
  printf 'title Reboot to %s\nsort-key z-android-action\nefi /EFI/android-devices/mobile-boot-action.efi\noptions %s\n' \
    "$action" "$action" > "$efi/loader/entries/$action.conf"
done

stage="$w/charger-root"
mkdir -p "$stage"/{dev,proc,sys,tmp,run,bin,modules,lib/firmware}
install -m755 "$here/charger-init" "$stage/init"
install -m755 ../ramdisk/bin/busybox "$stage/bin/"
ccsrc="$up/pkgs/mobile-charger"
aarch64-linux-gnu-gcc -static -s -O2 -std=c11 -Wall -Wextra -Werror \
  "$ccsrc"/{main,core,display,ui}.c -lm -o "$stage/bin/mobile-charger"
cp -a ../board-firmware/. "$stage/lib/firmware/"
modules=(qcom_pd_mapper qcom_glink_smem pmic_glink pmic_glink_altmode qcom_battmgr ucsi_glink fsa4480 qcom_q6v5_pas)
for m in "${modules[@]}"; do modprobe -d "$w/../modules" -S 7.3.4-asphalt-prc --show-depends "$m"; done > charger-deps
awk '$1=="insmod" && !seen[$2]++ {print $2}' charger-deps > charger-files
: > "$stage/modules.list"
while read -r ko; do
  name=$(basename "$ko" .zst)
  zstd -dc "$ko" > "$stage/modules/$name"
  echo "/modules/$name" >> "$stage/modules.list"
done < charger-files
cp "$kernel/dtb" charger.dtb
fdtput -t s charger.dtb /soc@0/remoteproc@2400000 status disabled
(cd "$stage" && find . -print0 | LC_ALL=C sort -z | cpio --null --quiet -o -H newc --owner 0:0 | zstd -q -T2 -6) > charger-initrd.zst
printf 'ID=mobile-charger\nPRETTY_NAME="Off-mode charging"\n' > charger-os-release
echo '4ee19937778fdb35a447288fad04307d7606dc2a14eb0524b3dcdcc9cbb397b2  downloads/ukify.py' | sha256sum -c -
"$py" downloads/ukify.py build --efi-arch=aa64 --stub="$loader/linuxaa64.efi.stub" --linux="$kernel/kernel" \
  --initrd=charger-initrd.zst --devicetree=charger.dtb --cmdline="$params android_charger=1 rdinit=/init console=tty2 loglevel=3 consoleblank=0 panic=0" \
  --os-release=@charger-os-release --uname=7.3.4-asphalt-prc --output="$efi/EFI/android-devices/charger.efi"

truncate -s 1G linux-boot.fat
mkfs.fat -S 4096 -s 1 -F 32 -n LINUX-BOOT linux-boot.fat
mcopy -s -i linux-boot.fat "$efi/EFI" "$efi/loader" ::/
fsck.fat -vn linux-boot.fat
verify=$(mktemp -d "$w/esp-check.XXXXXXXX")
mcopy -s -i linux-boot.fat ::/EFI ::/loader "$verify/"
diff -qr "$efi" "$verify"
zstd -T3 -4 -f linux-boot.fat -o "$out/linux-boot.fat.zst"
tar -C "$efi" -cf - EFI/debian loader/entries/debian.conf | zstd -T2 -4 -f -o "$out/debian-esp-files.tar.zst"
tar --zstd -df "$out/debian-esp-files.tar.zst" -C "$efi"
