#!/usr/bin/env bash
# Derive the matched-signal receiver from the sealed dev12.13 split receiver.
set -euo pipefail
export LC_ALL=C
umask 077
[[ $# == 3 ]] || { echo 'Usage: signal-attachment.sh SEALED_DEV12.13_RECEIVER SIGNAL_PROBE NEW_DIRECTORY' >&2; exit 2; }
here=$(dirname "$(realpath "$0")")
base=$(realpath -e "$1"); client=$(realpath -e "$2"); dest=$(realpath -m "$3")
[[ -f $client && -d ${dest%/*} && ! -e $dest && ! -L $dest ]]
[[ $(stat -c %d "$base") == "$(stat -c %d "${dest%/*}")" ]] || { echo 'Choose an output on the same filesystem for the carrier hard link.' >&2; exit 1; }
printf '%s  %s\n' c7e5c6a5cfc795c25bd54940b8f4f1fea0e457cafb02f6e17ca3dc6914fc608f "$base/SHA256SUMS" \
    9c86901edec6bd8f4052c62a94b994bf25d439eb0ae3ded5be9b823712442df8 "$client" | sha256sum --strict --quiet -c -
(cd "$base"; sha256sum --strict --quiet -c SHA256SUMS)
work=$(mktemp -d -- "${dest%/*}/.signal-receiver.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
mkdir "$work/tree" "$work/bundle"
tail -c 1968640 "$base/initrd" > "$work/old.cpio"
printf '%s  %s\n' b95ffa6ee14db058903c38a7c1bf892883dff150bb1dbed7e4638136f0db21d2 "$work/old.cpio" | sha256sum --strict --quiet -c -
(cd "$work/tree"; cpio --quiet -id --no-absolute-filenames < "$work/old.cpio")
(
    cd "$work/tree/y700-af-acm"
    sha256sum --strict --quiet -c SHA256SUMS
    patch --batch --forward --fuzz=0 -p1 < "$here/signal-service.patch"
    bash -n diagnostic.sh
    bash -n measure-board.sh
    install -m755 "$client" y700-signal-measure
    install -m644 "$here/signal_receipt.py" .
    # Keep every inherited file in this package's integrity check.
    mapfile -t files < <(cut -c67- SHA256SUMS)
    sha256sum "${files[@]}" signal_receipt.py y700-signal-measure > SHA256SUMS.new
    mv SHA256SUMS.new SHA256SUMS
)
(
    cd "$work/tree"
    find . -exec touch -h -d @1795150416 {} +
    find y700-af-acm y700-af-acm-init -print0 | sort -z | cpio --null --quiet --reproducible --owner=0:0 -o -H newc
) > "$work/new.cpio"
out=$work/bundle
head -c -1968640 "$base/initrd" > "$out/initrd"
cat "$work/new.cpio" >> "$out/initrd"
(( $(stat -c %s "$out/initrd") < 67108864 ))
for name in kernel.efi board.dtb cmdline.txt carrier.squashfs; do ln -- "$base/$name" "$out/$name"; done
(cd "$out"; sha256sum kernel.efi board.dtb initrd cmdline.txt carrier.squashfs > SHA256SUMS)
if (( EUID == 0 )); then
    # Match the sealed receiver's access policy for the new directory and its two new files.
    chown --reference="$base" "$out"
    for name in SHA256SUMS initrd; do
        chown --reference="$base/$name" "$out/$name"
        chmod --reference="$base/$name" "$out/$name"
    done
    chmod --reference="$base" "$out"
fi
mv -Tn -- "$out" "$dest"; [[ ! -e $out ]]
sha256sum "$dest/SHA256SUMS" "$dest/initrd"
