#!/usr/bin/env bash
# Make a new sparse disk FILE and use QEMU copy-on-write for guest writes.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
images=$(realpath -e "${1:?candidate directory}")
board=$(realpath -e "${2:?board component directory}")
qemu=$(realpath -e "${3:?extracted QEMU bundle}")
vm=$(realpath -m "${4:?new VM directory}")
card=
overlay=
variant=${7:-}
[[ -z $variant || $variant == --fallback-120 ]]
if [[ -n ${5:-} ]]; then card=$(realpath -e "$5"); fi
if [[ -n ${6:-} ]]; then overlay=$(realpath -e "$6"); fi
if [[ -n $overlay ]]; then test -n "$card"; fi
mkdir -m700 -- "$vm"
cd "$images"
sha256sum -c SHA256SUMS
package_count=$(sed -n 's/^package_count=//p' identity.txt)
package_digest=$(sed -n 's/^package_digest=//p' identity.txt)
notes_digest=$(sed -n 's/^kernel_notes_sha256=//p' identity.txt)
fbdev=$(sed -n 's/^fbdev_emulation=//p' identity.txt)
[[ -z $fbdev || $fbdev == 0 ]]
[[ -z $notes_digest || $notes_digest =~ ^[0-9a-f]{64}$ ]]
if [[ -z $package_count && -z $package_digest ]]; then
    # Historical candidate 03 predates the package receipt in identity.txt.
    package_count=993
    package_digest=af07f62e90d1eb88cf0173225b92778d759af652241e8a67fea6d73b8a68c85c
fi
[[ $package_count =~ ^[1-9][0-9]*$ && $package_digest =~ ^[0-9a-f]{64}$ ]]
test "$(stat -c %s linux-boot.fat)" = 1073741824
test "$(stat -c %s root.ext4)" = 6442450944
cd "$board"
sha256sum --quiet -c <<'HASHES'
ccfe8c4136a02adccdc68b2e7567fa4a06cc8874213064f62f20463803706c4f  efi/qemu-uboot/u-boot.bin
a89bc8f2ee12f118656c6963fb9d45b862e6d5a1aeedf2630ddbe08f03079d31  efi/vm/board.dtb
HASHES
cd "$vm"
sector=4096
label=linux-boot
esp=test-esp.fat
split=0
dual=0
expected_root=$images/root.ext4
selected=y700-test.conf
payload_dir=y700-test
qa_options='console=ttyAMA0 loglevel=7 systemd.show_status=yes'
if [[ -n "$card" ]]; then
    (cd "$card" && sha256sum -c SHA256SUMS)
    if mdir -b -i "$card/y700-test-card.img@@1048576" ::/loader/entries/debian-120.conf >/dev/null 2>&1; then
        dual=1; payload_dir=y700-sd-12-12; selected=$payload_dir.conf
        expected_root=$card/card-root.ext4
        cmp "$images/SHA256SUMS" "$card/SOURCE-SHA256SUMS"
        if [[ -n $variant ]]; then
            [[ -n $overlay ]]
            selected=$payload_dir-120.conf
            notes_digest=35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6
        fi
    fi
    sector=512
    label=y700-test-esp
    if [[ -n $overlay ]]; then
        # Use the complete exported card as the read-only backing disk.
        ln -s -- "$card/y700-test-card.img" disk.gpt
        split=1
    else
        cp --sparse=always "$card/y700-test-card.img" disk.gpt
        esp=disk.gpt@@1048576
    fi
else
    cp --sparse=always "$images/linux-boot.fat" "$esp"
fi
[[ -z $variant || $dual == 1 ]]
if (( split )); then
    (cd "$overlay" && sha256sum -c SHA256SUMS)
    mcopy -i "$images/linux-boot.fat" ::/EFI/BOOT/BOOTAA64.EFI exported-loader.efi
    if (( dual )); then
        cp --sparse=always "$images/linux-boot.fat" internal.fat
        mcopy -s -i internal.fat "$overlay/EFI/$payload_dir" ::/EFI/
        mcopy -i internal.fat "$overlay"/loader/entries/*.conf ::/loader/entries/
    else
        truncate -s 1G internal.fat
        mkfs.fat -S 4096 -s 1 -F 32 -i 10ACCE55 internal.fat
        mcopy -s -i internal.fat "$overlay/EFI" "$overlay/loader" ::/
        mmd -i internal.fat ::/EFI/BOOT
        mcopy -i internal.fat exported-loader.efi ::/EFI/BOOT/BOOTAA64.EFI
        printf 'default y700-test.conf\ntimeout 0\n' > selected-loader.conf
        mcopy -o -i internal.fat selected-loader.conf ::/loader/loader.conf
    fi
    mtype -i internal.fat ::/EFI/BOOT/BOOTAA64.EFI | cmp - exported-loader.efi
    entry=$overlay/loader/entries/$selected
    kernel=kernel.efi
    if [[ -n $variant ]]; then kernel=kernel-120.efi; fi
    grep -Fxq "devicetree /EFI/$payload_dir/board.dtb" "$entry"
    grep -Fxq "linux /EFI/$payload_dir/$kernel" "$entry"
    grep -Fxq "initrd /EFI/$payload_dir/initrd" "$entry"
    for payload in "$kernel" board.dtb; do
        mtype -i "$card/y700-test-card.img@@1048576" "::/EFI/debian/$payload" | cmp - "$overlay/EFI/$payload_dir/$payload"
    done
    for payload in "$kernel" initrd; do
        mtype -i internal.fat "::/EFI/$payload_dir/$payload" | cmp - "$overlay/EFI/$payload_dir/$payload"
    done
    sha256sum exported-loader.efi "$overlay/EFI/$payload_dir/$kernel" "$overlay/EFI/$payload_dir/initrd" "$entry" | tee trial-core.sha256
    cat > probe.service <<'UNIT'
[Unit]
Description=Verify the split EFI boot in QEMU
RequiresMountsFor=/boot
SuccessAction=poweroff
FailureAction=poweroff

[Service]
Type=oneshot
TimeoutStartSec=130
StandardOutput=tty
StandardError=tty
TTYPath=/dev/ttyAMA0
ExecStart=/bin/sh -c 'mkdir /run/y700-image-vm && mount -o ro /dev/disk/by-partlabel/linux-boot /run/y700-image-vm && exec /bin/sh /run/y700-image-vm/probe.sh'
UNIT
    qa_options="$qa_options systemd.unit=y700-image-vm.service systemd.set_credential_binary=systemd.extra-unit.y700-image-vm.service:$(base64 -w0 probe.service)"
    cp -- "$entry" pending.conf
    esp=internal.fat
    entry_name=$selected
else
    mcopy -i "$esp" ::/loader/entries/debian.conf pending.conf
    qa_options="$qa_options systemd.unit=kernel-command-line.target systemd.run=/boot/probe.sh systemd.run_success_action=poweroff systemd.run_failure_action=poweroff"
    entry_name=debian.conf
    payload_dir=debian
fi
tr -d '\r' < pending.conf > exported.conf
test "$(grep -c '^options ' exported.conf)" = 1
sed -n 's/^options //p' exported.conf > exported-options
if [[ $fbdev == 0 ]]; then grep -Eq '(^| )drm_kms_helper\.fbdev_emulation=0( |$)' exported-options; fi
if [[ "$sector" = 512 ]]; then
    grep -Eq '(^| )root=PARTLABEL=y700-test-root( |$)' exported-options
    grep -Eq '(^| )y700\.media=sd( |$)' exported-options
fi
# Preserve all shipped options, including a trial-specific rdinit. Only the
# disposable ESP receives the virtual board DT and observer parameters.
sed "/^options /s|$| $qa_options|" exported.conf > trial.conf
mcopy -o -i "$esp" trial.conf "::/loader/entries/$entry_name"
mcopy -o -i "$esp" "$board/efi/vm/board.dtb" "::/EFI/$payload_dir/board.dtb"
mcopy -i "$esp" exported-options ::/exported-options
{
    echo '#!/bin/sh'
    echo 'exec >/dev/ttyAMA0 2>&1'
    echo 'set -eu'
    sed -n '/^image_id=/p; /^root_uuid=/p' "$images/identity.txt"
    printf 'package_count=%s\npackage_digest=%s\n' "$package_count" "$package_digest"
    printf 'kernel_notes_sha256=%s\n' "$notes_digest"
    printf 'fbdev=%s\n' "$fbdev"
    echo "split=$split"
    echo "dual=$dual"
    echo "expected_entry=$selected"
    echo "esp_label=$label"
    echo "logical_sector=$sector"
    cat <<'PROBE'
test -d /sys/firmware/efi
test "$(cat /proc/1/comm)" = systemd
test "$(uname -r)" = 7.3.4-asphalt-prc
if [ -n "$kernel_notes_sha256" ]; then
    printf '%s  /sys/kernel/notes\n' "$kernel_notes_sha256" | sha256sum -c
fi
if [ "$fbdev" = 0 ]; then
    test "$(cat /sys/module/drm_kms_helper/parameters/fbdev_emulation)" = N
    test ! -c /dev/fb0
    test -s /var/lib/y700/build/firstboot-drm.lock.json
    echo 'Y700_KMS_BOOT framebuffer_emulation=off fb0=absent'
fi
rootdev=$(findmnt -nro SOURCE /)
bootdev=$(findmnt -nro SOURCE /boot)
test "$bootdev" = "$(readlink -f "/dev/disk/by-partlabel/$esp_label")"
test "${rootdev%2}" = "${bootdev%1}"
test "$(findmnt -nro FSTYPE /)" = ext4
test "$(findmnt -nro UUID /)" = "$root_uuid"
test "$(cat /etc/y700/image-id)" = "$image_id"
test "$(findmnt -nro FSTYPE /boot)" = vfat
parent=$(lsblk -no PKNAME "$rootdev")
test "$(cat "/sys/class/block/$parent/queue/logical_block_size")" = "$logical_sector"
test -s /boot/EFI/BOOT/BOOTAA64.EFI
if [ "$split" = 1 ]; then
    test "$rootdev" = "$(readlink -f /dev/disk/by-partlabel/y700-test-root)"
    internal=$(lsblk -no PKNAME /dev/disk/by-partlabel/linux-boot)
    test "$parent" != "$internal"
    test "$(cat "/sys/class/block/$internal/queue/logical_block_size")" = 4096
    test "$(findmnt -nro OPTIONS /run/y700-image-vm | cut -d, -f1)" = ro
    efivars=/sys/firmware/efi/efivars
    if ! mountpoint -q "$efivars"; then mount -t efivarfs -o ro efivarfs "$efivars"; fi
    efi_value() { dd if="$efivars/$1-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f" bs=1 skip=4 status=none | tr -d '\000'; }
    entry=$(efi_value LoaderEntrySelected)
    test "$entry" = "$expected_entry"
    loaderpart=$(efi_value LoaderDevicePartUUID)
    test "$(printf '%s' "$loaderpart" | tr A-F a-f)" = "$(blkid -s PARTUUID -o value /dev/disk/by-partlabel/linux-boot)"
    echo "Y700_VM_EFI_ENTRY selected=$entry loader_esp=internal"
    if [ "$dual" = 1 ]; then
        test "$(blkid -s UUID -o value /dev/disk/by-partlabel/linux)" = "$root_uuid"
        test "$(blkid -s UUID -o value /dev/disk/by-partlabel/linux-boot)" = 171A-4ADB
        test "$(findmnt -nro UUID -M /boot)" = 12DC-1212
        grep -Fxq 'PARTLABEL=y700-test-root / ext4 defaults 0 1' /etc/fstab
        grep -Fxq IMAGE_VERSION=dev12.12 /etc/os-release
        echo 'Y700_VM_SD_1212 ufs_root_uuid_collision=1 sd_esp=12DC-1212 ufs_esp=171A-4ADB'
    fi
    options=/run/y700-image-vm/exported-options
    echo 'Y700_VM_SPLIT_LAYOUT root_and_boot_card=1 card_sector=512 internal_sector=4096 internal_observer_ro=1'
else
    options=/boot/exported-options
fi
IFS= read -r shipped < "$options"
case " $(cat /proc/cmdline) " in *" $shipped "*) ;; *) exit 1 ;; esac
echo 'Y700_VM_EXPORTED_OPTIONS preserved=1'
initial_program=$(printf '%s\n' "$shipped" | tr ' ' '\n' | sed -n 's/^rdinit=//p')
test -n "$initial_program"
dmesg | grep -F "Run $initial_program as init process"
test -z "$(dpkg --audit)"
records=$(dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' | sed -n 's/^installed\t//p' | LC_ALL=C sort)
test "$(printf '%s\n' "$records" | wc -l)" = "$package_count"
test "$(printf '%s\n' "$records" | sha256sum | cut -d' ' -f1)" = "$package_digest"
printf 'Y700_VM_INVENTORY count=%s digest=%s\n' "$package_count" "$package_digest"
if grep -Fxq IMAGE_VERSION=dev12.11 /etc/os-release; then
    test "$package_count" = 1240
    test "$package_digest" = be0f181db24f72e2166b418e7b4e38999a672ffc89cb735a5afb7fd9a931941d
    test "$kernel_notes_sha256" = 35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6
    grep -Fxq IMAGE_ID=y700-prc-debian /etc/os-release
    printf '%s  %s\n' \
        411490734a965ca1405ca33e3b9a1fcb79a1fbad196d947cf3736cb66b1b41b1 /var/lib/y700/build/camera-autofocus.lock.json \
        3400560df16bd304fe76e7049f6ee9d5273e3e19bc23497ab95f6a7c83eef184 "/usr/lib/modules/$(uname -r)/kernel/drivers/rtc/rtc-pm8xxx.ko.zst" | sha256sum -c
    modprobe rtc-pm8xxx
    test -d /sys/module/rtc_pm8xxx
    printf 'Y700_VM_DEV1211 image=dev12.11 camera_receipt=verified rtc_driver=loaded\n'
fi
printf 'Y700_BOOT_PASS image=%s root=%s esp=%s kernel=%s pid1=%s packages=%s split=%s\n' "$image_id" "$rootdev" "$bootdev" "$(uname -r)" "$(cat /proc/1/comm)" "$package_count" "$split"
PROBE
} > probe.sh
mcopy -i "$esp" probe.sh ::/probe.sh
if (( split )); then
    if (( dual )); then
        truncate -s 7171M internal.gpt
        printf 'label: gpt\nunit: sectors\n\nstart=256, size=262144, type=uefi, name=linux-boot\nstart=262400, size=1572864, type=linux, name=linux\n' | sfdisk --sector-size 4096 internal.gpt
        dd if="$images/root.ext4" of=internal.gpt bs=1M seek=1025 conv=sparse,notrunc status=none
    else
        truncate -s 1027M internal.gpt
        printf 'label: gpt\nunit: sectors\n\nstart=256, size=262144, type=uefi, name=linux-boot\n' | sfdisk --sector-size 4096 internal.gpt
    fi
    dd if=internal.fat of=internal.gpt bs=1M seek=1 conv=sparse,notrunc status=none
elif [[ "$sector" = 4096 ]]; then
    truncate -s 7171M disk.gpt
    printf 'label: gpt\nunit: sectors\n\nstart=256, size=262144, type=uefi, name=linux-boot\nstart=262400, size=1572864, type=linux, name=linux\n' | sfdisk --sector-size 4096 disk.gpt
    dd if=test-esp.fat of=disk.gpt bs=1M seek=1 conv=sparse,notrunc status=none
    dd if="$images/root.ext4" of=disk.gpt bs=1M seek=1025 conv=sparse,notrunc status=none
fi
cmp -n 6442450944 "$expected_root" disk.gpt 0 1074790400
"${UV_BIN:-uv}" run --no-project --python "${UV_PYTHON:-3.13}" python "$repo/tests/boot-efi-guest.py" \
    "$qemu" "$board/efi/qemu-uboot/u-boot.bin" "$vm" "$(sed -n 's/^image_id=//p' "$images/identity.txt")" "$label" "$sector" "$split" "$package_count" "$selected"
if (( split )); then
    (cd "$card" && sha256sum -c SHA256SUMS)
    (cd "$overlay" && sha256sum -c SHA256SUMS)
fi
