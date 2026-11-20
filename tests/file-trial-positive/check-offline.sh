#!/usr/bin/env bash
# Inspect the stopped guest's retained overlay without journal replay or repair.
set -euo pipefail
work=$(realpath -e "$1")
disk=$(realpath -e "$2")
[[ $(id -u) == 0 && $work =~ ^/var/tmp/y700-file-boot\.[a-zA-Z0-9]{8}$ && $disk == "$work/session.qcow2" ]]
mkdir "$work/readonly" "$work/offline-mount"
loop= nbd_pid= fuse_pid=
cleanup() {
    if mountpoint -q "$work/offline-mount"; then umount "$work/offline-mount"; fi
    if [[ -n $loop ]]; then losetup -d "$loop"; fi
    if mountpoint -q "$work/readonly"; then fusermount3 -u "$work/readonly"; fi
    if [[ -n $fuse_pid ]]; then kill "$fuse_pid" 2>/dev/null || :; wait "$fuse_pid" 2>/dev/null || :; fi
    if [[ -n $nbd_pid ]]; then kill "$nbd_pid" 2>/dev/null || :; wait "$nbd_pid" 2>/dev/null || :; fi
}
trap cleanup EXIT
trap 'exit 143' TERM
"${QEMU_NBD:-qemu-nbd}" --persistent --read-only --format=qcow2 --socket="$work/offline.sock" "$disk" &
nbd_pid=$!
for _ in {1..120}; do [[ ! -S $work/offline.sock ]] || break; sleep .05; done
test -S "$work/offline.sock"
"${NBDFUSE:-nbdfuse}" -r "$work/readonly/disk.raw" --unix "$work/offline.sock" &
fuse_pid=$!
for _ in {1..120}; do [[ ! -f $work/readonly/disk.raw ]] || break; sleep .05; done
test -f "$work/readonly/disk.raw"
loop=$(losetup --find --show --read-only --sector-size 4096 --offset 1074790400 --sizelimit 9663676416 -- "$work/readonly/disk.raw")
[[ $loop =~ ^/dev/loop[0-9]+$ ]]
[[ $(blockdev --getro "$loop") == 1 ]]
clean_ext4() {
    local label=$1 target=$2 header
    header=$(dumpe2fs -h "$target" 2>/dev/null)
    grep -Eq '^Filesystem state:[[:space:]]*clean$' <<<"$header"
    if grep -Eq '^Filesystem features:.*(^|[[:space:]])needs_recovery([[:space:]]|$)' <<<"$header"; then return 1; fi
    e2fsck -fn "$target"
    echo "FILE_TRIAL_EXT4_CLEAN filesystem=$label replay=0 repair=0"
}
export LC_ALL=C
clean_ext4 outer "$loop"
mount -o ro,noload,noexec,nodev,nosuid "$loop" "$work/offline-mount"
base=$work/offline-mount
[[ $(cat "$base/etc/y700/image-id") == asphalt-prc-debian13-xfce-7.3.4-v1 ]]
trial=$base/var/lib/y700-trial/dev12.5
clean_ext4 nested-root "$trial/root.ext4"
fat_report=$(fsck.fat -vn "$trial/linux-boot.fat")
printf '%s\n' "$fat_report"
if grep -Eiq 'dirty bit|not properly unmounted|would remake|^Leaving filesystem unchanged' <<<"$fat_report"; then exit 1; fi
echo 'FILE_TRIAL_FAT_CLEAN filesystem=nested-esp repair=0'
debugfs -R 'stat /etc/y700/user-configured' "$trial/root.ext4" 2>/dev/null | grep -q '^Inode: '
echo 'FILE_TRIAL_PERSISTED_MARKER enrollment=present offline=1'
