#!/bin/bash
# Combine only the package members of the three previously published releases.
set -euo pipefail
export LC_ALL=C
umask 022
[[ $# == 4 ]] || { echo 'Usage: package-desktop-update.sh QCAM.tar BLUEMAN.tar IBUS.tar OUTPUT.tar' >&2; exit 2; }
repo=$(cd "$(dirname "$0")/.." && pwd -P)
qcam=$(realpath -e "$1")
blueman=$(realpath -e "$2")
ibus=$(realpath -e "$3")
output=$(realpath -m "$4")
[[ -d ${output%/*} && ! -L $4 && ! -L $output.sha256 ]]
printf '%s  %s\n' \
    e582e3335242c54bdb08e5bde6f71524d19374caf5b8d1c75b17db95e2230964 "$qcam" \
    3812a03a819b8ef0757e543d21fba4b4a0cc1383c79c6b763d7eb6827c91f48e "$blueman" \
    3126fddabe8c964d05d1fedf0d29886ed028a7036eb975b59f5051188c92edc9 "$ibus" | sha256sum --strict --quiet -c -
work=$(mktemp -d "${output%/*}/.desktop-update.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
cd "$work"
mkdir desktop-update
extract_pair() {
    local source=$1 prefix=$2 manifest=$3 digest name
    tar -xOf "$source" "$prefix$manifest" | awk '$2 ~ /[.]deb$/ {print}' > pair
    [[ $(wc -l < pair) == 2 ]]
    while read -r digest name; do
        [[ $digest =~ ^[0-9a-f]{64}$ && $name =~ ^[a-z0-9.+~-]+_[a-z0-9.+~-]+_arm64[.]deb$ ]]
        [[ ! -e desktop-update/$name ]]
        tar -xOf "$source" "$prefix$name" >"desktop-update/$name"
    done < pair
    cat pair >> packages
}
extract_pair "$qcam" '' PACKAGES.sha256
extract_pair "$blueman" blueman-update/ SHA256SUMS
extract_pair "$ibus" '' SHA256SUMS
sort -k2 packages > desktop-update/SHA256SUMS
(cd desktop-update && sha256sum --strict --quiet -c SHA256SUMS)
install -m755 "$repo/scripts/update-desktop-packages.sh" desktop-update/update.sh
opts=(--format=ustar --mtime=@1795219200 --owner=0 --group=0 --numeric-owner)
tar "${opts[@]}" --no-recursion --mode=0755 -cf bundle.tar desktop-update
tar "${opts[@]}" --mode=0644 -rf bundle.tar desktop-update/SHA256SUMS desktop-update/*.deb
tar "${opts[@]}" --mode=0755 -rf bundle.tar desktop-update/update.sh
if [[ -e $output ]]; then cmp -- bundle.tar "$output"; else ln -- bundle.tar "$output"; fi
(cd "${output%/*}" && sha256sum -- "${output##*/}") >bundle.sha256
if [[ -e $output.sha256 ]]; then cmp -- bundle.sha256 "$output.sha256"; else ln -- bundle.sha256 "$output.sha256"; fi
cat bundle.sha256
