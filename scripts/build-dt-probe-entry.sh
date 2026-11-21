#!/bin/bash
# Build a single-boot probe which retains the installed recovery initrd.
set -euo pipefail
umask 077
[[ $# == 4 ]] || { echo 'Usage: build-dt-probe-entry.sh --rtc1|--cci0 RECOVERY_ENTRY PROBE_DTB NEW_DIRECTORY, or --ldo5|--gt9768 RECOVERY_ENTRY IMAGE_DIRECTORY NEW_DIRECTORY' >&2; exit 2; }
kernel_hash=
release=dev12.10
base=y700-recovery-12-10
base_manifest=36132af676bfd7b14f7ef954c1d9329e1dc8eb77c0c99d5301eab412b5c18b0b
case $1 in
    --panel60)
        release=dev12.11; base=y700-file-12-11
        base_manifest=d7d617d453585e69eb04a279f7c3839a7edece65bd9a3887e1a1b7cdaba6a362
        name=y700-panel60-12-11
        title='NT36523N 60 Hz probe'; option=y700.panel_probe=60hz
        tree_hash=53bc719146da49baff7b975c06942892278639909e48d0f998b894220c7d05b7
        kernel_hash=0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60
        notes_hash=c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063
        manifest=1f208f3a5f4713a69987e62820d811d7886e801f7931ece5cfb4780cda7e4223 ;;
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
    --ldo5)
        name=y700-ldo5-12-10
        title='HI1339 LDO5 probe'; option=y700.ldo_probe=ldo5
        tree_hash=9546d73b96aafb9f3dbe8580ceafae65d1ba36bdcedba620da7395a8ea5f28d9
        kernel_hash=bfb74a14a8772750df919cdc80c3a141ca37b64a5a8e676e30e36206ea92fe85
        notes_hash=b52f0aebff47c2d1819d4569abc6f27d9c2f274f60f0230365d3440f99416fc7
        manifest=ec8957894bdbc40d2a9abd07a98c54f1066bb081c4bfd2887a42fe2e09eae6c5 ;;
    --gt9768)
        name=y700-gt9768-12-10
        title='GT9768 calibrated lens probe'; option=y700.focus_probe=gt9768
        tree_hash=a178f9de454d0e8aa5b474c91b4280da3aadc6aad0622c0120661447d836209f
        kernel_hash=b103d0fcd65a08cadb592fbdc69c8c483a7727ef212c15e464208f5c30a1a625
        notes_hash=35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6
        manifest=06049cd22b6a4bb0cd98df8ddbb257569fc2431e4033e7fa59f3663d38fed621 ;;
    *) exit 2 ;;
esac
shift
source_entry=$(realpath -e "$1")
if [[ -n $kernel_hash ]]; then
    image=$(realpath -e "$2")
    dtb=$image/board.dtb
    (cd "$image"; sha256sum --strict -c <<<"$kernel_hash  kernel.efi
$notes_hash  notes")
else
    dtb=$(realpath -e "$2")
fi
dest=$(realpath -m "$3")
[[ ! -e $dest && ! -L $dest ]]
(cd "$source_entry"; echo "$base_manifest  SHA256SUMS" | sha256sum --strict -c -; sha256sum --strict -c SHA256SUMS)
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
files=()
linux_sub=$base
if [[ -n $kernel_hash ]]; then
    linux_sub=$name
    install -m644 "$image/kernel.efi" "EFI/$name/kernel.efi"
    files+=("EFI/$name/kernel.efi")
fi
install -m644 "$dtb" "EFI/$name/board.dtb"
files+=("EFI/$name/board.dtb")
sed -e "s/^title .*/title Y700 $release ($title)/" \
    -e "s|^linux .*|linux /EFI/$linux_sub/kernel.efi|" \
    -e "s|^devicetree .*|devicetree /EFI/$name/board.dtb|" \
    -e "/^options /s/$/ $option/" \
    "$source_entry/loader/entries/$base.conf" >"loader/entries/$name.conf"
sha256sum "${files[@]}" "loader/entries/$name.conf" >SHA256SUMS
printf '%s  SHA256SUMS\n' "$manifest" | sha256sum --strict -c -
sha256sum --strict -c SHA256SUMS
mv -nT "$work/entry" "$dest"
[[ ! -e $work/entry ]]
