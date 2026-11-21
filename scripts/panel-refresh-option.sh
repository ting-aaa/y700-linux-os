#!/bin/bash
# Build or manage the optional 60/120 Hz dev12.11 entry. The permanent entry stays selected.
set -euo pipefail
umask 077
kernel=EFI/y700-display-12-11.efi
entry=loader/entries/y700-display-12-11.conf
base=y700-file-12-11
base_digest=d7d617d453585e69eb04a279f7c3839a7edece65bd9a3887e1a1b7cdaba6a362
digest=e63fcf5b1688ac8a4aed7c382a1e6c7b721b7a112341c9155c035fe65c4516cc
baseline() {
    sha256sum "EFI/$base/"{kernel.efi,board.dtb,initrd} "loader/entries/$base.conf" |
        sha256sum | cut -d' ' -f1
}
checked() (
    cd "$1"
    printf '%s  SHA256SUMS\n' "$digest" | sha256sum --strict -c -
    sha256sum --strict -c SHA256SUMS
)
if [[ ${1:-} == build && $# == 4 ]]; then
    image=$(realpath -e "$2"); original=$(realpath -e "$3"); output=$(realpath -ms "$4")
    [[ ! -e $output && ! -L $output && $(cd "$original"; baseline) == "$base_digest" ]]
    work=$(mktemp -d "${output%/*}/.panel-option.XXXXXXXX")
    trap 'if [[ -d $work ]]; then rm -r --one-file-system -- "$work"; fi' EXIT
    cd "$work"; mkdir -p EFI loader/entries
    install -m600 "$image" "$kernel"
    sed -e '1c title Y700 dev12.11 (60 / 120 Hz display)' -e "s|^linux .*|linux /$kernel|" \
        "$original/loader/entries/$base.conf" >"$entry"
    sha256sum "$kernel" "$entry" > SHA256SUMS
    checked .
    mv -nT -- "$work" "$output"; [[ ! -e $work ]]
    exit
fi
[[ $# == 3 && ( $1 == add || $1 == remove ) ]] || {
    echo 'Usage: panel-refresh-option.sh build KERNEL BASE_ENTRY NEW_DIR | add|remove OPTION_DIR MOUNTED_ESP' >&2
    exit 2
}
action=$1; source_dir=$(realpath -e "$2"); esp=$(realpath -e "$3")
[[ $(findmnt -nro FSTYPE,UUID -M "$esp") == 'vfat B6D4-FA81' ]]
checked "$source_dir"
cd "$esp"; exec {guard}<.; flock -n "$guard"
[[ $(baseline) == "$base_digest" && $(awk 'tolower($1) == "default" {print $2}' loader/loader.conf) == "$base.conf" ]]
if compgen -G 'loader/entries/y700-installed-*.conf' >/dev/null; then echo 'Counted trial is active' >&2; exit 1; fi
for file in "$kernel" "$entry"; do
    if [[ -e $file ]]; then cmp -- "$source_dir/$file" "$file"; fi
done
if [[ $action == add ]]; then
    tmp=
    trap 'if [[ -n $tmp ]]; then rm -f -- "$tmp"; fi' EXIT
    for file in "$kernel" "$entry"; do
        if [[ -e $file ]]; then continue; fi
        tmp=$(mktemp "${file%/*}/.y700-display.XXXXXXXX")
        cp -- "$source_dir/$file" "$tmp"; cmp -- "$source_dir/$file" "$tmp"; sync -f "$tmp"
        mv -nT -- "$tmp" "$file"; [[ ! -e $tmp ]]; tmp=
        sync -f .
    done
    sha256sum --strict -c "$source_dir/SHA256SUMS"
else
    for file in "$entry" "$kernel"; do
        if [[ -e $file ]]; then rm -- "$file"; sync -f .; fi
    done
fi
printf 'PANEL_REFRESH_OPTION action=%s default=%s.conf\n' "$action" "$base"
