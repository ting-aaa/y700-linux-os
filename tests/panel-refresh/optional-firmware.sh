#!/bin/bash
# Choose the optional entry over the actual U-Boot EFI console, then let the same menu time out.
set -euo pipefail
[[ $# == 8 ]] || { echo 'Usage: optional-firmware.sh BASE_FAT BASE_ENTRY OPTION UBOOT VIRT_DTB ARM64_BUSYBOX EFIVARFS_KO_ZSTD NEW_DIR' >&2; exit 2; }
driver=$(realpath -e "$(dirname "$0")/../installed-trial/recovery-firmware.py")
fat=$(realpath -e "$1"); base=$(realpath -e "$2"); option=$(realpath -e "$3")
bios=$(realpath -e "$4"); dt=$(realpath -e "$5"); busy=$(realpath -e "$6"); module=$(realpath -e "$7")
work=$(realpath -ms "$8"); umask 077; mkdir -m700 "$work"; cd "$work"
(cd "$base"; echo 'd7d617d453585e69eb04a279f7c3839a7edece65bd9a3887e1a1b7cdaba6a362  SHA256SUMS' | sha256sum -c -; sha256sum --strict -c SHA256SUMS)
(cd "$option"; echo 'e63fcf5b1688ac8a4aed7c382a1e6c7b721b7a112341c9155c035fe65c4516cc  SHA256SUMS' | sha256sum -c -; sha256sum --strict -c SHA256SUMS)
printf '%s  %s\n' 8b2983f8cfae282013e2b920e0f710f0dca260b2abba7718570720e928004860 "$module" | sha256sum -c -
mkdir -p init/{bin,proc,sys,dev}
install -m755 "$busy" init/bin/busybox
zstd -dc "$module" >init/efivarfs.ko
cat >init/qa-init <<'GUEST'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
mount -t devtmpfs dev /dev
exec </dev/console >/dev/console 2>&1
mount -t sysfs sys /sys; mount -t proc proc /proc
insmod /efivarfs.ko
mount -t efivarfs -o ro efivars /sys/firmware/efi/efivars
selected=$(tail -c +5 /sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f | tr -d '\000')
notes=$(sha256sum /sys/kernel/notes | cut -d' ' -f1)
case "$selected" in
    y700-display-12-11.conf) test "$notes" = c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063 ;;
    y700-file-12-11.conf) test "$notes" = 35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6 ;;
    *) exit 1 ;;
esac
if grep -Eq 'y700\.(installed_trial|panel_probe)=|trial-deadline|bless-boot' /proc/cmdline; then exit 1; fi
grep -Fwq root=UUID=c0e447e4-82db-59ee-91d6-0e1ec9d5f45e /proc/cmdline
echo "DISPLAY_OPTION_EFI selected=$selected notes=$notes trial_flags=0"
poweroff -f
GUEST
chmod 755 init/qa-init
(cd init; find . -print0 | cpio --null -oH newc --quiet | gzip -n > ../qa.gz)
truncate -s 180M disk.fat; mkfs.fat -F16 -S4096 disk.fat >/dev/null
mmd -i disk.fat ::/EFI ::/EFI/BOOT ::/EFI/y700-file-12-11 ::/loader ::/loader/entries
mcopy -i "$fat" ::/EFI/BOOT/BOOTAA64.EFI .
mcopy -i disk.fat BOOTAA64.EFI ::/EFI/BOOT/
mcopy -i disk.fat "$base"/EFI/y700-file-12-11/{kernel.efi,initrd} ::/EFI/y700-file-12-11/
mcopy -i disk.fat "$option/EFI/y700-display-12-11.efi" qa.gz ::/EFI/
mcopy -i disk.fat "$dt" ::/EFI/virt.dtb
for entry in "$base"/loader/entries/y700-file-12-11.conf "$option"/loader/entries/y700-display-12-11.conf; do
    awk '/^devicetree /{$0="devicetree /EFI/virt.dtb"} /^initrd /{print; print "initrd /EFI/qa.gz"; next}
         /^options /{$0=$0 " console=ttyAMA0 rdinit=/qa-init"} {print}' "$entry" >"${entry##*/}"
    mcopy -i disk.fat "${entry##*/}" ::/loader/entries/
done
printf 'default y700-file-12-11.conf\ntimeout 8\n' >loader.conf
mcopy -i disk.fat loader.conf ::/loader/
bytes=$(stat -c %s disk.fat); truncate -s $((bytes+2097152)) menu.gpt
printf 'label: gpt\nstart=256,size=%s,type=uefi,name=linux-boot\n' "$((bytes/4096))" | sfdisk --sector-size 4096 menu.gpt > layout.log
dd if=disk.fat of=menu.gpt conv=sparse,notrunc bs=1M seek=1 status=none
for role in trial base; do
    "${UV:-uv}" run --offline --no-project --python /usr/bin/python3 python "$driver" "$bios" "$role" display-option
    mtype -i menu.gpt@@1048576 ::/loader/loader.conf | cmp - loader.conf
done
echo 'PANEL_OPTION_EFI_PASS manual_selection=1 default_next_boot=1 loader_default_unchanged=1'
