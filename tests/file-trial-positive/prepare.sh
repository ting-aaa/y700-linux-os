#!/usr/bin/env bash
# Build a fake internal baseline as a regular file on a Linux PC.
set -euo pipefail
umask 077
if [[ $# != 3 || $(id -u) != 0 ]]; then
    echo 'Usage: prepare.sh SEALED_DEV125_ROOT SEALED_DEV125_ESP NEW_PRIVATE_DIRECTORY (Linux root)' >&2
    exit 2
fi
root=$(realpath -e "$1")
esp=$(realpath -e "$2")
out=$(realpath -m "$3")
[[ -f $root && -f $esp && ! -e $out && ! -L $out ]]
mkdir -m700 -- "$out"
printf '%s  %s\n' \
    041fcf2e04b5d05edbfa3147f442a019d2f260f6544b9182087bf911ff8e55b6 "$root" \
    495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6 "$esp" > "$out/source.sha256"
sha256sum --strict -c "$out/source.sha256"
outer=$out/outer.ext4
truncate -s 9G "$outer"
mkfs.ext4 -F -q -b 4096 -m0 -L y700-test-base -U ef306764-2315-4235-8796-69e2c9b61946 "$outer"
mountpoint=$out/outer-mount
mkdir -m700 -- "$mountpoint"
loop=
cleanup() {
    if mountpoint -q "$mountpoint"; then umount -- "$mountpoint"; fi
    if [[ -n $loop ]]; then losetup --detach "$loop"; fi
}
trap cleanup EXIT
loop=$(losetup --find --show --sector-size 4096 -- "$outer")
[[ $loop =~ ^/dev/loop[0-9]+$ ]]
[[ $(losetup -n -O BACK-FILE -- "$loop") == "$outer" ]]
mount -t ext4 -o nodev,nosuid,noexec "$loop" "$mountpoint"
install -d -m755 "$mountpoint/etc/y700"
printf 'asphalt-prc-debian13-xfce-7.3.4-v1\n' > "$mountpoint/etc/y700/image-id"
trial=$mountpoint/var/lib/y700-trial
install -d -m700 "$trial" "$trial/dev12.5"
cp --sparse=always -- "$root" "$trial/dev12.5/root.ext4"
cp --sparse=always -- "$esp" "$trial/dev12.5/linux-boot.fat"
chmod 600 "$trial/dev12.5/root.ext4" "$trial/dev12.5/linux-boot.fat"
cmp -- "$root" "$trial/dev12.5/root.ext4"
cmp -- "$esp" "$trial/dev12.5/linux-boot.fat"
umount -- "$mountpoint"
losetup --detach "$loop"
loop=
rmdir -- "$mountpoint"
e2fsck -fn "$outer"
chmod 400 "$outer"
(cd "$out" && sha256sum outer.ext4 > outer.sha256)
sha256sum --strict -c "$out/source.sha256"
printf 'FILE_TRIAL_OUTER_READY path=%s logical_bytes=9663676416\n' "$outer"
