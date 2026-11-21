#!/usr/bin/env bash
# Materialize the sealed dev12.14 generic images from the original dev12.13 archive.
set -euo pipefail
umask 077
fail() { echo "$1" >&2; exit 1; }
bundle=$(cd -- "$(dirname -- "$0")" && pwd -P)
personalize=false
if [[ ${1:-} == --bluetooth-address ]]; then
    set +x
    [[ $# == 4 ]] || fail 'Expected a private address file, parent TAR and new directory'
    address=$(realpath --no-symlinks -- "$2"); shift 2; personalize=true
fi
[[ $# == 2 ]] || fail 'Usage: bash unpack.sh [--bluetooth-address PRIVATE_FILE] DEV12.13.tar NEW_DIRECTORY'
archive=$(realpath -e -- "$1")
[[ -f $archive && ! -e $2 && ! -L $2 && $2 != */ ]] || fail 'Expected an archive and a new output directory'
parent=$(cd -- "$(dirname -- "$2")" && pwd -P)
target=$parent/$(basename -- "$2")
source "$bundle/build-storage-guard.sh" board "$parent"
cd "$bundle"
sha256sum --strict -c SHA256SUMS
command -v xdelta3 >/dev/null
prefix=y700-tb320fc-prc-debian-dev12.13/base
exec {fd}<"$archive"
archive=/proc/$$/fd/$fd
echo "60fc1e12b2ad707270bf722d90e72e32c030ae377a50a37130ecd4336aac1fb6  $archive" | sha256sum --strict -c -
if "$personalize"; then
    # The bundle contains the parent release's reviewed private input/readback functions.
    source "$bundle/bluetooth.sh"
    command -v debugfs >/dev/null && command -v e2fsck >/dev/null
    read_private_address "$address"
fi
stage=$(mktemp -d -- "$parent/.y700-dev12.14.XXXXXXXX")
trap 'rm -r --one-file-system -- "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$stage/image"
cd "$stage/image"
for file in asphalt-prc-u-boot.img linux-boot.fat root.ext4; do
    tar -xOf "$archive" "$prefix/$file.zst" | zstd -qd --sparse -o "$file"
done
echo '6155d87d5d5b9d5557e86362f09fb17328aef200861e94eb292a669c35659c7c  root.ext4' | sha256sum --strict -c -
mv -T root.ext4 "$stage/parent.ext4"
xdelta3 -d -c -s "$stage/parent.ext4" "$bundle/root.vcdiff" | dd of=root.ext4 bs=1M conv=sparse status=none
cp -- "$bundle/identity.txt" .
cp -- "$bundle/RAW-SHA256SUMS" SHA256SUMS
sha256sum --strict -c SHA256SUMS
if "$personalize"; then personalize_root; fi
cd "$stage"
mv -T --no-clobber -- image "$target"
[[ ! -e image ]] || fail 'Output directory appeared while unpacking'
printf 'Unpacked dev12.14 into %s\n' "$target"
