#!/bin/bash
set -euo pipefail
cd "$1"
[[ $(stat -c '%u:%a' .) == 0:700 && $(findmnt -nro FSTYPE -T .) == tmpfs ]]
printf '%s  initrd\n' "$3" | sha256sum --strict -c
source ./profiles.sh
ram_profile "$3"
[[ $(stat -c %s initrd) == "$initrd_bytes" ]]
# Both sealed archives use the same board initrd and aligned newc member offset.
# GNU dd is in coreutils on the board, including installations without cpio.
dd if=initrd of=carrier bs=1M iflag=skip_bytes,count_bytes skip=11641252 count="$carrier_bytes" status=none
printf '%s  carrier\n' "$carrier_sha" | sha256sum --strict -c
rm -- initrd
for ns in mnt net pid ipc; do readlink "/proc/self/ns/$ns" >"host-$ns"; done
snapshot() {
    cat /proc/sys/kernel/random/boot_id
    local seat
    seat=$(loginctl show-seat seat0 -p ActiveSession --value)
    [[ -n $seat ]]
    loginctl show-session "$seat" -p Id -p Active -p LockedHint
    systemctl show lightdm ssh NetworkManager bluetooth upower -p Id -p InvocationID
    if [[ -f /sys/class/backlight/ktz8866-backlight/brightness ]]; then cat /sys/class/backlight/ktz8866-backlight/brightness; fi
    findmnt -nro SOURCE,FSTYPE,OPTIONS /
    findmnt -nro SOURCE,FSTYPE,OPTIONS --mountpoint /boot || :
    cat /proc/swaps
    for p in /sys/class/remoteproc/remoteproc*; do
        if [[ -e $p/name && $(cat "$p/name") == *slpi* ]]; then cat "$p/state"; fi
    done
}
snapshot >before
rc=0
timeout --kill-after=5s 200s unshare --mount --propagation private --pid --fork --kill-child --ipc --net \
    bash "$1/namespace.sh" "$1" "$2" "$3" || rc=$?
snapshot >after
cmp before after
[[ -z $(losetup -j "$1/carrier") ]]
if losetup --list --noheadings --output BACK-FILE | grep -F "$1/"; then exit 1; fi
if grep -Fq "$1/" /proc/self/mountinfo; then exit 1; fi
echo 'RAM_USERSPACE original_boot_seat_services_mounts_swap_slpi=same leaked_mounts=0 leaked_loops=0'
exit "$rc"
