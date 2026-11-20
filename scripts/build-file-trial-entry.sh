#!/usr/bin/env bash
# Build four supplementary EFI files from the exact generic dev12.5 release.
set -euo pipefail
umask 077
[[ $# == 2 ]] || { echo 'Usage: build-file-trial-entry.sh IMAGES NEW_DIRECTORY' >&2; exit 2; }
images=$(realpath -e -- "$1")
[[ ! -e $2 && ! -L $2 ]]
dest=$(realpath -m -- "$2")
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d -- "${dest%/*}/.y700-file-entry.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
cd "$images"
sha256sum --strict -c <<'HASHES'
041fcf2e04b5d05edbfa3147f442a019d2f260f6544b9182087bf911ff8e55b6  root.ext4
495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6  linux-boot.fat
HASHES
cd "$work"
mkdir -p entry/EFI/y700-file entry/loader/entries append
for f in kernel.efi board.dtb; do
    mcopy -i "$images/linux-boot.fat" "::/EFI/debian/$f" "entry/EFI/y700-file/$f"
done
mcopy -i "$images/linux-boot.fat" ::/EFI/debian/initrd original-initrd
mcopy -i "$images/linux-boot.fat" ::/loader/entries/debian.conf original.conf
sha256sum --strict -c <<'HASHES'
4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1  entry/EFI/y700-file/kernel.efi
1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d  entry/EFI/y700-file/board.dtb
6d3832e03eaea523a55c6bf12f90e1cf1146a34df1a264bdeefec9c8398d00ce  original-initrd
HASHES
sed -e 's|^title .*|title Y700 dev12.5 (persistent files)|' -e 's|/EFI/debian/|/EFI/y700-file/|g' \
    -e '/^options /{s|rdinit=/init root=PARTLABEL=linux |rdinit=/y700-file-trial-init root=UUID=171a4adb-916b-4763-9e6f-722b4a99988f y700.media=file |;s/$/ panic=15/;}' \
    original.conf > entry/loader/entries/y700-file.conf
grep -q '^options rdinit=/y700-file-trial-init root=UUID=171a4adb-916b-4763-9e6f-722b4a99988f y700.media=file .* panic=15$' entry/loader/entries/y700-file.conf
cd append
for name in init shutdown; do
    install -m 755 "$repo/src/boot/file-trial-$name" "y700-file-trial-$name"
    sh -n "y700-file-trial-$name"
    touch -d @1795150416 "y700-file-trial-$name"
done
printf '%s\n' y700-file-trial-init y700-file-trial-shutdown |
    cpio --quiet --reproducible -o -H newc --owner 0:0 | gzip -n > "$work/extra.gz"
cd "$work"
cat original-initrd extra.gz > entry/EFI/y700-file/initrd
cmp -n "$(stat -c %s original-initrd)" original-initrd entry/EFI/y700-file/initrd
cd entry
sha256sum EFI/y700-file/{kernel.efi,board.dtb,initrd} loader/entries/y700-file.conf > SHA256SUMS
sha256sum --strict -c SHA256SUMS
cd "$work"
mv -T --no-clobber -- entry "$dest"
test ! -e entry
