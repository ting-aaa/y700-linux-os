#!/bin/bash
# Boot the production file initrd using a private copy of the sibling migration fixture.
# The source outer.ext4 must be the unmounted synthetic PC fixture from dev1211-migration.sh.
set -Eeuo pipefail
export LC_ALL=C
umask 077
[[ $# == 4 && $EUID == 0 ]] || { echo "Usage: sudo bash $0 IMAGES ENTRY MIGRATION_OUTER.EXT4 NEW_LOG_DIR" >&2; exit 2; }
if [[ ${Y700_NESTED_NS:-} != 1 ]]; then
    exec unshare --mount --propagation private env Y700_NESTED_NS=1 bash "$0" "$@"
fi
images=$(realpath -e "$1"); entry=$(realpath -e "$2"); source=$(realpath -e "$3")
logs=$(realpath -m "$4"); mkdir -m700 "$logs"
[[ -f $source && -z $(losetup -j "$source") && $(findmnt -nro PROPAGATION /) == private ]]
work=$(mktemp -d /var/tmp/y700-nested-test.XXXXXXXX)
cd "$work"
mkdir src disk
loop=
cleanup() {
    if mountpoint -q disk; then umount disk || return; fi
    if mountpoint -q src; then umount src || return; fi
    if [[ -n $loop ]]; then losetup -d "$loop" || return; fi
    cd /
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
trap 'echo "Nested boot fixture stopped at line $LINENO" >&2' ERR
printf '%s  %s\n' 0906c3c035c716f7c180c47e04a21de84bf2310a48d085c197c04b3b3f439232 "$images/SHA256SUMS" \
    d7d617d453585e69eb04a279f7c3839a7edece65bd9a3887e1a1b7cdaba6a362 "$entry/SHA256SUMS" | sha256sum --strict -c -
(cd "$images"; sha256sum --strict -c SHA256SUMS)
(cd "$entry"; sha256sum --strict -c SHA256SUMS)
store=var/lib/y700-trial
old=$store/dev12.10; new=$store/dev12.11
mount -o loop,ro,noload,nosuid,nodev,noexec "$source" src
grep -Fxq 'dev12.11 personal files verified, USB identity retained' "src/$new/installed.ok"
grep -Fxq 'generic_root_sha256=33ce23e8edac1d9c445c6b360a6355a189a151804352b032efe51320287d17a3' "src/$new/migration.log"
grep -Fxq 'generic_esp_sha256=92d47c14c4606d106ebad21ece8f5e23f244bd5aecea0c377bbe8966f8261b36' "src/$new/migration.log"
[[ $(blkid -p -s UUID -o value "src/$old/root.ext4") == 171a4adb-916b-4763-9e6f-722b4a99988f &&
   $(blkid -p -s UUID -o value "src/$old/linux-boot.fat") == 171A-4ADB ]]
[[ $(debugfs -R 'cat /etc/hostname' "src/$old/root.ext4" 2>/dev/null) == synthetic-machine ]]
(cd src; sha256sum "$old/root.ext4" "$old/linux-boot.fat") >"$work/old.before"
truncate -s 48G disk.raw
sfdisk --no-reread disk.raw >"$logs/gpt.log" <<'GPT'
label: gpt
unit: sectors

start=2048, type=linux, name=linux
GPT
sectors=$(sfdisk --json disk.raw | jq -er '.partitiontable.partitions[0] | select(.start == 2048 and .name == "linux") | .size')
open_disk() {
    loop=$(losetup --find --show --offset 1048576 --sizelimit "$((sectors*512))" "$work/disk.raw")
    [[ $(losetup -nO BACK-FILE "$loop") == "$work/disk.raw" ]]
}
close_disk() { umount disk; losetup -d "$loop"; loop=; }
open_disk
mkfs.ext4 -q -F -U ef306764-2315-4235-8796-69e2c9b61946 "$loop"
mount "$loop" disk
install -d -m755 disk/etc/y700
cp src/etc/y700/image-id disk/etc/y700/
install -d -m700 "disk/$store" "disk/$old" "disk/$new"
for f in "$old/root.ext4" "$old/linux-boot.fat" "$new/root.ext4" "$new/linux-boot.fat" "$new/installed.ok"; do
    [[ -f src/$f && ! -L src/$f ]]
    cp --sparse=always -- "src/$f" "disk/$f"
done
umount src
cat >disk/observer.sh <<'GUEST'
set -Eeuo pipefail
export LC_ALL=C
trap 'echo "NESTED_OBSERVER_FAIL line=$LINENO" >/dev/console; systemctl --no-block poweroff' ERR
[[ $(cat /proc/1/comm) == systemd && $(uname -m) == aarch64 && $(uname -r) == 7.3.4-asphalt-prc ]]
new=/run/initramfs/backing/var/lib/y700-trial/dev12.11
uuid=c0e447e4-82db-59ee-91d6-0e1ec9d5f45e
[[ $(findmnt -nro UUID -M /) == "$uuid" && $(findmnt -nro UUID -M /boot) == 31EC-3084 &&
   $(findmnt -nro SOURCE -M /run/initramfs/backing) == /dev/vda1 && $(cat /etc/y700/image-id) == "y700-prc-$uuid" ]]
for pair in /:root.ext4 /boot:linux-boot.fat; do
    dev=$(findmnt -nro SOURCE -M "${pair%:*}")
    [[ $dev =~ ^/dev/loop[0-9]+$ && $(losetup --raw -nO BACK-INO "$dev") == "$(stat -c %i "$new/${pair#*:}")" &&
       $(losetup --raw -nO BACK-MAJ:MIN "$dev") == "$(findmnt -nro MAJ:MIN -M /run/initramfs/backing)" &&
       $(losetup --raw -nO OFFSET "$dev") == 0 && ,$(findmnt -nro OPTIONS -M "${pair%:*}"), == *,rw,* ]]
done
[[ $(blockdev --getsize64 "$(findmnt -nro SOURCE -M /)") == 34359738368 &&
   $(blockdev --getsize64 "$(findmnt -nro SOURCE -M /boot)") == 1073741824 ]]
sha256sum --strict -c <<'SUMS'
35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6  /sys/kernel/notes
b103d0fcd65a08cadb592fbdc69c8c483a7727ef212c15e464208f5c30a1a625  /boot/EFI/debian/kernel.efi
53bc719146da49baff7b975c06942892278639909e48d0f998b894220c7d05b7  /boot/EFI/debian/board.dtb
411490734a965ca1405ca33e3b9a1fcb79a1fbad196d947cf3736cb66b1b41b1  /var/lib/y700/build/camera-autofocus.lock.json
SUMS
dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
    sed -n 's/^installed\t//p' | sort >/run/qa-tuples
[[ $(wc -l </run/qa-tuples) == 1240 && $(sha256sum /run/qa-tuples | cut -d' ' -f1) == be0f181db24f72e2166b418e7b4e38999a672ffc89cb735a5afb7fd9a931941d ]]
grep -Fxq IMAGE_VERSION=dev12.11 /etc/os-release
echo kept > /var/lib/y700/qa-nested
echo kept > /boot/qa-nested.txt
echo "NESTED_SYSTEMD_PASS release=dev12.11 root=$uuid,32GiB esp=31EC-3084,1GiB pair_inode_verified=1 inventory=1240" >/dev/console
systemctl --no-block poweroff
GUEST
unit=$(printf '%s\n' '[Unit]' 'DefaultDependencies=no' 'After=local-fs.target' 'Before=shutdown.target' 'Conflicts=shutdown.target' \
    '[Service]' 'Type=oneshot' 'ExecStart=/bin/bash /run/initramfs/backing/observer.sh' 'StandardOutput=journal+console' 'StandardError=journal+console' | base64 -w0)
args=$(sed -n 's/^options //p' "$entry/loader/entries/y700-file-12-11.conf")
base=$entry/EFI/y700-file-12-11
boot() {
    local -a flags=()
    if [[ -n ${QEMU_DATA:-} ]]; then flags=(-L "$QEMU_DATA"); fi
    timeout -k 5 210 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${flags[@]}" \
        -M virt,gic-version=3 -cpu max -smp 2 -m 1536 -nodefaults -no-user-config \
        -display none -no-reboot -monitor none -serial stdio -nic none \
        -drive file=disk.raw,format=raw,if=none,id=os -device virtio-blk-device,drive=os \
        -kernel "$base/kernel.efi" -initrd "$base/initrd" \
        -append "$args console=ttyAMA0 loglevel=5 udev.children_max=4 systemd.unit=basic.target systemd.wants=nested-qa.service systemd.set_credential_binary=systemd.extra-unit.nested-qa.service:$unit" \
        >"$logs/$1.log" 2>&1
}
# Substitute the previous FAT in the test copy alone; the production initrd should refuse it.
mv "disk/$new/linux-boot.fat" "disk/$new/correct-fat"
cp --sparse=always "disk/$old/linux-boot.fat" "disk/$new/linux-boot.fat"
close_disk
boot wrong-fat
grep -F 'y700-file-trial: unexpected inner FAT' "$logs/wrong-fat.log"
if grep -Fq 'verified persistent root=' "$logs/wrong-fat.log"; then exit 1; fi
open_disk; mount "$loop" disk
mv -f "disk/$new/correct-fat" "disk/$new/linux-boot.fat"
close_disk
boot nested
grep -F 'NESTED_SYSTEMD_PASS' "$logs/nested.log"
grep -F 'y700-file-trial: clean shutdown' "$logs/nested.log"
grep -Fi 'Power down' "$logs/nested.log"
open_disk
e2fsck -fn "$loop" >"$logs/outer-fsck.log" 2>&1
mount -o ro,noload "$loop" disk
(cd disk; sha256sum --strict -c "$work/old.before")
e2fsck -fn "disk/$new/root.ext4" >"$logs/inner-fsck.log" 2>&1
fsck.fat -n "disk/$new/linux-boot.fat" >"$logs/fat-fsck.log" 2>&1
[[ $(debugfs -R 'cat /var/lib/y700/qa-nested' "disk/$new/root.ext4" 2>/dev/null) == kept &&
   $(mtype -i "disk/$new/linux-boot.fat" ::/qa-nested.txt) == kept ]]
echo 'NESTED_1211_PASS old_files_sha_unchanged=2 persisted_markers=2 ext4_clean=2 fat_clean=1'
