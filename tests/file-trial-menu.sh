#!/usr/bin/env bash
set -euo pipefail
[[ $EUID == 0 && $# == 2 ]] || { echo 'Usage (root): file-trial-menu.sh BASELINE_ESP_SOURCE_DIR VERIFIED_ENTRY_DIR' >&2; exit 2; }
if [[ ${Y700_MENU_PRIVATE:-0} != 1 ]]; then
    exec unshare --mount --propagation private env Y700_MENU_PRIVATE=1 bash "$0" "$@"
fi
baseline=$(realpath -e -- "$1")
entry=$(realpath -e -- "$2")
manage=$(realpath -e -- "$(dirname "$0")/../scripts/manage-file-trial-entry.sh")
work=$(mktemp -d /var/tmp/y700-file-menu.XXXXXXXX)
esp=$work/mounted
cleanup() {
    if mountpoint -q "$esp"; then umount "$esp"; fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir "$esp"
truncate -s 304M "$work/efi.fat"
mkfs.fat -F32 -S4096 -s1 "$work/efi.fat" >/dev/null
mount -o loop,nosuid,nodev "$work/efi.fat" "$esp"
cp -r -- "$baseline/EFI" "$baseline/loader" "$esp/"
inventory() { (cd "$esp" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }
inventory > "$work/before"
bash "$manage" add "$entry" "$esp"
bash "$manage" add "$entry" "$esp"
printf 'test sentinel' > "$esp/EFI/y700-file/unknown"
if bash "$manage" remove "$entry" "$esp"; then exit 1; fi
[[ -e $esp/loader/entries/y700-file.conf && -e $esp/EFI/y700-file/unknown ]]
rm -- "$esp/EFI/y700-file/unknown"
bash "$manage" remove "$entry" "$esp"
bash "$manage" remove "$entry" "$esp"
inventory | cmp - "$work/before"
umount "$esp"
fsck.fat -n "$work/efi.fat"
echo FILE_TRIAL_MENU_REGRESSION_PASS
