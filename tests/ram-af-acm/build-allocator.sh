#!/usr/bin/env bash
# Replace only the pinned final newc member. The released carrier is hard-linked.
set -euo pipefail
export LC_ALL=C
umask 077
here=$(cd "$(dirname "$0")" && pwd -P)
settling_sha=ab1cd0e90330a2b3905d8103b5be42fa098c4f15e494e8284c13f4decfcc5d23
pairs=0
if [[ ${1:-} == --score-pairs && $# == 4 ]]; then
    pairs=1
    base=$(realpath -e "$2"); previous=$base/attachment; library=$(realpath -e "$3"); dest=$(realpath -m "$4")
    base_sha=e06431c4839c40d93afaf8ffbe3467d337782607e1de5434136abae76166fb90
    previous_sha=305912e5883e4a5cd27a17f019f7594c34f0435a06eec09222136f78a4c5b3e6
    lib_sha=a56b92c1c2528582e23b151275291d4cbb4ae70e7fc8c446c885914f5c715012
elif [[ $# == 5 ]]; then
    base=$(realpath -e "$1"); previous=$(realpath -e "$2"); client=$(realpath -e "$3"); library=$(realpath -e "$4")
    dest=$(realpath -m "$5")
    base_sha=0e52f171ce43862488272c8bc8bc2f610792ad46a678c153c03e32d3dcfd4f61
    previous_sha=63507067bf8b027da7fb070a2aedf3e949a128a7007cb7ca36f1de4c899ee8ca
    lib_sha=$settling_sha
    printf '%s  %s\n' f2f0536739cca7de9eb620f8b2677b8d37b44d55bd6f8f8982f1e202ff784900 "$client" | sha256sum --strict --quiet -c -
else
    echo 'Usage: build-allocator.sh SEALED_RECEIVER RETURN_ATTACHMENT NEW_CLIENT SETTLING_LIB NEW_OUTPUT' >&2
    echo '       build-allocator.sh --score-pairs SEALED_ALLOCATOR_RECEIVER SCORE_LIB NEW_OUTPUT' >&2
    exit 2
fi
[[ ! -e $dest && ! -L $dest ]]
printf '%s  %s\n' "$base_sha" "$base/SHA256SUMS" "$previous_sha" "$previous/SHA256SUMS" \
    "$lib_sha" "$library" | sha256sum --strict --quiet -c -
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
install -m644 "$library" "$payload/libcamera.so.0.7"
extras=()
if (( pairs )); then
    [[ $(grep -cFx "    diag_sha=$settling_sha" "$payload/measure-board.sh") == 1 ]]
    sed -i "s/^    diag_sha=$settling_sha$/    diag_sha=$lib_sha/" "$payload/measure-board.sh"
    mv -- "$payload/filter.sh" "$payload/filter-aggregates.sh"
    install -m755 "$here/filter-pairs.sh" "$payload/filter.sh"
    extras=(filter-aggregates.sh)
else
    install -m755 "$client" "$payload/y700-af-measure"
    install -m755 "$here/../camera-lens-graph/measure-board.sh" "$here/diagnostic.sh" "$here/filter.sh" \
        "$here/allocator-vm.sh" "$payload/"
    install -m644 "$here/private-allocator.sh" "$payload/"
fi
(cd "$payload"; sha256sum ack.timer allocator-vm.sh diagnostic.service diagnostic.sh "${extras[@]}" filter.sh libcamera.so.0.7 \
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
