#!/bin/bash
# Prepare a separate ESP partition image from the generic dev12.10 release.
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1795150416 MTOOLSRC=/dev/null
umask 077
[[ $# == 3 ]] || { echo 'Usage: build-camera-esp.sh RELEASE_ESP.FAT LDO5_IMAGE_DIRECTORY NEW_ESP.FAT' >&2; exit 2; }
esp=$(realpath -e -- "$1")
image=$(realpath -e -- "$2")
parent=$(realpath -e -- "$(dirname -- "$3")")
out=$parent/$(basename -- "$3")
[[ -f $esp && -d $image && ! -e $out && ! -L $out ]]
kernel=bfb74a14a8772750df919cdc80c3a141ca37b64a5a8e676e30e36206ea92fe85
dtb=9546d73b96aafb9f3dbe8580ceafae65d1ba36bdcedba620da7395a8ea5f28d9
original=495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6
candidate=ecdc35608c24b06cbad557f724ada12d7f3c98dbc92143a2e8c6d562ca9b7b67
for file in kernel.efi board.dtb; do [[ -f $image/$file ]]; done
check_source() {
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
for file in kernel.efi board.dtb; do
    install -m600 "$image/$file" "$file"
    touch -d "@$SOURCE_DATE_EPOCH" "$file"
    mcopy -o -m -i camera.fat "$file" "::/EFI/debian/$file"
done
readback camera.fat after
cmp before.paths after.paths
# The sealed single-root menu, boot manager, Android tools and original
# initrd must survive. Compare every extracted byte, directory and filename.
for file in kernel.efi board.dtb; do
    cmp "$file" "after/EFI/debian/$file"
    cp "$file" "before/EFI/debian/$file"
done
diff -r --no-dereference before after
printf '%s  camera.fat\n' "$candidate" | sha256sum --strict --quiet -c -
check_source
sync -f camera.fat
# Publish only a checked file. A concurrently created destination wins.
ln -T -- camera.fat "$out"
sync -f "$parent"
printf 'CAMERA_ESP_PASS bytes=1073741824 source=%s candidate=%s\n' "$original" "$candidate"
cat after.files
