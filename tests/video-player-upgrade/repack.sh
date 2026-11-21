#!/bin/bash
# Recreate the original transport from its verified members.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: repack.sh NEW.tar.gz' >&2; exit 2; }
out=$(realpath -m "$1")
cd "$(dirname "$0")"
top=$(pwd -P)
case $out in "$top"/*) echo 'Write the new TAR outside the extracted archive' >&2; exit 2 ;; esac
[[ ! -e $out && ! -L $out ]]
mkdir -p "$(dirname "$out")"
sha256sum --quiet --strict -c SHA256SUMS
[[ -z $(find . ! -type d ! -type f -print -quit) ]]
[[ -z $(find . -type d -empty -print -quit) ]]
# Refuse unrelated files before adding the verified tree to the archive.
find . -type f ! -path ./SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | cmp SHA256SUMS -
tmp=$(mktemp "$(dirname "$out")/.parole-update.XXXXXXXX")
trap 'rm -f -- "$tmp"' EXIT
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode='u=rwX,go=rX' \
    --transform='s,^\.,y700-player-update,' -cf - . | gzip -n > "$tmp"
chmod 644 "$tmp"
ln "$tmp" "$out"
sha256sum "$out"
