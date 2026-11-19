#!/usr/bin/env bash
# Reconstruct the updated development image from the compressed base and QCOW2.
set -euo pipefail
umask 077
if (( $# != 1 )); then echo "Usage: bash $0 --verify | NEW_DIRECTORY" >&2; exit 2; fi
bundle=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
manifest_names() {
    local source=$1 name pattern='^[0-9a-f]{64}  ' record
    shift
    local -a rows
    mapfile -t rows < "$source"
    (( ${#rows[@]} == $# )) || return 1
    for record in "${rows[@]}"; do
        name=$1; shift
        [[ $record =~ $pattern && ${record:66} == "$name" ]] || return 1
    done
}
manifest_names "$bundle/SHA256SUMS" base/SHA256SUMS base/unpack.sh dev8.qcow2 identity.txt RAW-SHA256SUMS y700-platform_0.1.0~dev8_all.deb
manifest_names "$bundle/RAW-SHA256SUMS" asphalt-prc-u-boot.img linux-boot.fat root.ext4 identity.txt
manifest_names "$bundle/base/SHA256SUMS" asphalt-prc-u-boot.img.zst linux-boot.fat.zst root.ext4.zst identity.txt RAW-SHA256SUMS
if [[ $1 != --verify ]]; then
    [[ -n $1 && $1 != -* && $1 != */ ]] || exit 2
    parent=$(cd -- "$(dirname -- "$1")" && pwd -P)
    target=$parent/$(basename -- "$1")
    [[ ! -e $target && ! -L $target ]] || { echo 'Choose a new destination' >&2; exit 1; }
    # Reserve the three logical image sizes plus the private overlay and metadata.
    available=$(df -B1 --output=avail "$parent" | tail -1)
    required=$((41406464 + 1073741824 + 6442450944 + $(stat -Lc %s "$bundle/dev8.qcow2") + 16777216))
    (( available >= required )) || { echo "Need $required free bytes at the destination" >&2; exit 1; }
fi
(cd "$bundle" && sha256sum --strict -c SHA256SUMS)
if [[ $1 == --verify ]]; then
    bash "$bundle/base/unpack.sh" --verify
    echo 'Compressed base and update payload verified. Extraction checks the complete resulting raw image.'
    exit
fi
command -v qemu-img >/dev/null
stage=$(mktemp -d --tmpdir="$parent" .y700-dev8.XXXXXXXX)
cleanup() {
    if [[ -d $stage ]]; then
        rm -f -- "$stage/image/"{asphalt-prc-u-boot.img,linux-boot.fat,root.ext4,identity.txt,SHA256SUMS,dev8.qcow2}
        if [[ -d $stage/image ]]; then rmdir -- "$stage/image"; fi
        rmdir -- "$stage"
    fi
}
trap cleanup EXIT
bash "$bundle/base/unpack.sh" "$stage/image"
cd "$stage/image"
# Use a private overlay copy; only the freshly unpacked regular file is writable.
[[ -f root.ext4 && ! -L root.ext4 && $(stat -c %h root.ext4) == 1 ]]
cp --sparse=always -- "$bundle/dev8.qcow2" dev8.qcow2
qemu-img check -f qcow2 dev8.qcow2
qemu-img commit -d -f qcow2 -b "$stage/image/root.ext4" dev8.qcow2
rm -- dev8.qcow2
cp -- "$bundle/identity.txt" identity.txt
cp -- "$bundle/RAW-SHA256SUMS" SHA256SUMS
sha256sum --strict -c SHA256SUMS
cd "$stage"
mv -T --no-clobber -- image "$target"
[[ ! -e image ]] || { echo 'The destination appeared during extraction' >&2; exit 1; }
printf 'Unpacked and verified %s\n' "$target"
