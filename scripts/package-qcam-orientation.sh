#!/bin/bash
# Package the orientation update with the same byte-checking installer used by its predecessor.
set -euo pipefail
export LC_ALL=C
[[ $# == 3 ]] || { echo 'Usage: package-qcam-orientation.sh PREVIOUS.deb UPDATED.deb OUTPUT.tar' >&2; exit 2; }
previous=$(realpath -e "$1")
next=$(realpath -e "$2")
output=$(realpath -m "$3")
source_dir=$(cd "$(dirname "$0")" && pwd)
prefix=y700-camera-qcam_0.7.2-1~bpo13+1
old_hash=3bfbc1bf91892b621af6a2ccf86b7ef4a137583f7edcf0e0cb40c2a2f353244f
new_hash=770adeb3b30681100b12c6fd1e877c5e4ec271e3c8420f9beae5b262e8331083
printf '%s  %s\n' "$old_hash" "$previous" "$new_hash" "$next" | sha256sum --strict --quiet -c -
[[ -d ${output%/*} && ! -L $3 ]]
work=$(mktemp -d "${output%/*}/.qcam-orientation.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
mkdir "$work/qcam-orientation"
cd "$work/qcam-orientation"
install -m644 "$previous" "${prefix}.y7007_arm64.deb"
install -m644 "$next" "${prefix}.y7008_arm64.deb"
sed -e 's/update-qcam-focus.sh/update.sh/g' \
    -e "/^prev=/s/y7005/y7007/" -e "/^next=/s/y7007/y7008/" \
    -e "/deb.*next/s/$old_hash/$new_hash/" \
    -e "/deb.*prev/s/4e79033cc61128049b32c0265b09c00a7930a1f6bb45d48f97849709cf497d56/$old_hash/" \
    "$source_dir/update-qcam-focus.sh" > update.sh
grep -Fq "$old_hash \"\$(deb \"\$prev\")\"" update.sh
grep -Fq "$new_hash \"\$(deb \"\$next\")\"" update.sh
chmod 755 update.sh
sha256sum -- *.deb update.sh > SHA256SUMS
chmod 644 SHA256SUMS
cd ..
tar --format=ustar --sort=name --mtime=@1795219200 --owner=0 --group=0 --numeric-owner \
    --mode=u=rwX,go=rX -cf bundle.tar qcam-orientation
if [[ -e $output ]]; then cmp bundle.tar "$output"; else ln -- bundle.tar "$output"; fi
sha256sum -- "$output"
