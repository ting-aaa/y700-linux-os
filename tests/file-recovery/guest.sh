#!/bin/bash
# Delivered through the private read-only observer drive on this QEMU regression.
set -euo pipefail
test "$(cat /proc/1/comm)" = systemd
tr '\000' '\n' < /proc/device-tree/compatible | grep -Fxq linux,dummy-virt
host=/run/initramfs/backing
test "$(findmnt -nro SOURCE -M "$host")" = "$(readlink -e /dev/disk/by-id/virtio-y700fixture-part1)"
[[ ,$(findmnt -nro OPTIONS -M "$host"), == *,rw,* ]]
for record in '/ root.ext4 ext4' '/boot linux-boot.fat vfat'; do
    read -r point file fstype <<<"$record"
    source=$(findmnt -nro SOURCE -M "$point")
    [[ $source =~ ^/dev/loop[0-9]+$ && $(findmnt -nro FSTYPE -M "$point") == "$fstype" ]]
    [[ $(cat "/sys/class/block/${source##*/}/loop/backing_file") == */var/lib/y700-trial/dev12.10/"$file" ]]
    state=$(findmnt -nro OPTIONS -M "$point" | cut -d, -f1)
    if [[ $point == / ]]; then [[ $state == rw ]]; else fat_mode=$state; fi
done
printf '%s  %s\n' 39cd516bc47679ba3c7980dc3ed43a43c1bac80e40fba690c85d33d9794fd5eb \
    /var/lib/y700/build/video-player-update.lock.json | sha256sum --strict --status -c -
actual_size=$(blockdev --getsize64 "$(findmnt -nro SOURCE -M /)")
case "$actual_size" in 6442450944|34359738368) ;; *) exit 1;; esac
if [[ -f "$host/expected-root-bytes" ]]; then test "$(cat "$host/expected-root-bytes")" = "$actual_size"; fi
echo "FILE_RECOVERY_TOPOLOGY root_bytes=$actual_size outer_sector_bytes=$(blockdev --getss "$(findmnt -nro SOURCE -M "$host")")" >/dev/console
root_marker=/var/lib/y700/qa-recovery-marker
fat_marker=/boot/qa-recovery-marker.txt
if grep -qw y700.recovery_test=cut /proc/cmdline; then
    [[ $fat_mode == rw ]]
    for target in "$root_marker" "$fat_marker"; do
        test ! -e "$target"
        cat "$host/expected-marker" > "$target"
        sync "$target" "${target%/*}"
    done
    echo 'FILE_RECOVERY_CUT_READY mount_rw=outer,root,esp marker_fsync=root,esp pid1=systemd' >/dev/console
    exec sleep infinity
fi
grep -qw y700.recovery_test=verify /proc/cmdline
cmp "$root_marker" "$host/expected-marker"
cmp "$fat_marker" "$host/expected-marker"
[[ $fat_mode == rw || $fat_mode == ro ]]
echo "FILE_RECOVERY_BOOTED correct_release=1 pid1=systemd marker=root,esp esp_mode=$fat_mode" >/dev/console
systemctl --no-block poweroff
