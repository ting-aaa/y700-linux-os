#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit
checker_pid=$BASHPID
fail() {
    printf 'RAM_TRIAL_CHECK_FAIL line=%s\n' "$1"
    printf 'RAM_TRIAL_BLOCK_NAMES'; printf ' %s' /sys/class/block/*; printf '\n'
    for mount in / /boot /run/y700-ram/carrier /run/y700-ram/lower /run/y700-ram/changes; do
        findmnt -nro TARGET,SOURCE,FSTYPE,MAJ:MIN,UUID,OPTIONS --mountpoint "$mount" || :
    done
    losetup -ln -O NAME,RO,BACK-FILE,BACK-INO,BACK-MAJ:MIN || :
}
trap 'if [[ $BASHPID == "$checker_pid" ]]; then fail "$LINENO"; fi' ERR
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
grep -qw y700.ram_probe=1 /proc/cmdline
grep -qw y700.media=ram /proc/cmdline
test "$(cat /proc/1/comm)" = systemd
base=/run/y700-ram
if test -e /proc/device-tree/chosen/linux,booted-from-kexec; then
    echo RAM_TRIAL_BOOT_ORIGIN=kexec
else
    echo RAM_TRIAL_BOOT_ORIGIN=direct
fi
hex() { od -An -tx1 "$1" | tr -d ' \n'; }
start=$(hex /proc/device-tree/chosen/linux,initrd-start)
end=$(hex /proc/device-tree/chosen/linux,initrd-end)
[[ $start =~ ^[0-9a-f]{8,16}$ && $end =~ ^[0-9a-f]{8,16}$ ]]
printf 'RAM_TRIAL_PLACEMENT initrd_start=0x%s initrd_end=0x%s\n' "$start" "$end"
awk '/^(MemTotal|MemFree|MemAvailable|Shmem):/ {gsub(":", "", $1); printf "RAM_TRIAL_MEMORY name=%s kib=%s\n", $1, $2}' /proc/meminfo

swap=0
while read -r device _; do
    [[ $device != Filename ]] || continue
    [[ $device =~ ^/dev/zram[0-9]+$ ]]
    swap=$((swap + 1))
done < /proc/swaps
printf 'RAM_TRIAL_SWAP zram=%d disk_backed=0\n' "$swap"

for device in /sys/class/block/*; do
    [[ ${device##*/} =~ ^(loop|ram|zram)[0-9]+$ ]]
done
if findmnt -n --mountpoint /boot; then exit 1; fi
test "$(findmnt -nro FSTYPE /)" = overlay
opts=,$(findmnt -nro OPTIONS /),
for option in rw "lowerdir=$base/lower" "upperdir=$base/changes/upper" "workdir=$base/changes/work"; do
    [[ $opts == *",$option,"* ]]
done
test "$(findmnt -nro FSTYPE --mountpoint "$base/changes")" = tmpfs

ro_loop() {
    local target=$1 fstype=$2 loop
    loop=$(findmnt -nro SOURCE --mountpoint "$target")
    [[ $loop =~ ^/dev/loop[0-9]+$ ]]
    test "$(findmnt -nro FSTYPE --mountpoint "$target")" = "$fstype"
    [[ ,$(findmnt -nro OPTIONS --mountpoint "$target"), == *,ro,* ]]
    test "$(losetup -ln --raw -O RO "$loop")" = 1
    printf '%s\n' "$loop"
}
carrier=$(ro_loop "$base/carrier" squashfs)
lower=$(ro_loop "$base/lower" ext4)
test "$carrier" != "$lower"
back=$(losetup -n -O BACK-FILE "$carrier")
[[ $back == */y700-root.squashfs || $back == */y700-root.squashfs\ \(deleted\) ]]
[[ $(losetup -ln --raw -O BACK-MAJ:MIN "$carrier") =~ ^0:[0-9]+$ ]]
test "$(losetup -ln --raw -O BACK-INO "$lower")" = "$(stat -c %i "$base/carrier/root.ext4")"
test "$(losetup -ln --raw -O BACK-MAJ:MIN "$lower")" = "$(findmnt -nro MAJ:MIN --mountpoint "$base/carrier")"
test "$(findmnt -nro UUID --mountpoint "$base/lower")" = 171a4adb-916b-4763-9e6f-722b4a99988f
[[ ,$(findmnt -nro OPTIONS --mountpoint "$base/lower"), == *,norecovery,* ]]

file=/etc/y700/.ram-qa-write
test ! -e "$file"
printf 'synthetic ram write\n' > "$file"
cmp "$file" "$base/changes/upper$file"
test ! -e "$base/lower$file"
rm -- "$file"
echo 'RAM_TRIAL_TOPOLOGY root=overlay carrier=squashfs_ro lower=ext4_ro upper=tmpfs external_disks=0 boot_mount=0 write_confined=1'
