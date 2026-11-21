#!/usr/bin/env bash
# Package the verified root transition without redistributing the dev12.13 archive.
set -euo pipefail
umask 077
export LC_ALL=C
[[ $# == 4 ]] || { echo 'Usage: package-browser-camera-release.sh DEV12.13.tar DEV12.13_ROOT DEV12.14_ROOT NEW_DIRECTORY' >&2; exit 2; }
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
archive=$(realpath -e -- "$1"); base=$(realpath -e -- "$2"); root=$(realpath -e -- "$3")
parent=$(cd -- "$(dirname -- "$4")" && pwd -P)
dest=$parent/$(basename -- "$4")
[[ ! -e $dest && ! -L $dest ]]
source "$repo/scripts/build-storage-guard.sh" archive "$parent" reserve 32
basehash=6155d87d5d5b9d5557e86362f09fb17328aef200861e94eb292a669c35659c7c
roothash=32896d21a07a1c9529db3d007df788bb8ddcf4e5b6b0782527737ac7af1a3259
printf '%s  %s\n' 60fc1e12b2ad707270bf722d90e72e32c030ae377a50a37130ecd4336aac1fb6 "$archive" "$basehash" "$base" "$roothash" "$root" | sha256sum --strict -c -
name=y700-tb320fc-prc-debian-dev12.14
prior=y700-tb320fc-prc-debian-dev12.13
work=$(mktemp -d "$parent/.y700-browser-release.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
cd "$work"; mkdir "$name" result
xdelta3 -3 -A -e -s "$base" "$root" "$name/root.vcdiff"
restored=$(xdelta3 -d -c -s "$base" "$name/root.vcdiff" | sha256sum)
[[ ${restored%% *} == "$roothash" ]]
tar -xOf "$archive" "$prior/base/identity.txt" > original-identity
grep -Fxq 'package_digest=5f991636f274f7d21c38f4eaf4e119d6491a1c7c901fdb818518548333574098' original-identity
sed 's/^package_digest=.*/package_digest=a652f024df73eb7386043cf11fa3fde1a1eb81a9f78a572c7bce808b0f1979fb/' original-identity > "$name/identity.txt"
tar -xOf "$archive" "$prior/unpack.sh" | sed -n '/^read_private_address() {/,/^bundle=/{ /^bundle=/!p; }' > "$name/bluetooth.sh"
for fn in read_private_address debugfs_output personalize_root; do grep -Fxq "$fn() {" "$name/bluetooth.sh"; done
bash -n "$name/bluetooth.sh"
debugfs -R 'cat /var/lib/y700/build/packages.tsv' "$root" 2>/dev/null > native-ledger
echo 'f1689b582a6065355a63313745b8eded6ba190153eec081ee93cc6a78610f831  native-ledger' | sha256sum --strict -c -
awk -F'\t' 'BEGIN{OFS="\t"}{sub(/:[^:]+$/, "", $1);print $1,$2,$3}' native-ledger | sort > result/packages.tsv
echo 'a652f024df73eb7386043cf11fa3fde1a1eb81a9f78a572c7bce808b0f1979fb  result/packages.tsv' | sha256sum --strict -c -
install -m644 "$repo/scripts/unpack-browser-camera-release.sh" "$name/unpack.sh"
install -m644 "$repo/scripts/build-storage-guard.sh" "$name/"
install -m644 "$repo/docs/DEV12.14-IMAGE.md" "$name/README.md"
install -m644 result/packages.tsv "$name/"
(
 cd "$name"
 printf '%s  %s\n' f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8 asphalt-prc-u-boot.img cdd0e35bf0d0cd859f521bf74fafa594388ea3093c33ea81c189da56cb3dea0d linux-boot.fat "$roothash" root.ext4 > RAW-SHA256SUMS
 sha256sum identity.txt >> RAW-SHA256SUMS
 sha256sum README.md RAW-SHA256SUMS bluetooth.sh build-storage-guard.sh identity.txt packages.tsv root.vcdiff unpack.sh > SHA256SUMS
)
tar --sort=name --format=ustar --mtime=@1795046400 --owner=0 --group=0 --numeric-owner --mode='u=rwX,go=rX' -cf "result/$name.tar" "$name"
(cd result; sha256sum "$name.tar" packages.tsv > SHA256SUMS)
mv -T --no-clobber result "$dest"
[[ ! -e result ]]
