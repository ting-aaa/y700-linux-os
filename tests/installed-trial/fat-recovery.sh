#!/bin/bash
# Use the sealed 1 GiB FAT and the exact initramfs BusyBox in a PC-only chroot.
set -euo pipefail
if [[ ${Y700_FAT_TEST_NS:-0} != 1 ]]; then
    exec unshare --mount --propagation private --net --pid --fork env Y700_FAT_TEST_NS=1 bash "$0" "$@"
fi
[[ $# == 3 && $EUID == 0 ]] || { echo 'Usage: fat-recovery.sh SEALED_ROOT SEALED_FAT INITRAMFS_BUSYBOX' >&2; exit 2; }
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
raw=$(realpath -e "$1"); fat=$(realpath -e "$2"); bb=$(realpath -e "$3")
printf '%s  %s\n' 495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6 "$fat" \
    7d93682be37cf6ed46699f6fff546b80bf133cf8ec342c2d04bc23387f78bc34 "$bb" | sha256sum --quiet --strict -c -
work=$(mktemp -d /var/tmp/y700-fat-test.XXXXXXXX)
cleanup() {
    if mountpoint -q "$work/proc/meminfo"; then umount "$work/proc/meminfo" || return 1; fi
    if mountpoint -q "$work/proc"; then umount "$work/proc" || return 1; fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir -p "$work"/{bin,proc,sys,run,dev,var/lib/y700-trial/dev12.10}
image=$work/var/lib/y700-trial/dev12.10/linux-boot.fat
cp --sparse=always --reflink=auto "$fat" "$image"; chmod 600 "$image"
install -m755 "$bb" "$work/bin/busybox"
install -m644 "$repo/src/boot/file-recovery-fat" "$work/helper"
mount -t proc -o ro,nosuid,nodev,noexec proc "$work/proc"
mknod -m666 "$work/dev/null" c 1 3
bash "$repo/scripts/pack-recovery-fat-tools.sh" "$raw" "$work"
chroot "$work" /bin/busybox --install -s /bin
cat > "$work/probe" <<'PROBE'
#!/bin/sh
set -eu
export PATH=/bin
images=/var/lib/y700-trial/dev12.10
hex() { dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | hexdump -ve '1/1 "%02x"'; }
private_image() { [ ! -L "$1" ] && [ -f "$1" ] && [ "$(stat -c '%u:%g:%a:%h:%s' "$1")" = "0:0:600:1:$2" ]; }
fail() { echo "FAIL: $*" >&2; exit 1; }
. /helper
recover_boot_fat "$images/linux-boot.fat" "$1"
[ "$fat_access" = "$2" ]
PROBE
probe() { chroot "$work" /bin/busybox sh /probe "$@"; }
snapshot() { sha256sum "$image" | cut -c1-64; }
write_bytes() { printf '%b' "$2" | dd of="$image" bs=1 seek="$1" conv=notrunc,fsync status=none; }
original=$(snapshot)
probe 0 rw
probe 1 rw
[[ $(snapshot) == "$original" ]]
write_bytes 65 '\001'
write_bytes 4584 '\310\233\003\000'
probe 1 rw
[[ $(snapshot) == "$original" ]]
echo 'FAT_QA clean_both=pass dirty_and_stale_fsinfo=pass full_original_sha_restored=1'
write_bytes 65 '\003'
changed=$(snapshot); probe 1 ro; [[ $(snapshot) == "$changed" ]]
write_bytes 65 '\001'
printf 'MemAvailable: 1048576 kB\n' > "$work/meminfo"
mount --bind "$work/meminfo" "$work/proc/meminfo"
changed=$(snapshot); probe 1 ro; [[ $(snapshot) == "$changed" ]]
umount "$work/proc/meminfo"
write_bytes 65 '\000'
echo 'FAT_QA unknown_flags=read-only insufficient_ram=read-only originals_unchanged=1'
write_bytes $((6*4096+67)) '\000'
changed=$(snapshot); probe 1 ro; [[ $(snapshot) == "$changed" ]]
write_bytes 65 '\001'
changed=$(snapshot); probe 1 ro; [[ $(snapshot) == "$changed" ]]
write_bytes $((6*4096+67)) '\333'
# Mark the final free cluster as allocated in both FATs. Automatic repair would
# change data beyond the allowed count/state pair, even if its new tree is valid.
for start in 131072 1179648; do
    pos=$((start + 261601*4))
    [[ $(od -An -tu4 -j "$pos" -N4 "$image") -eq 0 ]]
    write_bytes "$pos" '\377\377\377\017'
done
changed=$(snapshot); probe 1 ro; [[ $(snapshot) == "$changed" ]]
echo 'FAT_QA ignored_backup_warning=read-only lost_cluster=read-only corrupt_original_unchanged=1'
