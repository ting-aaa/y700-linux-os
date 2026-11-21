#!/usr/bin/env bash
# Assemble the five short-lived cache files outside the firmware partitions.
set -euo pipefail
umask 077
[[ $# == 6 ]] || { echo 'Usage: prepare-stage.sh STOCK_IMAGE STOCK_DTB CANDIDATE_DIR OBSERVER_INITRD INITRD_SHA256 NEW_DIRECTORY' >&2; exit 2; }
stock=$(realpath -e "$1"); stockdt=$(realpath -e "$2"); candidate=$(realpath -e "$3")
initrd=$(realpath -e "$4"); pin=$5; dest=$(realpath -m "$6")
[[ $pin =~ ^[0-9a-f]{64}$ && ! -e $dest && ! -L $dest ]]
stock_image=0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60
stock_dt=53bc719146da49baff7b975c06942892278639909e48d0f998b894220c7d05b7
candidate_image=243db9c43ef8f7a4a3e224106d87f2c87ba16c1ce93c475c4eafa02f8817fce6
candidate_dt=c2def1dcb64e3a50fbad8304ffbb92c34401c03bf4b3a72471799b6dab75c65c
printf '%s  %s\n' "$stock_image" "$stock" "$stock_dt" "$stockdt" "$candidate_image" "$candidate/kernel.efi" \
    "$candidate_dt" "$candidate/board.dtb" "$pin" "$initrd" | sha256sum --strict --quiet -c -
tmp=$(mktemp -d -- "$(dirname "$dest")/.ufs-stage.XXXXXXXX")
trap 'rm -r --one-file-system -- "$tmp"' EXIT
mkdir "$tmp/cache"
cd "$tmp/cache"
for kind in stock candidate; do
    if [[ $kind == stock ]]; then src=$stock; dt=$stockdt; else src=$candidate/kernel.efi; dt=$candidate/board.dtb; fi
    ln -- "$src" "$kind-image" 2>/dev/null || cp --reflink=auto -- "$src" "$kind-image"
    cp -- "$dt" "$kind.dtb"
    [[ $(fdtget "$kind.dtb" /soc@0/ufshc@1d84000 status) == okay && $(fdtget "$kind.dtb" /soc@0/mmc@8804000 status) == okay ]]
    fdtput -t s "$kind.dtb" /soc@0/mmc@8804000 status disabled
done
ln -- "$initrd" initrd 2>/dev/null || cp --reflink=auto -- "$initrd" initrd
printf '%s  %s\n' 7578715cea3c1acbbc8bcc7f60226e8e4bbe6c6b296cba5696f9f5128b9a0d3a stock.dtb \
    df17a0afb947a7adff4631d0ad9ee888629ac2c6523a5db28865c368915025c2 candidate.dtb | sha256sum --strict --quiet -c -
sha256sum -- stock-image stock.dtb candidate-image candidate.dtb initrd
cd "$tmp"
mv -Tn -- cache "$dest"; [[ ! -e cache ]]
