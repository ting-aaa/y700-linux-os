#!/bin/bash
# Use the controller-generated menu on a private copy, with QEMU's DT and an EFI variable observer.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
mode=recovery; prefix=y700-installed-recovery-qarecovery
if [[ ${1:-} == --rtc1 ]]; then shift; mode=rtc1; prefix=y700-installed-rtc1-qartc; fi
[[ $# == 5 ]] || { echo 'Usage: recovery-firmware.sh [--rtc1] MENU_QA_DIR VIRT_UBOOT VIRT_DTB ARM64_BUSYBOX EFIVARFS_KO_ZSTD' >&2; exit 2; }
work=$(realpath -e "$1")
bios=$(realpath -e "$2"); dt=$(realpath -e "$3"); busy=$(realpath -e "$4")
efivarfs=$(realpath -e "$5")
[[ $work == /var/tmp/y700-recovery-menu.* && -s $work/menu.fat && -d $work/armed-loader ]]
mkdir -m700 "$work/firmware"; cd "$work/firmware"
mkdir -p init/{bin,dev,proc,sys}
install -m755 "$busy" init/bin/busybox
printf '%s  %s\n' 8b2983f8cfae282013e2b920e0f710f0dca260b2abba7718570720e928004860 "$efivarfs" | sha256sum --strict -c -
zstd -dc "$efivarfs" >init/efivarfs.ko
cat > init/qa-init <<'GUEST'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
mount -t devtmpfs dev /dev
exec </dev/console >/dev/console 2>&1
mount -t sysfs sys /sys
mount -t proc proc /proc
insmod /efivarfs.ko
mount -t efivarfs -o ro efivars /sys/firmware/efi/efivars
key=/sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
selected=$(cat "$key" | tail -c +5 | tr -d '\000')
case "$selected" in
    y700-installed-recovery-qarecovery-trial.conf)
        grep -Fwq y700.installed_trial=qarecovery /proc/cmdline
        grep -Fwq y700.recovery=journal /proc/cmdline
        echo "RECOVERY_EFI selected=$selected recovery=1"
        reboot -f ;;
    y700-installed-recovery-qarecovery-base.conf)
        if grep -Eq ' y700\.(installed_trial|recovery)=' /proc/cmdline; then exit 1; fi
        grep -Fwq y700.release=dev12.10 /proc/cmdline
        echo "RECOVERY_EFI selected=$selected recovery=0"
        poweroff -f ;;
    y700-installed-rtc1-qartc-trial.conf)
        grep -Fwq y700.installed_trial=qartc /proc/cmdline
        grep -Fwq y700.recovery=journal /proc/cmdline
        grep -Fwq y700.rtc_probe=rtc1 /proc/cmdline
        test "$(tr -d '\000' </proc/device-tree/aliases/rtc1)" = /pl031@9010000
        echo "RTC1_EFI selected=$selected virtual_alias=1"
        reboot -f ;;
    y700-installed-rtc1-qartc-base.conf)
        if grep -Eq ' y700\.(installed_trial|rtc_probe)=' /proc/cmdline; then exit 1; fi
        grep -Fwq y700.recovery=journal /proc/cmdline
        test ! -e /proc/device-tree/aliases/rtc1
        echo "RTC1_EFI selected=$selected virtual_alias=0"
        poweroff -f ;;
    *) exit 1 ;;
esac
GUEST
chmod 755 init/qa-init
(cd init; find . -print0 | cpio -o -H newc --null --quiet | gzip -n -1 > ../observer.gz)
# This test filesystem has 512-byte BPB sectors, so reformat on a separate 4Kn-compatible FAT.
truncate -s 600M esp4k.fat
mkfs.fat -F16 -S4096 esp4k.fat >/dev/null
mkdir sources
mcopy -s -i ../menu.fat '::/EFI' sources/
mcopy -i esp4k.fat -s sources/EFI ::/
mcopy -i esp4k.fat -s ../armed-loader ::/loader
mcopy -i esp4k.fat "$dt" ::/EFI/qa-virt.dtb
mcopy -i esp4k.fat observer.gz ::/EFI/qa-observer.gz
if [[ $mode == rtc1 ]]; then
    cp "$dt" rtc1-virt.dtb
    fdtput -t s rtc1-virt.dtb /aliases rtc1 /pl031@9010000
    mcopy -i esp4k.fat rtc1-virt.dtb ::/EFI/qa-rtc1-virt.dtb
fi
for original in ../armed-loader/entries/y700-installed-*.conf; do
    qa_dt=/EFI/qa-virt.dtb
    if [[ $mode == rtc1 && $original == *-trial+1.conf ]]; then qa_dt=/EFI/qa-rtc1-virt.dtb; fi
    awk -v dt="$qa_dt" '/^devicetree / {print "devicetree " dt;next}
         /^initrd / {print; print "initrd /EFI/qa-observer.gz"; next}
         /^options / {$0=$0 " console=ttyAMA0 rdinit=/qa-init"} {print}' "$original" > boot.conf
    mcopy -o -i esp4k.fat boot.conf "::/loader/entries/${original##*/}"
done
sed 's/^timeout .*/timeout 0/' ../armed-loader/loader.conf > loader.conf
mcopy -o -i esp4k.fat loader.conf ::/loader/loader.conf
bytes=$(stat -c %s esp4k.fat)
truncate -s 0 menu.gpt; truncate -s $((bytes+2097152)) menu.gpt
printf 'label: gpt\nstart=256,size=%s,type=uefi,name=linux-boot\n' "$((bytes/4096))" | sfdisk --sector-size 4096 menu.gpt > layout.log
dd if=esp4k.fat of=menu.gpt conv=sparse,notrunc bs=1M seek=1 status=none
for role in trial base; do
    "${UV:-uv}" run --offline --no-project --python /usr/bin/python3 python "$here/recovery-firmware.py" "$bios" "$role" "$mode"
    mdir -b -i menu.gpt@@1048576 ::/loader/entries/ | grep -Fx "::/loader/entries/$prefix-trial+0-1.conf"
done
echo "RECOVERY_FIRMWARE_PASS mode=$mode actual_count_consumed=1 trial_id_without_count=1 second_boot_previous_file_entry=1"
