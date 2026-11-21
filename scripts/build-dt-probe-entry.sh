#!/bin/bash
# Build a DT-only supplement for the exact installed recovery kernel and initrd.
set -euo pipefail
umask 077
[[ $# == 4 ]] || { echo 'Usage: build-dt-probe-entry.sh --rtc1|--cci0 RECOVERY_ENTRY PROBE_DTB NEW_DIRECTORY' >&2; exit 2; }
case $1 in
    --rtc1)
        name=y700-rtc1-12-10
        title='RTC1 awake probe'; option=y700.rtc_probe=rtc1
        tree_hash=501e44f89c639165aa753ecbb336d14ac38846abdfc57cc343806a3248844e51
        manifest=8fe4ebbca9fc20b6cd13453eb014fcf0aa48d5b6af97c4b40c0ad3d96bc0809a ;;
    --cci0)
        name=y700-cci0-12-10
        title='CCI0 37.5 MHz probe'; option=y700.cci_probe=cci0
        tree_hash=b7364d3d493689f5d64834d22dbaa3684892fb3572bceaf653659f7486d69aea
        manifest=d181c60b152378d2b8e1505277587f346f3f54601f33b2b46b04bf816db5dcfd ;;
    *) exit 2 ;;
esac
shift
source_entry=$(realpath -e "$1")
dtb=$(realpath -e "$2")
dest=$(realpath -m "$3")
[[ ! -e $dest && ! -L $dest ]]
(cd "$source_entry"; echo '36132af676bfd7b14f7ef954c1d9329e1dc8eb77c0c99d5301eab412b5c18b0b  SHA256SUMS' | sha256sum --strict -c -; sha256sum --strict -c SHA256SUMS)
printf '%s  %s\n' "$tree_hash" "$dtb" | sha256sum --strict -c -
work=$(mktemp -d "${dest%/*}/.y700-dt-entry.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
if [[ $name == y700-cci0-12-10 ]]; then
    cp "$dtb" "$work/reverse.dtb"
    fdtput -d "$work/reverse.dtb" /soc@0/cci@ac15000 assigned-clocks assigned-clock-rates
    dtc -q -I dtb -O dts -s -o "$work/reverse.dts" "$work/reverse.dtb"
    dtc -q -I dtb -O dts -s -o "$work/baseline.dts" "$source_entry/EFI/y700-recovery-12-10/board.dtb"
    cmp "$work/reverse.dts" "$work/baseline.dts"
fi
mkdir -p "$work/entry/EFI/$name" "$work/entry/loader/entries"
cd "$work/entry"
install -m644 "$dtb" "EFI/$name/board.dtb"
sed -e "s/^title .*/title Y700 dev12.10 ($title)/" \
    -e "s|^devicetree .*|devicetree /EFI/$name/board.dtb|" \
    -e "/^options /s/$/ $option/" \
    "$source_entry/loader/entries/y700-recovery-12-10.conf" >"loader/entries/$name.conf"
sha256sum "EFI/$name/board.dtb" "loader/entries/$name.conf" >SHA256SUMS
printf '%s  SHA256SUMS\n' "$manifest" | sha256sum --strict -c -
sha256sum --strict -c SHA256SUMS
mv -nT "$work/entry" "$dest"
[[ ! -e $work/entry ]]
