#!/bin/bash
# Prepare a separate, byte-verified ESP image from a sealed generic release.
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1795150416 MTOOLSRC=/dev/null
umask 077
mode=ldo5
case ${1:-} in --gt9768|--gt9768-rtc1|--dev12.12) mode=${1#--}; shift ;; esac
[[ $# == 3 ]] || { echo 'Usage: build-camera-esp.sh [--gt9768|--gt9768-rtc1|--dev12.12] RELEASE_ESP.FAT KERNEL_IMAGE_DIRECTORY NEW_ESP.FAT' >&2; exit 2; }
esp=$(realpath -e -- "$1")
image=$(realpath -e -- "$2")
parent=$(realpath -e -- "$(dirname -- "$3")")
out=$parent/$(basename -- "$3")
[[ -f $esp && -d $image && ! -e $out && ! -L $out ]]
kernel=bfb74a14a8772750df919cdc80c3a141ca37b64a5a8e676e30e36206ea92fe85
dtb=9546d73b96aafb9f3dbe8580ceafae65d1ba36bdcedba620da7395a8ea5f28d9
original=495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6
candidate=ecdc35608c24b06cbad557f724ada12d7f3c98dbc92143a2e8c6d562ca9b7b67
if [[ $mode == dev12.12 ]]; then
    original=92d47c14c4606d106ebad21ece8f5e23f244bd5aecea0c377bbe8966f8261b36
    kernel=0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60
    dtb=53bc719146da49baff7b975c06942892278639909e48d0f998b894220c7d05b7
    notes=c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063
    candidate=1f6d75c17b5f38ff69d57e13c671bd0c1cbccf0c74cf1ea3f79e2011445ed091
elif [[ $mode != ldo5 ]]; then
    kernel=b103d0fcd65a08cadb592fbdc69c8c483a7727ef212c15e464208f5c30a1a625
    dtb=a178f9de454d0e8aa5b474c91b4280da3aadc6aad0622c0120661447d836209f
    notes=35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6
    candidate=5004039ac64b91a5dc70375cb0db6c11aff590dcb69031dd5c767323f1e90d40
    if [[ $mode == gt9768-rtc1 ]]; then
        dtb=53bc719146da49baff7b975c06942892278639909e48d0f998b894220c7d05b7
        candidate=92d47c14c4606d106ebad21ece8f5e23f244bd5aecea0c377bbe8966f8261b36
    fi
fi
for file in kernel.efi board.dtb; do [[ -f $image/$file ]]; done
check_source() {
    if [[ $mode != ldo5 ]]; then printf '%s  %s\n' "$notes" "$image/notes" | sha256sum --strict --quiet -c -; fi
    printf '%s  %s\n' "$original" "$esp" "$kernel" "$image/kernel.efi" "$dtb" "$image/board.dtb" |
        sha256sum --strict --quiet -c -
}
check_source
work=$(mktemp -d -- "$parent/.y700-camera-esp.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
cd "$work"
mkdir before after
cp --sparse=always --reflink=auto -- "$esp" camera.fat
chmod u+w camera.fat
readback() {
    local fat=$1 dir=$2
    [[ $(stat -c %s "$fat") == 1073741824 && $(blkid -p -s UUID -o value "$fat") == 171A-4ADB ]]
    fsck.fat -n "$fat"
    mdir -abs -i "$fat" ::/ | sort >"$dir.paths"
    mcopy -s -i "$fat" '::*' "$dir/"
    (cd "$dir"; find . -type f -print0 | sort -z | xargs -0 sha256sum) >"$dir.files"
}
readback "$esp" before
if [[ $mode == dev12.12 ]]; then
    cp before/EFI/debian/kernel.efi kernel-120.efi
    install -m600 "$image/kernel.efi" kernel.efi
    cmp "$image/board.dtb" before/EFI/debian/board.dtb
    base=before/loader/entries/debian.conf
    sed '1c title Y700 dev12.12 (60 / 120 Hz display)' "$base" > debian.conf
    sed -e '1c title Y700 dev12.12 (dev12.11 kernel, 120 Hz only)' \
        -e 's|^linux .*|linux /EFI/debian/kernel-120.efi|' \
        -e 's/^sort-key debian$/sort-key debian-fallback/' "$base" > debian-120.conf
    touch -d "@$SOURCE_DATE_EPOCH" kernel{,-120}.efi debian{,-120}.conf
    mcopy -o -m -i camera.fat kernel{,-120}.efi ::/EFI/debian/
    mcopy -o -m -i camera.fat debian{,-120}.conf ::/loader/entries/
    cp kernel{,-120}.efi before/EFI/debian/
    cp debian{,-120}.conf before/loader/entries/
    printf '%s\n' ::/EFI/debian/kernel-120.efi ::/loader/entries/debian-120.conf >>before.paths
    sort -o before.paths before.paths
else
    for file in kernel.efi board.dtb; do
        install -m600 "$image/$file" "$file"
        touch -d "@$SOURCE_DATE_EPOCH" "$file"
        mcopy -o -m -i camera.fat "$file" "::/EFI/debian/$file"
        cp "$file" "before/EFI/debian/$file"
    done
fi
readback camera.fat after
cmp before.paths after.paths
# Compare against the source tree with only the intended files substituted.
diff -r --no-dereference before after
printf '%s  camera.fat\n' "$candidate" | sha256sum --strict --quiet -c -
check_source
sync -f camera.fat
# Publish only a checked file. A concurrently created destination wins.
ln -T -- camera.fat "$out"
sync -f "$parent"
printf 'CAMERA_ESP_PASS bytes=1073741824 source=%s candidate=%s\n' "$original" "$candidate"
cat after.files
