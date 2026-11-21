#!/bin/bash
# Boot both unmodified BLS entries from a disposable copy of the exported generic FAT.
set -euo pipefail
[[ $# == 5 ]] || { echo 'Usage: generic-firmware.sh RELEASE_FAT VIRT_UBOOT VIRT_DTB EFIVARFS_KO_ZSTD NEW_DIR' >&2; exit 2; }
driver=$(realpath -e "$(dirname "$0")/../installed-trial/recovery-firmware.py")
fat=$(realpath -e "$1"); bios=$(realpath -e "$2"); dt=$(realpath -e "$3"); module=$(realpath -e "$4")
work=$(realpath -ms "$5"); umask 077; mkdir -m700 "$work"; cd "$work"
printf '%s  %s\n' 1f6d75c17b5f38ff69d57e13c671bd0c1cbccf0c74cf1ea3f79e2011445ed091 "$fat" \
    8b2983f8cfae282013e2b920e0f710f0dca260b2abba7718570720e928004860 "$module" | sha256sum --strict -c -
mkdir -p original init/qa init/esp
mcopy -s -i "$fat" '::*' original/
[[ ! -e original/extlinux && ! -e original/boot/extlinux ]]
cp original/loader/loader.conf loader.conf
(cd original; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) |
    sed -E 's#  \./EFI/debian/(board\.dtb|initrd)$#  ./EFI/qa-original/\1#' >init/qa/production.sha256
[[ $(wc -l <init/qa/production.sha256) == 13 ]]
zstd -dc "$module" >init/qa/efivarfs.ko
cat > init/init <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
mount -t devtmpfs dev /dev; exec </dev/ttyAMA0 >/dev/ttyAMA0 2>&1
mount -t proc proc /proc; mount -t sysfs sys /sys
insmod /qa/efivarfs.ko
mount -t efivarfs -o ro efivars /sys/firmware/efi/efivars
efi() { tail -c +5 "/sys/firmware/efi/efivars/$1-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f" | tr -d '\000'; }
selected=$(efi LoaderEntrySelected)
test "$(efi LoaderDevicePartUUID | tr A-F a-f)" = 2cd88b43-29b3-41e3-90d1-2063b8cb6ae1
notes=$(sha256sum /sys/kernel/notes | cut -d' ' -f1)
case "$selected" in
    debian.conf) test "$notes" = c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063 ;;
    debian-120.conf) test "$notes" = 35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6 ;;
    *) exit 1 ;;
esac
mount -t vfat -o ro /dev/vda1 /esp
cd /esp; sha256sum -c /qa/production.sha256
options=$(sed -n 's/^options //p' "loader/entries/$selected")
case " $(cat /proc/cmdline) " in *" $options "*) ;; *) exit 1 ;; esac
grep -Fwq root=PARTLABEL=linux /proc/cmdline
if grep -Eq 'y700\.(media|installed_trial|panel_probe)=|trial-deadline|bless-boot' /proc/cmdline; then exit 1; fi
test ! -e extlinux/extlinux.conf
echo "GENERIC_1212_EFI selected=$selected notes=$notes production_files=13 generic_root=1"
poweroff -f
INIT
chmod 755 init/init
(cd init; find . -print0 | cpio --null -oH newc --quiet | gzip -n > ../observer.gz)
# QEMU needs its own DT. Append the observer to the shipped initrd and retain both
# physical originals so the guest can verify every production file after entering EFI.
cat original/EFI/debian/initrd observer.gz > initrd
cp --sparse=always "$fat" test.fat
mmd -i test.fat ::/EFI/qa-original
mcopy -i test.fat original/EFI/debian/{board.dtb,initrd} ::/EFI/qa-original/
mcopy -o -i test.fat "$dt" ::/EFI/debian/board.dtb
mcopy -o -i test.fat initrd ::/EFI/debian/initrd
bytes=$(stat -c %s test.fat); truncate -s $((bytes+2097152)) menu.gpt
printf 'label: gpt\nstart=256,size=%s,type=uefi,uuid=2cd88b43-29b3-41e3-90d1-2063b8cb6ae1,name=linux-boot\n' "$((bytes/4096))" | sfdisk --sector-size 4096 menu.gpt >layout.log
dd if=test.fat of=menu.gpt conv=sparse,notrunc bs=1M seek=1 status=none
for role in base trial; do
    "${UV:-uv}" run --offline --no-project --python /usr/bin/python3 python "$driver" "$bios" "$role" dev1212-generic
    mtype -i menu.gpt@@1048576 ::/loader/loader.conf | cmp - loader.conf
done
echo 'GENERIC_1212_FIRMWARE_PASS unchanged_bls=2 default_dual=1 manual_120=1'
