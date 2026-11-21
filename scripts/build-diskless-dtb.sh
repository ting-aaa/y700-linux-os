#!/usr/bin/env bash
# Build the dev12.12 RAM-only diagnostic board description on the development host.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: build-diskless-dtb.sh RELEASE_BOARD_DTB NEW_RAM_DTB' >&2; exit 2; }
source_dtb=$(realpath -e -- "$1")
dest=$2
[[ -f $source_dtb && ! -e $dest && ! -L $dest ]]
printf '%s  %s\n' 53bc719146da49baff7b975c06942892278639909e48d0f998b894220c7d05b7 "$source_dtb" |
    sha256sum --strict --quiet -c -
[[ $(fdtget "$source_dtb" / compatible) == 'lenovo,asphalt qcom,sm8475' && $(fdtget "$source_dtb" / region_country) == PRC ]]
work=$(mktemp -d -- "$(dirname -- "$dest")/.y700-ram-dtb.XXXXXXXX")
trap 'rm -r -- "$work"' EXIT
cp -- "$source_dtb" "$work/diskless.dtb"
controllers=(/soc@0/ufshc@1d84000 /soc@0/mmc@8804000)
for node in "${controllers[@]}"; do
    [[ $(fdtget "$source_dtb" "$node" status) == okay ]]
    fdtput -t s "$work/diskless.dtb" "$node" status disabled
    [[ $(fdtget "$work/diskless.dtb" "$node" status) == disabled ]]
done
# Restore the two properties in a private copy and compare the full canonical trees.
cp -- "$work/diskless.dtb" "$work/check.dtb"
for node in "${controllers[@]}"; do fdtput -t s "$work/check.dtb" "$node" status okay; done
dtc -q -s -I dtb -O dtb -o "$work/original.dtb" "$source_dtb"
dtc -q -s -I dtb -O dtb -o "$work/restored.dtb" "$work/check.dtb"
cmp "$work/original.dtb" "$work/restored.dtb"
ln -T -- "$work/diskless.dtb" "$dest"
sha256sum -- "$dest"
