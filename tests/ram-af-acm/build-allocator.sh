#!/usr/bin/env bash
# Replace only the pinned final newc member. The released carrier is hard-linked.
set -euo pipefail
export LC_ALL=C
umask 077
[[ $# == 5 ]] || { echo 'Usage: build-allocator.sh SEALED_RECEIVER RETURN_ATTACHMENT NEW_CLIENT SETTLING_LIB NEW_OUTPUT' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd -P)
base=$(realpath -e "$1"); previous=$(realpath -e "$2"); client=$(realpath -e "$3"); library=$(realpath -e "$4")
dest=$(realpath -m "$5")
[[ ! -e $dest && ! -L $dest ]]
printf '%s  %s\n' \
    0e52f171ce43862488272c8bc8bc2f610792ad46a678c153c03e32d3dcfd4f61 "$base/SHA256SUMS" \
    63507067bf8b027da7fb070a2aedf3e949a128a7007cb7ca36f1de4c899ee8ca "$previous/SHA256SUMS" \
    f2f0536739cca7de9eb620f8b2677b8d37b44d55bd6f8f8982f1e202ff784900 "$client" \
    ab1cd0e90330a2b3905d8103b5be42fa098c4f15e494e8284c13f4decfcc5d23 "$library" | sha256sum --strict --quiet -c -
(cd "$base"; sha256sum --strict --quiet -c SHA256SUMS)
(cd "$previous"; sha256sum --strict --quiet -c SHA256SUMS)
work=$(mktemp -d /var/tmp/y700-af-allocator-build.XXXXXXXX)
draft=$(mktemp -d -- "${dest%/*}/.ram-allocator.XXXXXXXX")
trap 'rm -r -- "$work" "$draft"' EXIT
mkdir "$work/tree" "$draft/bundle" "$draft/bundle/attachment"
out=$draft/bundle; addon=$out/attachment
old=$previous/af-acm.cpio
old_size=$(stat -c %s "$old")
prefix=$(( $(stat -c %s "$base/initrd") - old_size ))
(( prefix > 11637348 && prefix % 4 == 0 ))
tail -c "$old_size" "$base/initrd" | cmp - "$old"
(cd "$work/tree"; cpio --quiet -id --no-absolute-filenames < "$old")
payload=$work/tree/y700-af-acm
(cd "$payload"; sha256sum --strict --quiet -c SHA256SUMS)
install -m755 "$client" "$payload/y700-af-measure"
install -m644 "$library" "$payload/libcamera.so.0.7"
install -m755 "$here/../camera-lens-graph/measure-board.sh" "$here/diagnostic.sh" "$here/filter.sh" \
    "$here/allocator-vm.sh" "$payload/"
install -m644 "$here/private-allocator.sh" "$payload/"
(cd "$payload"; sha256sum ack.timer allocator-vm.sh diagnostic.service diagnostic.sh filter.sh libcamera.so.0.7 \
    measure-board.sh private-allocator.sh return.service return.timer y700-af-measure > SHA256SUMS)
(cd "$work/tree"; find . -exec touch -h -d @1795150416 {} +; find y700-af-acm y700-af-acm-init -print0 | \
    sort -z | cpio --null --quiet --reproducible --owner 0:0 -o -H newc) > "$addon/af-acm.cpio"
cp -- "$previous/cmdline.txt" "$addon/cmdline.txt"
(cd "$addon"; sha256sum af-acm.cpio cmdline.txt > SHA256SUMS)
head -c "$prefix" "$base/initrd" > "$out/initrd"
cat "$addon/af-acm.cpio" >> "$out/initrd"
(( $(stat -c %s "$out/initrd") < 67108864 ))
for file in kernel.efi board.dtb cmdline.txt carrier.squashfs; do ln -- "$base/$file" "$out/$file"; done
(cd "$out"; sha256sum kernel.efi board.dtb initrd cmdline.txt carrier.squashfs > SHA256SUMS)
mv -Tn -- "$out" "$dest"; [[ ! -e $out ]]
sha256sum "$dest/SHA256SUMS" "$dest/attachment/SHA256SUMS"
