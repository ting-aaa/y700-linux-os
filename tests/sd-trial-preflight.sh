#!/usr/bin/env bash
# Read-only preflight on the working TB320FC_PRC UFS install for the dev12.5 trial.
set -euo pipefail
export LC_ALL=C
fail() { echo "Preflight failed: $*" >&2; exit 1; }
[[ $(tr -d '\0' </proc/device-tree/region_country) == PRC ]]
tr '\0' '\n' </proc/device-tree/compatible | grep -Fxq lenovo,asphalt || fail 'unexpected board'
root=$(findmnt -nro SOURCE /)
esp=$(findmnt -nro SOURCE /boot)
parent=$(lsblk -dnro PKNAME "$root")
[[ -n $parent && $parent == "$(lsblk -dnro PKNAME "$esp")" ]] || fail 'root and ESP parents differ'
[[ $(readlink -f "/sys/class/block/$parent") == */1d84000.ufshc/* ]] || fail 'not on internal UFS'
[[ $(findmnt -nro FSTYPE /) == ext4 && $(findmnt -nro FSTYPE /boot) == vfat ]]
[[ $(findmnt -nro UUID /) != 171a4adb-916b-4763-9e6f-722b4a99988f && $(findmnt -nro UUID /boot) != 171A-4ADB ]] || fail 'UUID collision with trial media'
[[ -r /boot/loader/entries/debian.conf && ! -e /boot/EFI/y700-test && ! -e /boot/loader/entries/y700-test.conf ]] || fail 'missing baseline or existing trial paths'
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
# The four-file supplement has 51,170,438 bytes. Allow for allocation rounding and new directories.
cluster=$(stat -f -c %S /boot)
required=$((51170438 + 8 * cluster))
available=$(df -B1 --output=avail /boot | tail -n 1)
(( available >= required )) || fail 'insufficient free space for the supplement'
cd /boot
sha256sum EFI/BOOT/BOOTAA64.EFI EFI/debian/{kernel.efi,initrd,board.dtb} loader/loader.conf loader/entries/debian.conf
sha256sum /sys/kernel/notes
printf 'SD_TRIAL_PREFLIGHT_PASS root=%s esp=%s default=%s menu_seconds=%s free_bytes=%d candidate_uuids=distinct trial_paths=free\n' "$root" "$esp" "$default" "$timeout" "$available"
