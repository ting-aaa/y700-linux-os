#!/usr/bin/env bash
# Add or remove the four reviewed files for an edition on the mounted baseline ESP.
set -euo pipefail
umask 077
die() { echo "File trial entry: $*" >&2; exit 1; }
payload=y700-file
manifest=c0ab1aca3a71d38000e6dda15d8730cdb7d68afc06e4cc0904ba18dd1a4184a2
if [[ ${1:-} == --dev12.10 ]]; then
    shift
    payload=y700-file-12-10
    manifest=dd6f4174b3a2f17d8332d0d511d1806c8e826715abd8735e30973bedeee93d0d
fi
[[ $# == 3 && ( $1 == add || $1 == remove ) ]] || die 'usage: manage-file-trial-entry.sh [--dev12.10] add|remove VERIFIED_ENTRY_DIR MOUNTED_INTERNAL_ESP'
mode=$1
source_dir=$(realpath -e -- "$2")
esp=$(realpath -e -- "$3")
[[ $(findmnt -nro FSTYPE -M "$esp") == vfat ]] || die 'expected a mounted FAT ESP'
[[ $(findmnt -nro UUID -M "$esp") != 171A-4ADB ]] || die 'target is the trial ESP image'
if [[ $payload == y700-file-12-10 ]]; then
    [[ $(findmnt -nro UUID -M "$esp") == B6D4-FA81 ]] || die 'unexpected internal ESP UUID'
fi
cd "$source_dir"
printf '%s  SHA256SUMS\n' "$manifest" | sha256sum --strict -c -
sha256sum --quiet --strict -c SHA256SUMS
cd "$esp"
[[ -d EFI && -d loader/entries && -f loader/entries/debian.conf ]] || die 'internal Debian entry is missing'
[[ $(awk 'tolower($1) == "default" {print $2}' loader/loader.conf) == debian.conf ]] || die 'default internal return entry differs'
original=$(sha256sum loader/loader.conf loader/entries/debian.conf EFI/BOOT/BOOTAA64.EFI EFI/debian/{kernel.efi,board.dtb,initrd})
exec {guard}<.
flock -n "$guard" || die 'another menu operation is active'
dir=EFI/$payload
menu=loader/entries/$payload.conf
payloads=(kernel.efi board.dtb initrd)
check_dir() {
    [[ -d $dir && $(find "$dir" -mindepth 1 -maxdepth 1 -printf . | wc -c) == 3 ]] || die 'unexpected contents at trial payload path'
    for file in "${payloads[@]}"; do cmp -- "$source_dir/$dir/$file" "$dir/$file"; done
}
tmp_dir=
tmp_menu=
cleanup() {
    if [[ -n $tmp_menu && -f $tmp_menu ]]; then rm -- "$tmp_menu"; fi
    if [[ -n $tmp_dir && -d $tmp_dir ]]; then
        rm -f -- "$tmp_dir"/{kernel.efi,board.dtb,initrd}
        rmdir -- "$tmp_dir"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -e $menu ]]; then
    cmp -- "$menu" "$source_dir/$menu"
    check_dir
fi
if [[ -e $dir ]]; then check_dir; fi
if [[ $mode == add ]]; then
    if [[ ! -e $dir ]]; then
        tmp_dir=$(mktemp -d EFI/.y700-file.XXXXXXXX)
        for file in "${payloads[@]}"; do
            cp -- "$source_dir/$dir/$file" "$tmp_dir/$file"
            cmp -- "$source_dir/$dir/$file" "$tmp_dir/$file"
        done
        sync -f "$tmp_dir"
        mv -nT -- "$tmp_dir" "$dir"
        [[ ! -e $tmp_dir ]] || die 'trial payload path appeared concurrently'
    fi
    check_dir
    if [[ ! -e $menu ]]; then
        tmp_menu=$(mktemp loader/entries/.y700-file.XXXXXXXX)
        cat "$source_dir/$menu" > "$tmp_menu"
        cmp -- "$tmp_menu" "$source_dir/$menu"
        sync -f "$tmp_menu"
        mv -nT -- "$tmp_menu" "$menu"
        [[ ! -e $tmp_menu ]] || die 'menu path appeared concurrently'
    fi
    sha256sum --strict -c "$source_dir/SHA256SUMS"
else
    if [[ -e $menu ]]; then rm -- "$menu"; sync -f .; fi
    if [[ -d $dir ]]; then
        tmp_dir=$(mktemp -d EFI/.y700-file.XXXXXXXX)
        rmdir -- "$tmp_dir"
        mv -T -- "$dir" "$tmp_dir"
    fi
fi
sync -f .
printf '%s\n' "$original" | sha256sum --quiet --strict -c -
printf 'FILE_TRIAL_MENU_PASS action=%s default=debian.conf original_hashes=unchanged\n' "$mode"
