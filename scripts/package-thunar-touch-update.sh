#!/bin/bash
set -euo pipefail
export LC_ALL=C
[[ $# == 2 ]] || { echo 'Usage: package-thunar-touch-update.sh DEBS OUTPUT.tar' >&2; exit 2; }
repo=$(cd "$(dirname "$0")/.." && pwd -P)
debs=$(realpath -e "$1")
out=$(realpath -m "$2")
[[ -d $debs && -d ${out%/*} && ! -L $2 && ! -L $out.sha256 ]]
w=$(mktemp -d "${out%/*}/.thunar-update.XXXXXXXX")
trap 'rm -r --one-file-system -- "$w"' EXIT
dir=$w/thunar-update
mkdir "$dir"
for ver in 4.20.2-1+deb13u1{,+y7001}; do
    name=thunar_${ver}_arm64.deb
    [[ -f $debs/$name && ! -L $debs/$name ]]
    install -m644 "$debs/$name" "$dir/$name"
done
install -m755 "$repo/scripts/update-thunar-touch.sh" "$dir/"
install -m644 "$repo/tests/thunar-touch-update/README.md" "$dir/"
install -d -m755 "$dir/source"
install -m755 "$repo/packaging/thunar-touch/build.sh" "$dir/source/"
install -m644 "$repo/packaging/thunar-touch/direct-touch.patch" "$dir/source/"
printf '%s  %s\n' \
    d6d061934d90e2e9f3e94ac97d66da880066b0c6ff1005943b60cf55cd1e387d "$dir/source/build.sh" \
    cec046736ada63000f3cc2c8158d32a9e5563a5d9f4f4d7a98e738feb4a6c0f8 "$dir/source/direct-touch.patch" |
    sha256sum --strict --quiet -c -
bash "$dir/update-thunar-touch.sh" verify-archives
(cd "$dir"; sha256sum -- *.deb *.sh README.md source/* > SHA256SUMS)
opts=(--format=ustar --mtime=@1795219200 --owner=0 --group=0 --numeric-owner)
cd "$w"
tar "${opts[@]}" --no-recursion --mode=0755 -cf offline.tar thunar-update thunar-update/source
tar "${opts[@]}" --mode=0644 -rf offline.tar thunar-update/SHA256SUMS thunar-update/README.md thunar-update/*.deb thunar-update/source/direct-touch.patch
tar "${opts[@]}" --mode=0755 -rf offline.tar thunar-update/update-thunar-touch.sh thunar-update/source/build.sh
publish() {
    if ! ln -T -- "$1" "$2" 2>/dev/null; then
        [[ -f $2 && ! -L $2 ]] && cmp -- "$1" "$2"
    fi
}
publish offline.tar "$out"
(cd "${out%/*}"; sha256sum -- "${out##*/}") > offline.sha256
publish offline.sha256 "$out.sha256"
cat offline.sha256
