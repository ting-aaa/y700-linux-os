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
if [[ -n ${5:-} ]]; then card=$(realpath -e "$5"); fi
if [[ -n ${6:-} ]]; then overlay=$(realpath -e "$6"); fi
mkdir -m700 -- "$vm"
cd "$images"
sha256sum -c SHA256SUMS
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
media=
esp=test-esp.fat
if [[ -n "$card" ]]; then
    (cd "$card" && sha256sum -c SHA256SUMS)
    cp --sparse=always "$card/y700-test-card.img" disk.gpt
    esp=disk.gpt@@1048576
    sector=512
    label=y700-test-esp
    media='y700.media=sd'
else
    cp --sparse=always "$images/linux-boot.fat" "$esp"
fi
mcopy -i "$esp" ::/loader/entries/debian.conf debian.conf
# Keep the candidate kernel, initrd and root. Supply the virtual board DT,
# PL011 console, and a one-shot userspace verifier executed by systemd PID 1.
sed -i -E 's|(^options rdinit=/init root=PARTLABEL=[^ ]+).*|\1 rw console=ttyAMA0 loglevel=5 systemd.show_status=yes systemd.unit=kernel-command-line.target systemd.run=/boot/probe.sh systemd.run_success_action=poweroff systemd.run_failure_action=poweroff|' debian.conf
sed -i "/^options /s/$/ $media/" debian.conf
mcopy -o -i "$esp" debian.conf ::/loader/entries/debian.conf
mcopy -o -i "$esp" "$board/efi/vm/board.dtb" ::/EFI/debian/board.dtb
split=0
if [[ -n "$overlay" ]]; then
    test "$sector" = 512
    (cd "$overlay" && sha256sum -c SHA256SUMS)
    split=1
    # Stand in for the existing internal ESP. Its FAT ID must differ from the
    # card referenced by fstab. Only this disk can launch an EFI loader.
    truncate -s 1G internal.fat
    mkfs.fat -S 4096 -s 1 -F 32 -i 10ACCE55 internal.fat
    mcopy -s -i internal.fat "$overlay/EFI" "$overlay/loader" ::/
    mmd -i internal.fat ::/EFI/BOOT
    mcopy -i internal.fat "$images/esp/EFI/BOOT/BOOTAA64.EFI" ::/EFI/BOOT/
    grep -Fq 'devicetree /EFI/y700-test/board.dtb' "$overlay/loader/entries/y700-test.conf"
    grep -Fq 'linux /EFI/y700-test/kernel.efi' "$overlay/loader/entries/y700-test.conf"
    grep -Fq 'initrd /EFI/y700-test/initrd' "$overlay/loader/entries/y700-test.conf"
    sed '/^options /d' "$overlay/loader/entries/y700-test.conf" > trial.conf
    grep '^options ' debian.conf >> trial.conf
    mcopy -o -i internal.fat trial.conf ::/loader/entries/y700-test.conf
    mcopy -o -i internal.fat "$board/efi/vm/board.dtb" ::/EFI/y700-test/board.dtb
    mdel -i "$esp" ::/EFI/BOOT/BOOTAA64.EFI
    truncate -s 1027M internal.gpt
    printf 'label: gpt\nunit: sectors\n\nstart=256, size=262144, type=uefi, name=linux-boot\n' | sfdisk --sector-size 4096 internal.gpt
    dd if=internal.fat of=internal.gpt bs=1M seek=1 conv=sparse,notrunc status=none
fi
{
    echo '#!/bin/sh'
    echo 'exec >/dev/ttyAMA0 2>&1'
    echo 'set -eu'
    cat "$images/identity.txt"
    echo "split=$split"
    echo "esp_label=$label"
    cat <<'PROBE'
test -d /sys/firmware/efi
test "$(cat /proc/1/comm)" = systemd
test "$(uname -r)" = 7.3.4-asphalt-prc
rootdev=$(findmnt -nro SOURCE /)
bootdev=$(findmnt -nro SOURCE /boot)
test "$bootdev" = "$(readlink -f "/dev/disk/by-partlabel/$esp_label")"
test "${rootdev%2}" = "${bootdev%1}"
test "$(findmnt -nro FSTYPE /)" = ext4
test "$(findmnt -nro UUID /)" = "$root_uuid"
test "$(cat /etc/y700/image-id)" = "$image_id"
test "$(findmnt -nro FSTYPE /boot)" = vfat
if [ "$split" = 1 ]; then
    test ! -e /boot/EFI/BOOT/BOOTAA64.EFI
    test "$(lsblk -no PKNAME "$rootdev")" != "$(lsblk -no PKNAME /dev/disk/by-partlabel/linux-boot)"
else
    test -s /boot/EFI/BOOT/BOOTAA64.EFI
fi
test "$(dpkg-query -W -f='${Version}' y700-platform)" = '0.1.0~dev2'
test -z "$(dpkg --audit)"
test "$(dpkg-query -W -f='${db:Status-Status}\n' | grep -cx installed)" = 993
printf 'Y700_BOOT_PASS image=%s root=%s esp=%s kernel=%s pid1=%s packages=993 split=%s\n' "$image_id" "$rootdev" "$bootdev" "$(uname -r)" "$(cat /proc/1/comm)" "$split"
PROBE
} > probe.sh
mcopy -i "$esp" probe.sh ::/probe.sh
if [[ "$sector" = 4096 ]]; then
    truncate -s 7171M disk.gpt
    printf 'label: gpt\nunit: sectors\n\nstart=256, size=262144, type=uefi, name=linux-boot\nstart=262400, size=1572864, type=linux, name=linux\n' | sfdisk --sector-size 4096 disk.gpt
    dd if=test-esp.fat of=disk.gpt bs=1M seek=1 conv=sparse,notrunc status=none
    dd if="$images/root.ext4" of=disk.gpt bs=1M seek=1025 conv=sparse,notrunc status=none
fi
cmp -n 6442450944 "$images/root.ext4" disk.gpt 0 1074790400
"${UV_BIN:-uv}" run --no-project --python "${UV_PYTHON:-3.13}" python "$repo/tests/boot-efi-guest.py" \
    "$qemu" "$board/efi/qemu-uboot/u-boot.bin" "$vm" "$(sed -n 's/^image_id=//p' "$images/identity.txt")" "$label" "$sector" "$split"
