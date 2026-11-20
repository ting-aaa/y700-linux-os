#!/usr/bin/env bash
# Package a disposable first kernel's initramfs for the QEMU-only warm boot test.
set -euo pipefail
umask 077
[[ $# == 2 ]] || { echo 'Usage: prepare.sh RAM_BUNDLE NEW_FIRST_INITRD' >&2; exit 2; }
here=$(cd -- "$(dirname -- "$0")" && pwd)
trial=$(realpath -e -- "$1")
dest=$(realpath -m -- "$2")
[[ ! -e $dest && ! -L $dest ]]
scratch=$(mktemp -d -- "${dest%/*}/.y700-handover.XXXXXXXX")
trap 'rm -r --one-file-system -- "$scratch"' EXIT
(cd "$trial" && sha256sum --strict -c SHA256SUMS)
cd "$scratch"
mkdir dev proc sys
cp -- "$here/check-irq-placement.awk" .
# Take the checksum utility from the candidate's original early userspace.
head -c 11637348 "$trial/initrd" | gzip -dc | cpio --quiet -idm bin/busybox
awk '$2 == "kernel.efi" || $2 == "initrd"' "$trial/SHA256SUMS" > payload.sha256
[[ $(wc -l < payload.sha256) == 2 ]]
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -static -O2 -Wall -Wextra -Werror \
    "$here/first-kernel.c" -o y700-ram-trial-init
ln -s -- "$trial/kernel.efi" kernel.efi
ln -s -- "$trial/initrd" initrd
printf '%s\n' dev proc sys bin bin/busybox payload.sha256 check-irq-placement.awk y700-ram-trial-init kernel.efi initrd |
    cpio --quiet --dereference --reproducible -o -H newc --owner 0:0 > first.cpio
ln -- first.cpio "$dest"
