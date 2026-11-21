#!/usr/bin/env bash
# Append the edition-specific SD init without replacing the generic /init.
set -euo pipefail
umask 077
program=y700-sd-trial-init
change=sd-trial-return.patch
if [[ ${1:-} == --dev12.12 ]]; then
    shift; program=y700-dev1212-sd-init; change=dev12.12-sd-init.patch
fi
[[ $# == 2 ]] || { echo 'Usage: add-sd-trial-return.sh [--dev12.12] ORIGINAL_INITRD NEW_INITRD' >&2; exit 2; }
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
patch --silent --fuzz=0 -o "$program" original-init "$repo/src/boot/$change"
if [[ $program == y700-dev1212-sd-init ]]; then
    printf '%s  %s\n' 335aa115fa6389816d93f161c9a722ef5ab1fafad8a774d1ef8903ada9453f98 "$program" | sha256sum -c -
fi
chmod 755 "$program"
touch -d @1795150416 "$program"
sh -n "$program"
printf '%s\n' "$program" | cpio --quiet --reproducible -o -H newc --owner 0:0 | gzip -n > trial.cpio.gz
cat -- "$src" trial.cpio.gz > result
cmp -n "$(stat -c %s "$src")" -- "$src" result
ln -T -- result "$dest"
