#!/bin/bash
# Build a DT-only supplement for the exact installed recovery kernel and initrd.
set -euo pipefail
umask 077
[[ $# == 3 ]] || { echo 'Usage: build-rtc1-entry.sh RECOVERY_ENTRY RTC1_DTB NEW_DIRECTORY' >&2; exit 2; }
source_entry=$(realpath -e "$1")
dtb=$(realpath -e "$2")
dest=$(realpath -m "$3")
[[ ! -e $dest && ! -L $dest ]]
(cd "$source_entry"; echo '36132af676bfd7b14f7ef954c1d9329e1dc8eb77c0c99d5301eab412b5c18b0b  SHA256SUMS' | sha256sum --strict -c -; sha256sum --strict -c SHA256SUMS)
printf '%s  %s\n' 501e44f89c639165aa753ecbb336d14ac38846abdfc57cc343806a3248844e51 "$dtb" | sha256sum --strict -c -
work=$(mktemp -d "${dest%/*}/.y700-rtc1-entry.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
name=y700-rtc1-12-10
mkdir -p "$work/entry/EFI/$name" "$work/entry/loader/entries"
cd "$work/entry"
install -m644 "$dtb" "EFI/$name/board.dtb"
sed -e 's/^title .*/title Y700 dev12.10 (RTC1 awake probe)/' \
    -e "s|^devicetree .*|devicetree /EFI/$name/board.dtb|" \
    -e '/^options /s/$/ y700.rtc_probe=rtc1/' \
    "$source_entry/loader/entries/y700-recovery-12-10.conf" >"loader/entries/$name.conf"
sha256sum "EFI/$name/board.dtb" "loader/entries/$name.conf" >SHA256SUMS
echo '8fe4ebbca9fc20b6cd13453eb014fcf0aa48d5b6af97c4b40c0ad3d96bc0809a  SHA256SUMS' | sha256sum --strict -c -
sha256sum --strict -c SHA256SUMS
mv -nT "$work/entry" "$dest"
[[ ! -e $work/entry ]]
