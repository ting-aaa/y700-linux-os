#!/usr/bin/env bash
# Read-only preflight on the working TB320FC_PRC UFS install for the dev12.5 trial.
set -euo pipefail
export LC_ALL=C
fail() { echo "Preflight failed: $*" >&2; exit 1; }
entry=y700-test
marker=SD_TRIAL_PREFLIGHT_PASS
payload_bytes=51170438
if [[ ${1:-} == --file-trial && $# == 2 && $2 =~ ^[1-9][0-9]{0,8}$ ]]; then
    entry=y700-file
    marker=FILE_TRIAL_PREFLIGHT_PASS
    payload_bytes=$2
elif (( $# )); then
    fail 'expected no arguments for microSD or --file-trial SUPPLEMENT_BYTES'
fi
[[ $(tr -d '\0' </proc/device-tree/region_country) == PRC ]]
tr '\0' '\n' </proc/device-tree/compatible | grep -Fxq lenovo,asphalt || fail 'unexpected board'
root=$(findmnt -nro SOURCE /)
esp=$(findmnt -nro SOURCE /boot)
parent=$(lsblk -dnro PKNAME "$root")
[[ -n $parent && $parent == "$(lsblk -dnro PKNAME "$esp")" ]] || fail 'root and ESP parents differ'
[[ $(readlink -f "/sys/class/block/$parent") == */1d84000.ufshc/* ]] || fail 'not on internal UFS'
[[ $(findmnt -nro FSTYPE /) == ext4 && $(findmnt -nro FSTYPE /boot) == vfat ]]
[[ $(findmnt -nro UUID /) != 171a4adb-916b-4763-9e6f-722b4a99988f && $(findmnt -nro UUID /boot) != 171A-4ADB ]] || fail 'UUID collision with trial media'
[[ -r /boot/loader/entries/debian.conf && ! -e /boot/EFI/$entry && ! -e /boot/loader/entries/$entry.conf ]] || fail 'missing baseline or existing trial paths'
if [[ $entry == y700-file ]]; then
    [[ $(findmnt -nro UUID /) == ef306764-2315-4235-8796-69e2c9b61946 ]] || fail 'unexpected backing filesystem'
    [[ $(cat /etc/y700/image-id) == asphalt-prc-debian13-xfce-7.3.4-v1 ]] || fail 'unexpected backing system'
    [[ -c /dev/loop-control && -d /sys/module/loop ]] || fail 'loop devices unavailable'
    private=/var/lib/y700-trial
    [[ ! -L $private && ( ! -e $private || ( -d $private && $(stat -c '%u:%g:%a' "$private") == 0:0:700 ) ) ]] || fail 'unexpected staging directory'
    [[ ! -e $private/dev12.5 && ! -L $private/dev12.5 ]] || fail 'trial data already exists'
    free_root=$(df -B1 --output=avail / | tail -n 1)
    (( free_root > 7516192768 )) || fail 'insufficient space for both allocated images'
    printf 'backing_free_bytes=%d file_images_bytes=7516192768\n' "$free_root"
fi
default=$(awk 'tolower($1) == "default" {print $2}' /boot/loader/loader.conf)
[[ $default == debian.conf ]] || fail 'default must identify the working internal Debian entry'
timeout=$(awk 'tolower($1) == "timeout" {print $2}' /boot/loader/loader.conf)
[[ $timeout =~ ^[1-9][0-9]*$ ]] || fail 'no timed menu on the baseline'
vars=/sys/firmware/efi/efivars
guid=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
[[ $(findmnt -nro FSTYPE -T "$vars") == efivarfs ]] || fail 'EFI boot selection cannot be inspected'
read_var() { cat "$vars/$1-$guid" | tail -c +5 | iconv -f UTF-16LE -t UTF-8 | tr -d '\0'; }
[[ $(read_var LoaderEntrySelected) == "$default" ]] || fail 'booted entry differs from configured return entry'
if [[ -f $vars/LoaderEntryDefault-$guid ]]; then
    [[ $(read_var LoaderEntryDefault) == "$default" ]] || fail 'persistent EFI default overrides the return entry'
fi
[[ ! -e $vars/LoaderEntryOneShot-$guid ]] || fail 'another one-time entry is pending'
for var in LoaderConfigTimeout LoaderConfigTimeoutOneShot; do
    if [[ -f $vars/$var-$guid ]]; then
        [[ $(read_var "$var") =~ ^[1-9][0-9]*$ ]] || fail 'EFI timeout override does not provide a timed menu'
    fi
done
# Allow for four files' allocation rounding and new directories on FAT.
cluster=$(stat -f -c %S /boot)
required=$((payload_bytes + 8 * cluster))
available=$(df -B1 --output=avail /boot | tail -n 1)
(( available >= required )) || fail 'insufficient free space for the supplement'
cd /boot
sha256sum EFI/BOOT/BOOTAA64.EFI EFI/debian/{kernel.efi,initrd,board.dtb} loader/loader.conf loader/entries/debian.conf
sha256sum /sys/kernel/notes
printf '%s root=%s esp=%s default=%s menu_seconds=%s free_bytes=%d candidate_uuids=distinct trial_paths=free\n' "$marker" "$root" "$esp" "$default" "$timeout" "$available"
