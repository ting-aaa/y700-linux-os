#!/usr/bin/env bash
# Create one read-only boot medium for firmware and the first kernel.
set -euo pipefail
umask 077
[[ $# == 5 && ! -e $5 && ! -L $5 ]]
kernel=$(realpath -e "$1")
initrd=$(realpath -e "$2")
dtb=$(realpath -e "$3")
options=$4
image=$5
[[ -f $kernel && -f $initrd && -f $dtb && -f $Y700_BOOTAA64 && $options != *$'\n'* ]]
payload=$(( $(stat -c %s "$kernel") + $(stat -c %s "$initrd") ))
sectors=$(( (payload + 64 * 1024 * 1024 + 511) / 512 ))
truncate -s "$(( (sectors + 4096) * 512 ))" -- "$image"
printf 'label: gpt\nunit: sectors\n\nstart=2048,size=%s,type=uefi,name=BOOT\n' "$sectors" | sfdisk "$image" >/dev/null
fat=$image@@1048576
mformat -F -T "$sectors" -v RAMBOOT -i "$fat" ::
mmd -i "$fat" ::/EFI ::/EFI/BOOT ::/loader ::/loader/entries
mcopy -i "$fat" "$Y700_BOOTAA64" ::/EFI/BOOT/BOOTAA64.EFI
mcopy -i "$fat" "$kernel" ::/kernel.efi
mcopy -i "$fat" "$dtb" ::/virt.dtb
mcopy -i "$fat" "$initrd" ::/initrd
printf 'default baseline.conf\ntimeout 0\neditor no\n' | mcopy -i "$fat" - ::/loader/loader.conf
printf 'title Y700 baseline on QEMU\nlinux /kernel.efi\ninitrd /initrd\ndevicetree /virt.dtb\noptions %s\n' \
    "$options" | mcopy -i "$fat" - ::/loader/entries/baseline.conf
