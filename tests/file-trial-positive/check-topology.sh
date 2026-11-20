#!/usr/bin/env bash
set -euo pipefail
grep -qw y700.file_probe=1 /proc/cmdline
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
base=/run/initramfs/backing
trial=$base/var/lib/y700-trial/dev12.5
[[ $(findmnt -nro SOURCE,FSTYPE "$base") == '/dev/vda2 ext4' ]]
[[ $(findmnt -nro UUID "$base") == ef306764-2315-4235-8796-69e2c9b61946 ]]
[[ $(cat "$base/etc/y700/image-id") == asphalt-prc-debian13-xfce-7.3.4-v1 ]]
[[ $(cat /sys/class/block/vda/queue/logical_block_size) == 4096 ]]
[[ $(findmnt -nro SOURCE,FSTYPE /run/y700-file-qa) == '/dev/vda1 vfat' ]]
[[ $(findmnt -nro OPTIONS /run/y700-file-qa | cut -d, -f1) == ro ]]
[[ $(stat -c '%u:%g:%a' "$trial/..") == 0:0:700 ]]
[[ $(stat -c '%u:%g:%a' "$trial") == 0:0:700 ]]
outerdev=$(lsblk -dnro MAJ:MIN /dev/vda2)
loop_for() {
    local target=$1 fstype=$2 image=$3 loop
    loop=$(findmnt -nro SOURCE "$target")
    [[ $loop =~ ^/dev/loop[0-9]+$ && $(findmnt -nro FSTYPE "$target") == "$fstype" ]]
    [[ $(findmnt -nro OPTIONS "$target" | cut -d, -f1) == rw ]]
    [[ $(stat -c '%u:%g:%a:%h' "$image") == 0:0:600:1 ]]
    [[ $(losetup -n -O BACK-INO "$loop") == "$(stat -c %i "$image")" ]]
    [[ $(losetup -n -O BACK-MAJ:MIN "$loop") == "$outerdev" ]]
    [[ $(losetup -n -O OFFSET "$loop") == 0 ]]
    printf '%s\n' "$loop"
}
rootdev=$(loop_for / ext4 "$trial/root.ext4")
bootdev=$(loop_for /boot vfat "$trial/linux-boot.fat")
[[ $rootdev != "$bootdev" && $(findmnt -nro UUID /boot) == 171A-4ADB ]]

efivars=/sys/firmware/efi/efivars
if ! mountpoint -q "$efivars"; then mount -t efivarfs -o ro efivarfs "$efivars"; fi
efi_value() { dd if="$efivars/$1-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f" bs=1 skip=4 status=none | tr -d '\000'; }
[[ $(efi_value LoaderEntrySelected) == y700-file.conf ]]
[[ $(efi_value LoaderDevicePartUUID | tr A-F a-f) == "$(blkid -s PARTUUID -o value /dev/vda1)" ]]
IFS= read -r options < /run/y700-file-qa/exported-options
case " $(cat /proc/cmdline) " in *" $options "*) ;; *) exit 1 ;; esac
dmesg | grep -F 'Run /y700-file-trial-init as init process'
echo 'FILE_TRIAL_EFI entry=y700-file.conf firmware_disk=/dev/vda1 sector=4096 options_preserved=1'
printf 'FILE_TRIAL_LOOPS root=%s boot=%s parent=/dev/vda2 root_inode=verified esp_inode=verified writable=1\n' "$rootdev" "$bootdev"
