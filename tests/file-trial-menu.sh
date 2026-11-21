#!/usr/bin/env bash
set -euo pipefail
if [[ ${Y700_MENU_PRIVATE:-0} != 1 ]]; then
    exec unshare --mount --propagation private env Y700_MENU_PRIVATE=1 bash "$0" "$@"
fi
flags=()
serial=()
payload=y700-file
installed=
if [[ ${1:-} == --dev12.10 ]]; then
    shift
    flags=(--dev12.10)
    serial=(-i B6D4FA81)
    payload=y700-file-12-10
elif [[ ${1:-} == --dev12.10-recovery && $# == 4 ]]; then
    installed=$(realpath -e -- "$2")
    shift 2
    flags=(--dev12.10-recovery)
    serial=(-i B6D4FA81)
    payload=y700-recovery-12-10
fi
[[ $EUID == 0 && $# == 2 ]] || { echo 'Usage (root): file-trial-menu.sh [--dev12.10|--dev12.10-recovery INSTALLED_ENTRY_DIR] BASELINE_ESP_SOURCE_DIR VERIFIED_ENTRY_DIR' >&2; exit 2; }
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
mkfs.fat -F32 -S4096 -s1 "${serial[@]}" "$work/efi.fat" >/dev/null
mount -o loop,nosuid,nodev "$work/efi.fat" "$esp"
cp -r -- "$baseline/EFI" "$baseline/loader" "$esp/"
if [[ -n $installed ]]; then
    bash "$manage" --dev12.10 add "$installed" "$esp"
    sed -i 's/^default debian.conf$/default y700-file-12-10.conf/' "$esp/loader/loader.conf"
    grep -Fxq 'default y700-file-12-10.conf' "$esp/loader/loader.conf"
    current=$esp/loader/entries/y700-file-12-10.conf
    cp "$current" "$work/current.conf"
    echo changed >> "$current"
    if bash "$manage" "${flags[@]}" add "$entry" "$esp"; then exit 1; fi
    [[ ! -e $esp/loader/entries/$payload.conf && ! -e $esp/EFI/$payload ]]
    cp "$work/current.conf" "$current"
fi
inventory() { (cd "$esp" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }
inventory > "$work/before"
bash "$manage" "${flags[@]}" add "$entry" "$esp"
bash "$manage" "${flags[@]}" add "$entry" "$esp"
printf 'test sentinel' > "$esp/EFI/$payload/unknown"
if bash "$manage" "${flags[@]}" remove "$entry" "$esp"; then exit 1; fi
[[ -e $esp/loader/entries/$payload.conf && -e $esp/EFI/$payload/unknown ]]
rm -- "$esp/EFI/$payload/unknown"
bash "$manage" "${flags[@]}" remove "$entry" "$esp"
bash "$manage" "${flags[@]}" remove "$entry" "$esp"
inventory | cmp - "$work/before"
umount "$esp"
fsck.fat -n "$work/efi.fat"
echo FILE_TRIAL_MENU_REGRESSION_PASS
