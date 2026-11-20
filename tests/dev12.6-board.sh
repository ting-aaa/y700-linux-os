#!/usr/bin/env bash
# Test the delivered TAR and a synthetic per-device copy, as an ordinary Linux user.
set -euo pipefail
export LC_ALL=C
umask 077
if [[ $# != 2 || $EUID == 0 || ! $2 =~ ^[0-9a-f]{64}$ ]]; then
    echo 'Usage (ordinary user): dev12.6-board.sh DELIVERY_DIRECTORY EXPECTED_TAR_SHA256' >&2
    exit 2
fi
source_dir=$(realpath -e -- "$1")
bundle=y700-tb320fc-prc-debian-dev12.6
work=$(mktemp -d -- "${TMPDIR:-/tmp}/y700-dev12.6-extract.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
cd -- "$work"
cp -- "$source_dir/$bundle.tar" "$source_dir/SHA256SUMS" .
printf '%s  %s.tar\n' "$2" "$bundle" | cmp -s -- - SHA256SUMS
sha256sum --strict -c SHA256SUMS
tar -xf "$bundle.tar"
bash "$bundle/unpack.sh" --verify
bash "$bundle/unpack.sh" generic
cd generic
sha256sum --strict -c SHA256SUMS
sha256sum --strict -c - <<'RAW'
f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8  asphalt-prc-u-boot.img
495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6  linux-boot.fat
74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd  root.ext4
RAW
e2fsck -fn root.ext4
fsck.fat -n linux-boot.fat
test ! -e UNPERSONALIZED-SHA256SUMS
mkdir ../db
debugfs -R 'dump /var/lib/dpkg/status ../db/status' root.ext4 >/dev/null 2>&1
dpkg-query --admindir=../db -W '-f=${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
    sed -n 's/^installed\t//p' | sort > ../packages.tsv
test "$(wc -l < ../packages.tsv)" == 1115
package_sha=a5f46346523f60efb2545e290d209372daa983b094e42c37e7ced2cdb97b3d98
printf '%s  ../packages.tsv\n' "$package_sha" | sha256sum --strict -c -
grep -Fxq 'package_count=1115' identity.txt
grep -Fxq "package_digest=$package_sha" identity.txt
cd ..
mkdir private
cat > private/props <<'PROPS'
[ro.product.vendor.model]: [TB320FC]
[ro.product.vendor.device]: [TB320FC]
[ro.odm.lenovo.btaddr]: [02:BC:34:00:45:66]
[persist.vendor.service.bdroid.bdaddr]: [02:BC:34:00:45:66]
PROPS
uv run --offline --no-project --python /usr/bin/python3 python "$bundle/prepare-bluetooth-identity.py" \
    --getprop private/props --output private/address
bash "$bundle/unpack.sh" --bluetooth-address private/address personal
cd personal
sha256sum --strict -c SHA256SUMS
cmp -- UNPERSONALIZED-SHA256SUMS ../generic/SHA256SUMS
for file in asphalt-prc-u-boot.img linux-boot.fat identity.txt; do cmp -- "$file" "../generic/$file"; done
debugfs -R 'dump /etc/y700/bluetooth-address ../private/readback' root.ext4 >/dev/null 2>&1
cmp -- ../private/readback ../private/address
debugfs -R 'stat /etc/y700/bluetooth-address' root.ext4 2>/dev/null > ../inode
grep -Eq '^Inode: .*Type: regular .*Mode: +0600' ../inode
grep -Eq '^User: +0 +Group: +0 .*Size: 18$' ../inode
e2fsck -fn root.ext4
printf 'DEV12P6_BOARD_PASS uid=%s archive=%s raw=3 packages=1115 ext4=2 fat=1 bluetooth=synthetic\n' "$EUID" "$2"
