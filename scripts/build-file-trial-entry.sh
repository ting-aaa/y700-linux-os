#!/usr/bin/env bash
# Build four supplementary EFI files from the selected exact generic release.
set -euo pipefail
umask 077
edition=dev12.5
payload=y700-file
root_sha=041fcf2e04b5d05edbfa3147f442a019d2f260f6544b9182087bf911ff8e55b6
extra=
if [[ ${1:-} == --dev12.10 ]]; then
    shift
    edition=dev12.10
    payload=y700-file-12-10
    root_sha=18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd
    extra="y700.release=$edition "
fi
[[ $# == 2 ]] || { echo 'Usage: build-file-trial-entry.sh [--dev12.10] IMAGES NEW_DIRECTORY' >&2; exit 2; }
images=$(realpath -e -- "$1")
[[ ! -e $2 && ! -L $2 ]]
dest=$(realpath -m -- "$2")
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d -- "${dest%/*}/.y700-file-entry.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
cd "$images"
printf '%s  root.ext4\n' "$root_sha" | sha256sum --strict -c -
sha256sum --strict -c <<'HASHES'
495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6  linux-boot.fat
HASHES
cd "$work"
mkdir -p "entry/EFI/$payload" entry/loader/entries append
for f in kernel.efi board.dtb; do
    mcopy -i "$images/linux-boot.fat" "::/EFI/debian/$f" "entry/EFI/$payload/$f"
done
mcopy -i "$images/linux-boot.fat" ::/EFI/debian/initrd original-initrd
mcopy -i "$images/linux-boot.fat" ::/loader/entries/debian.conf original.conf
sha256sum --strict -c <<HASHES
4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1  entry/EFI/$payload/kernel.efi
1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d  entry/EFI/$payload/board.dtb
6d3832e03eaea523a55c6bf12f90e1cf1146a34df1a264bdeefec9c8398d00ce  original-initrd
HASHES
menu=loader/entries/$payload.conf
sed -e "s|^title .*|title Y700 $edition (persistent files)|" -e "s|/EFI/debian/|/EFI/$payload/|g" \
    -e "/^options /{s|rdinit=/init root=PARTLABEL=linux |rdinit=/y700-file-trial-init root=UUID=171a4adb-916b-4763-9e6f-722b4a99988f y700.media=file ${extra}|;s/$/ panic=15/;}" \
    original.conf > "entry/$menu"
grep -q '^options rdinit=/y700-file-trial-init root=UUID=171a4adb-916b-4763-9e6f-722b4a99988f y700.media=file .* panic=15$' "entry/$menu"
cd append
for name in init shutdown; do
    install -m 755 "$repo/src/boot/file-trial-$name" "y700-file-trial-$name"
done
if [[ $edition == dev12.10 ]]; then
    patch --batch --forward --fuzz=0 -p1 < "$repo/src/boot/file-trial-dev12.10.patch"
fi
for name in init shutdown; do
    sh -n "y700-file-trial-$name"
    touch -d @1795150416 "y700-file-trial-$name"
done
printf '%s\n' y700-file-trial-init y700-file-trial-shutdown |
    cpio --quiet --reproducible -o -H newc --owner 0:0 | gzip -n > "$work/extra.gz"
cd "$work"
cat original-initrd extra.gz > "entry/EFI/$payload/initrd"
cmp -n "$(stat -c %s original-initrd)" original-initrd "entry/EFI/$payload/initrd"
cd entry
sha256sum "EFI/$payload/"{kernel.efi,board.dtb,initrd} "$menu" > SHA256SUMS
sha256sum --strict -c SHA256SUMS
cd "$work"
mv -T --no-clobber -- entry "$dest"
test ! -e entry
