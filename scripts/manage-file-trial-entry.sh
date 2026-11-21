#!/usr/bin/env bash
# Add or remove the four reviewed files for an edition on the mounted baseline ESP.
set -euo pipefail
umask 077
die() { echo "File trial entry: $*" >&2; exit 1; }
payload=y700-file
probe=0
manifest=c0ab1aca3a71d38000e6dda15d8730cdb7d68afc06e4cc0904ba18dd1a4184a2
if [[ ${1:-} == --dev12.11-panel60 ]]; then
    shift
    probe=1
    payload=y700-panel60-12-11
    manifest=1f208f3a5f4713a69987e62820d811d7886e801f7931ece5cfb4780cda7e4223
elif [[ ${1:-} == --dev12.11 ]]; then
    shift
    payload=y700-file-12-11
    manifest=d7d617d453585e69eb04a279f7c3839a7edece65bd9a3887e1a1b7cdaba6a362
elif [[ ${1:-} == --dev12.10 ]]; then
    shift
    payload=y700-file-12-10
    manifest=dd6f4174b3a2f17d8332d0d511d1806c8e826715abd8735e30973bedeee93d0d
elif [[ ${1:-} == --dev12.10-rtc1 ]]; then
    shift
    probe=1
    payload=y700-rtc1-12-10
    manifest=8fe4ebbca9fc20b6cd13453eb014fcf0aa48d5b6af97c4b40c0ad3d96bc0809a
elif [[ ${1:-} == --dev12.10-cci0 ]]; then
    shift
    probe=1
    payload=y700-cci0-12-10
    manifest=d181c60b152378d2b8e1505277587f346f3f54601f33b2b46b04bf816db5dcfd
elif [[ ${1:-} == --dev12.10-ldo5 ]]; then
    shift
    probe=1
    payload=y700-ldo5-12-10
    manifest=ec8957894bdbc40d2a9abd07a98c54f1066bb081c4bfd2887a42fe2e09eae6c5
elif [[ ${1:-} == --dev12.10-gt9768 ]]; then
    shift
    probe=1
    payload=y700-gt9768-12-10
    manifest=06049cd22b6a4bb0cd98df8ddbb257569fc2431e4033e7fa59f3663d38fed621
elif [[ ${1:-} == --dev12.10-recovery ]]; then
    shift
    payload=y700-recovery-12-10
    manifest=36132af676bfd7b14f7ef954c1d9329e1dc8eb77c0c99d5301eab412b5c18b0b
fi
[[ $# == 3 && ( $1 == add || $1 == remove ) ]] || die 'usage: manage-file-trial-entry.sh [--dev12.11|--dev12.10|--dev12.10-recovery|--dev12.10-rtc1|--dev12.10-cci0|--dev12.10-ldo5|--dev12.10-gt9768] add|remove VERIFIED_ENTRY_DIR MOUNTED_INTERNAL_ESP'
mode=$1
source_dir=$(realpath -e -- "$2")
esp=$(realpath -e -- "$3")
[[ $(findmnt -nro FSTYPE -M "$esp") == vfat ]] || die 'expected a mounted FAT ESP'
[[ $(findmnt -nro UUID -M "$esp") != 171A-4ADB ]] || die 'target is the trial ESP image'
if [[ $payload != y700-file ]]; then
    [[ $(findmnt -nro UUID -M "$esp") == B6D4-FA81 ]] || die 'unexpected internal ESP UUID'
fi
cd "$source_dir"
printf '%s  SHA256SUMS\n' "$manifest" | sha256sum --strict -c -
sha256sum --quiet --strict -c SHA256SUMS
cd "$esp"
exec {guard}<.
flock -n "$guard" || die 'another menu operation is active'
[[ -d EFI && -d loader/entries && -f loader/entries/debian.conf ]] || die 'internal Debian entry is missing'
default=$(awk 'tolower($1)=="default" {print $2}' loader/loader.conf)
preserved=(loader/loader.conf loader/entries/debian.conf EFI/BOOT/BOOTAA64.EFI EFI/debian/{kernel.efi,board.dtb,initrd})
if (( probe )) || [[ $payload == y700-file-12-11 ]]; then
    expected_default=y700-recovery-12-10.conf
    if [[ $payload == y700-panel60-12-11 ]]; then
        expected_default=y700-file-12-11.conf
        existing=(EFI/y700-file-12-11/{kernel.efi,board.dtb,initrd} loader/entries/y700-file-12-11.conf)
        [[ $(sha256sum "${existing[@]}" | sha256sum | cut -d' ' -f1) == d7d617d453585e69eb04a279f7c3839a7edece65bd9a3887e1a1b7cdaba6a362 ]] || die 'permanent dev12.11 payload differs'
        preserved+=("${existing[@]}")
    fi
    [[ $default == "$expected_default" ]] || die 'expected permanent release default'
    ! compgen -G 'loader/entries/y700-installed-*.conf' >/dev/null || die 'a counted trial is active'
    [[ ! -e loader/entries/y700-rtc1-12-10.conf && ! -e loader/entries/y700-cci0-12-10.conf &&
       ! -e loader/entries/y700-ldo5-12-10.conf && ! -e loader/entries/y700-gt9768-12-10.conf &&
       ! -e loader/entries/y700-panel60-12-11.conf ]] || die 'unexpected uncounted probe entry'
    for prior in y700-file-12-10 y700-recovery-12-10; do
        existing=("EFI/$prior/"{kernel.efi,board.dtb,initrd} "loader/entries/$prior.conf")
        case $prior in
            y700-file-12-10) expected=dd6f4174b3a2f17d8332d0d511d1806c8e826715abd8735e30973bedeee93d0d ;;
            y700-recovery-12-10) expected=36132af676bfd7b14f7ef954c1d9329e1dc8eb77c0c99d5301eab412b5c18b0b ;;
        esac
        [[ $(sha256sum "${existing[@]}" | sha256sum | cut -d' ' -f1) == "$expected" ]] || die 'retained installed payload differs'
        preserved+=("${existing[@]}")
    done
elif [[ $payload == y700-recovery-12-10 && $default == y700-file-12-10.conf ]]; then
    existing=(EFI/y700-file-12-10/{kernel.efi,board.dtb,initrd} loader/entries/y700-file-12-10.conf)
    existing_manifest=$(sha256sum "${existing[@]}" | sha256sum | cut -d' ' -f1)
    [[ $existing_manifest == dd6f4174b3a2f17d8332d0d511d1806c8e826715abd8735e30973bedeee93d0d ]] ||
        die 'installed default payload differs'
    preserved+=("${existing[@]}")
elif [[ $default != debian.conf ]]; then
    die 'default internal return entry differs'
fi
original=$(sha256sum "${preserved[@]}")
dir=EFI/$payload
menu=loader/entries/$payload.conf
source_menu=$menu
payloads=(kernel.efi board.dtb initrd)
if (( probe )); then
    menu=$dir/source.conf
    payloads=(board.dtb)
    if [[ $payload == y700-ldo5-12-10 || $payload == y700-gt9768-12-10 || $payload == y700-panel60-12-11 ]]; then payloads+=(kernel.efi); fi
fi
check_dir() {
    local count=${#payloads[@]}
    if [[ $probe == 1 && -e $menu ]]; then ((count+=1)); fi
    [[ -d $dir && $(find "$dir" -mindepth 1 -maxdepth 1 -printf . | wc -c) == "$count" ]] || die 'unexpected contents at trial payload path'
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
    cmp -- "$menu" "$source_dir/$source_menu"
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
        cat "$source_dir/$source_menu" > "$tmp_menu"
        cmp -- "$tmp_menu" "$source_dir/$source_menu"
        sync -f "$tmp_menu"
        mv -nT -- "$tmp_menu" "$menu"
        [[ ! -e $tmp_menu ]] || die 'menu path appeared concurrently'
    fi
    if [[ $menu == "$source_menu" ]]; then sha256sum --strict -c "$source_dir/SHA256SUMS"
    else cmp "$menu" "$source_dir/$source_menu"; check_dir; fi
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
printf 'FILE_TRIAL_MENU_PASS action=%s default=%s original_hashes=unchanged\n' "$mode" "$default"
