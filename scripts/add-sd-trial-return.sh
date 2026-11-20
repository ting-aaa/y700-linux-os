#!/usr/bin/env bash
# Add an alternate PID 1 to the dev12.5 SD trial supplement.
set -euo pipefail
umask 077
[[ $# == 2 ]] || { echo 'Usage: add-sd-trial-return.sh ORIGINAL_INITRD NEW_INITRD' >&2; exit 2; }
[[ ! -e $2 && ! -L $2 ]]
src=$(realpath -e -- "$1")
dest=$(realpath -m -- "$2")
[[ -f $src && ! -e $dest && ! -L $dest && -d ${dest%/*} ]]
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d -- "${dest%/*}/.y700-sd-init.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
cd "$work"
printf '%s  %s\n' 6d3832e03eaea523a55c6bf12f90e1cf1146a34df1a264bdeefec9c8398d00ce "$src" | sha256sum --strict -c -
gzip -dc "$src" | cpio --quiet -i --to-stdout init > original-init
printf '%s  %s\n' 61d548300f6f66b8876757af2c0159046e1bc98e3cb36736a2d9e562fc574aac original-init | sha256sum --strict -c -
patch --silent --fuzz=0 -o y700-sd-trial-init original-init "$repo/src/boot/sd-trial-return.patch"
chmod 755 y700-sd-trial-init
touch -d @1795150416 y700-sd-trial-init
sh -n y700-sd-trial-init
printf '%s\n' y700-sd-trial-init | cpio --quiet --reproducible -o -H newc --owner 0:0 | gzip -n > trial.cpio.gz
cat -- "$src" trial.cpio.gz > result
cmp -n "$(stat -c %s "$src")" -- "$src" result
ln -T -- result "$dest"
