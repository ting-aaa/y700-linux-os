#!/usr/bin/env bash
# Use a new FAT loop mount to exercise the same menu transaction as the tablet.
set -euo pipefail
if [[ ${1:-} != private ]]; then exec unshare --mount --propagation private bash "$0" private; fi
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
source "$repo/scripts/arm-installed-trial.sh"
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-installed-qa.XXXXXXXX")
esp=$work/esp; store=$work/store
mkdir "$esp" "$store"
trap 'for fs in "$esp" "$work/root"; do if mountpoint -q "$fs"; then umount "$fs" || exit 1; fi; done; rm -r --one-file-system -- "$work"' EXIT
truncate -s 64M "$work/disk.fat"
mkfs.fat -F 32 "$work/disk.fat" >/dev/null
mount -o loop,nodev,nosuid,noexec "$work/disk.fat" "$esp"
mkdir -p "$esp/loader/entries" "$esp/EFI/"{BOOT,debian,y700-file-12-10}
printf 'test boot loader\n' > "$esp/EFI/BOOT/BOOTAA64.EFI"
for name in debian y700-file-12-10; do
    for payload in kernel.efi initrd board.dtb; do echo "$name-$payload" > "$esp/EFI/$name/$payload"; done
    options=root=PARTLABEL=linux
    if [[ $name != debian ]]; then options='rdinit=/y700-file-trial-init y700.media=file y700.release=dev12.10 panic=15'; fi
    cat > "$esp/loader/entries/$name.conf" <<EOF
title $name
sort-key debian
linux /EFI/$name/kernel.efi
initrd /EFI/$name/initrd
devicetree /EFI/$name/board.dtb
options $options
EOF
done
echo -e 'default debian.conf\ntimeout 3' > "$esp/loader/loader.conf"
entry_sha=$(sha "$esp/loader/entries/$entry")
id=cold1; state=$store/control-$id
menu arm; menu arm
[[ $(cat "$esp/loader/loader.conf") == $'default y700-installed-cold1-*.conf\ntimeout 3' ]]
[[ -f $entries/$prefix-trial+1.conf && -f $entries/$prefix-base.conf ]]
if (menu promote) 2>/dev/null; then exit 1; fi
cp "$entries/$entry" "$work/entry"; echo altered >> "$entries/$entry"
if (menu restore) 2>/dev/null; then exit 1; fi
cp "$work/entry" "$entries/$entry"
# Model the filename transition performed by systemd-boot before Linux starts.
mv "$entries/$prefix-trial+1.conf" "$entries/$prefix-trial+0-1.conf"
if (menu arm) 2>/dev/null || (menu promote) 2>/dev/null; then exit 1; fi
printf '00000000-0000-4000-8000-000000000001\n' > "$state/confirmed"
original=$(cat "$conf"); echo -e 'default externally-edited.conf\ntimeout 3' > "$conf"
if (menu promote) 2>/dev/null; then exit 1; fi
printf '%s\n' "$original" > "$conf"
menu promote; menu promote
[[ $(cat "$conf") == $'default y700-file-12-10.conf\ntimeout 3' ]]
menu restore; menu restore
[[ $(cat "$conf") == $'default debian.conf\ntimeout 3' ]]
if (menu arm) 2>/dev/null || (menu promote) 2>/dev/null; then exit 1; fi
id=cold2; state=$store/control-$id
menu arm; menu restore
[[ $(cat "$conf") == $'default debian.conf\ntimeout 3' ]]
! compgen -G "$entries/y700-installed-*.conf" >/dev/null
timer_unit > "$work/$timer"; reboot_unit > "$work/${timer%.timer}.service"
systemd-analyze verify "$work/$timer" "$work/${timer%.timer}.service"
mkdir "$store/dev12.10" "$work/root"
img=$store/dev12.10/root.ext4
truncate -s 32G "$img"; mkfs.ext4 -q -U "$inner_uuid" -E lazy_itable_init=1 "$img"
mount -o loop "$img" "$work/root"
mkdir -p "$work/root/etc/systemd/system" "$work/root/var/lib/y700/build"
cp "$repo/config/video-player-update.lock.json" "$work/root/var/lib/y700/build/"
bash "$repo/scripts/arm-installed-trial.sh" prepare-candidate "$work/root"
bash "$repo/scripts/arm-installed-trial.sh" prepare-candidate "$work/root"
umount "$work/root"
check_prepared_image
echo 'INSTALLED_TRIAL_QA FAT=1 interrupted_edits_rejected=1 exhausted_cannot_rearm=1 confirmed_promote=1 original_restored=1 deadline_units=verified offline_candidate=32GiB'
