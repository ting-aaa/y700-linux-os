#!/bin/bash
# Boot the released file initrd on a private GPT disk on a Linux PC.
set -euo pipefail
umask 077
[[ $# == 4 && $EUID == 0 ]] || { echo 'Usage: file-trial-edition.sh DEV1210_IMAGES DEV129_ROOT ENTRY NEW_LOG_DIRECTORY' >&2; exit 2; }
if [[ ${Y700_EDITION_PRIVATE:-0} != 1 ]]; then
    exec unshare --mount --propagation private env Y700_EDITION_PRIVATE=1 bash "$0" "$@"
fi
imgs=$(realpath -e "$1")
old=$(realpath -e "$2")
entry=$(realpath -e "$3")
logs=$(realpath -m "$4")
mkdir -m700 "$logs"
work=$(mktemp -d /var/tmp/y700-file-edition-test.XXXXXXXX)
cd "$work"
mkdir m
loop=
cleanup() {
    if mountpoint -q "$work/m"; then umount "$work/m"; fi
    if [[ -n $loop ]]; then losetup -d "$loop"; fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
base=EFI/y700-file-12-10
menu=loader/entries/y700-file-12-10.conf
(cd "$entry"; sha256sum --strict -c SHA256SUMS)
sha256sum --strict -c <<HASH
18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd  $imgs/root.ext4
495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6  $imgs/linux-boot.fat
e40d2b7b297913c7200d2238f8f79d5a28926b983866cf09ca61f3dcbd8a0ddb  $old
HASH
[[ $(debugfs -R 'cat /var/lib/y700/build/video-player.lock.json' "$old" 2>/dev/null | jq -r .edition) == dev12.9 ]]
args=$(sed -n 's/^options //p' "$entry/$menu")
[[ $args == *' y700.release=dev12.10 '* ]]
truncate -s 38G disk.raw
sfdisk --no-reread disk.raw <<'GPT'
label: gpt
unit: sectors

start=2048, size=79687680, type=linux, name=linux
GPT
bind_outer() {
    loop=$(losetup --find --show --offset 1048576 --sizelimit $((79687680*512)) "$work/disk.raw")
    [[ $(losetup -n -O BACK-FILE "$loop") == "$work/disk.raw" ]]
}
unbind_outer() { losetup -d "$loop"; loop=; }
bind_outer
mkfs.ext4 -F -q -L y700-qa-only -U ef306764-2315-4235-8796-69e2c9b61946 "$loop"
mount "$loop" m
install -d -m755 m/etc/y700
echo asphalt-prc-debian13-xfce-7.3.4-v1 >m/etc/y700/image-id
dest=m/var/lib/y700-trial/dev12.10
install -d -m700 m/var/lib/y700-trial "$dest"
cp --sparse=always -- "$old" "$dest/root.ext4"
cp --sparse=always -- "$imgs/linux-boot.fat" "$dest/linux-boot.fat"
chmod 600 "$dest/"*
cat >m/qa.sh <<'GUEST'
set -eu
[[ $(cat /proc/1/comm) == systemd ]]
mountpoint -q /boot
root=$(findmnt -nro SOURCE /); esp=$(findmnt -nro SOURCE -M /boot)
[[ $root == /dev/loop* && $esp == /dev/loop* && $root != "$esp" ]]
for f in "$root/root.ext4" "$esp/linux-boot.fat"; do
    loop=${f%/*}; name=${f##*/}
    [[ $(cat "/sys/class/block/${loop##*/}/loop/backing_file") == */var/lib/y700-trial/dev12.10/"$name" ]]
done
[[ $(blockdev --getsize64 "$root") == 34359738368 ]]
[[ $(findmnt -nro SOURCE -M /run/initramfs/backing) == /dev/vda1 ]]
[[ $(sha256sum /var/lib/y700/build/video-player-update.lock.json | cut -d' ' -f1) == 39cd516bc47679ba3c7980dc3ed43a43c1bac80e40fba690c85d33d9794fd5eb ]]
echo kept > /var/lib/y700/qa-persistence
echo FILE_1210_PID1_PASS_root32G_esp1G > /dev/console
systemctl --no-block poweroff
GUEST
printf '[Unit]\nDescription=QA file root\nDefaultDependencies=no\nAfter=local-fs.target\nBefore=shutdown.target\nConflicts=shutdown.target\n[Service]\nType=oneshot\nExecStart=/bin/bash /run/initramfs/backing/qa.sh\nStandardOutput=journal+console\nStandardError=journal+console\n' >guest.service
unit=$(base64 -w0 guest.service)
umount m
unbind_outer
boot() {
    local label=$1
    local -a flags=()
    if [[ -n ${QEMU_DATA:-} ]]; then flags=(-L "$QEMU_DATA"); fi
    timeout -k 8 240 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${flags[@]}" \
        -M virt,gic-version=3 -cpu max -smp 2 -m 1250 -nodefaults -no-user-config \
        -display none -no-reboot -monitor none -serial stdio -nic none \
        -drive file=disk.raw,format=raw,if=none,id=inner -device virtio-blk-device,drive=inner \
        -kernel "$entry/$base/kernel.efi" -initrd "$entry/$base/initrd" \
        -append "$args console=ttyAMA0 loglevel=5 systemd.unit=basic.target systemd.wants=file-edition-qa.service systemd.set_credential_binary=systemd.extra-unit.file-edition-qa.service:$unit" \
        >"$logs/$label.log" 2>&1
}
boot wrong-release
grep -F 'unexpected inner release receipt; rebooting to default' "$logs/wrong-release.log"
if grep -Fq 'verified persistent root=' "$logs/wrong-release.log"; then exit 1; fi
bind_outer
e2fsck -fn "$loop" >"$logs/wrong-outer-fsck.log" 2>&1
mount "$loop" m
cmp -- "$dest/root.ext4" "$old"
cp --sparse=always -- "$imgs/root.ext4" "$dest/root.ext4"
chmod 600 "$dest/root.ext4"
e2fsck -fp "$dest/root.ext4" >"$logs/before-resize.log" 2>&1
truncate -s 32G "$dest/root.ext4"
resize2fs "$dest/root.ext4" >"$logs/resize.log" 2>&1
e2fsck -fn "$dest/root.ext4" >"$logs/resized-fsck.log" 2>&1
umount m
unbind_outer
boot correct-release
grep -F 'FILE_1210_PID1_PASS_root32G_esp1G' "$logs/correct-release.log"
grep -F 'y700-file-trial: clean shutdown' "$logs/correct-release.log"
bind_outer
e2fsck -fn "$loop" >"$logs/final-outer-fsck.log" 2>&1
mount -o ro,noload "$loop" m
e2fsck -fn "$dest/root.ext4" >"$logs/final-inner-fsck.log" 2>&1
[[ $(debugfs -R 'cat /var/lib/y700/qa-persistence' "$dest/root.ext4" 2>/dev/null) == kept ]]
fsck.fat -n "$dest/linux-boot.fat" >"$logs/final-fat-fsck.log" 2>&1
echo FILE_1210_EDITION_PASS_wrong_6G_refused_correct_32G_persisted_both_ext4_and_fat_clean
