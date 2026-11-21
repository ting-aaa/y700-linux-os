#!/usr/bin/env bash
# Exercise the guard actually present in the sealed initrd with a synthetic device tree.
set -euo pipefail
[[ $# == 1 && $EUID == 0 ]] || { echo 'Usage as root: check-storage-guard.sh DEV12.12_RAM_BUNDLE' >&2; exit 2; }
bundle=$(realpath -e -- "$1")
here=$(cd "$(dirname "$0")" && pwd)
(cd "$bundle"; sha256sum --strict -c SHA256SUMS)
work=$(mktemp -d)
trap 'rm -r --one-file-system -- "$work"' EXIT
# The pinned stock gzip member ends at the four-byte-aligned offset 11637348.
tail -c +11637349 "$bundle/initrd" | cpio --quiet -i --to-stdout y700-ram-trial-init > "$work/init"
sed -n '/^# Physical diagnostic policy$/,/^# End physical diagnostic policy$/p' "$work/init" > "$work/guard"
cmp "$here/../../src/boot/ram-trial-storage-check" "$work/guard"
[[ $(grep -c '^check_storage$' "$work/init") == 1 && $(grep -Fc 'reboot -f' "$work/init") == 0 ]]
mkdir -p "$work/bin" "$work/dev" "$work/sys/class/block"
install -m755 "${BUSYBOX_STATIC:-/usr/bin/busybox}" "$work/bin/busybox"
for app in sh tr grep; do ln -s busybox "$work/bin/$app"; done
tree=$work/proc/device-tree/soc@0
ufs=$tree/ufshc@1d84000
sd=$tree/mmc@8804000
mkdir -p "$ufs" "$sd"
run_guard() {
    chroot "$work" /bin/sh -ec 'PATH=/bin; compat=lenovo,asphalt; . /guard; poweroff() { [ "$1" = -f ] && exit 42; exit 43; }; check_storage'
}
reject() {
    local rc=0
    run_guard > "$work/result" || rc=$?
    [[ $rc == 42 ]] && grep -Fqx "y700-ram-trial: $1; powering off" "$work/dev/console"
}
for node in "$ufs" "$sd"; do printf 'disabled\0' > "$node/status"; done
[[ $(run_guard) == 'y700-ram-trial: physical UFS and SD hosts disabled' ]]
for node in "$ufs" "$sd"; do
    rm "$node/status"
    reject "storage host active: ${node##*/}"
    printf 'okay\0' > "$node/status"
    reject "storage host active: ${node##*/}"
    printf 'disabled\0' > "$node/status"
done
for dev in sda sda1 mmcblk0 mmcblk0p1; do
    mkdir "$work/sys/class/block/$dev"
    reject "physical storage enumerated: $dev"
    rmdir "$work/sys/class/block/$dev"
done
echo 'RAM_STORAGE_GUARD_PASS disabled=2 missing_rejected=2 enabled_rejected=2 enumerated_rejected=4'
