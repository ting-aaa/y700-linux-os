#!/usr/bin/env bash
# Carry the verified score-pair diagnostic and its USB return timer onto dev12.13.
set -euo pipefail
export LC_ALL=C
umask 077
[[ $# == 2 ]] || { echo 'Usage: dev12.13-attachment.sh SCORES_AF_ACM.cpio NEW_DIRECTORY' >&2; exit 2; }
source_cpio=$(realpath -e -- "$1")
out=$(realpath -m -- "$2")
[[ -f $source_cpio && ! -e $out && ! -L $out ]]
printf '%s  %s\n' f1c4fce05c14756f0cc1e5816e9b398941e777bb54caa2f00e1981ea5710cd55 "$source_cpio" | sha256sum --strict -c -
work=$(mktemp -d -- "${out%/*}/.y700-af-stage.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
mkdir "$work/tree" "$work/result"
cd "$work/tree"
cpio --quiet -id --no-absolute-filenames < "$source_cpio"
(
    cd y700-af-acm
    sha256sum --strict --quiet -c SHA256SUMS
    [[ $(grep -Fxc 'grep -Fxq IMAGE_VERSION=dev12.12 /etc/os-release' diagnostic.sh) == 1 ]]
    sed -i -e 's/^grep -Fxq IMAGE_VERSION=dev12\.12 /grep -Fxq IMAGE_VERSION=dev12.13 /' \
        -e '/^grep -Fxq IMAGE_VERSION=/a echo "3d77058cde509e6f3256f332d4a2469d9448490ce6628001defdadd08711b5b8  /var/lib/y700/build/packages.tsv" | sha256sum --strict --quiet -c -' diagnostic.sh
    digest=$(sha256sum diagnostic.sh)
    sed -i "s/^[0-9a-f]\{64\}  diagnostic\.sh$/${digest}/" SHA256SUMS
    sha256sum --strict --quiet -c SHA256SUMS
)
find . -exec touch -h -d @1795150416 {} +
find y700-af-acm y700-af-acm-init -print0 | sort -z | cpio --null --quiet --reproducible --owner=0:0 -o -H newc > "$work/result/af-acm.cpio"
(cd "$work/result"; sha256sum af-acm.cpio > SHA256SUMS)
mv -T --no-clobber -- "$work/result" "$out"
[[ ! -e $work/result ]]
