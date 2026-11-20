#!/usr/bin/env bash
# Package the approved raw U-Boot, final EFI system partition and generic root for TB320FC_PRC.
set -euo pipefail
umask 077
export LC_ALL=C
if [[ $# != 7 ]]; then
    echo 'Usage: package-board-image.sh VERSION ROOT.ext4 EXPECTED_ROOT_SHA256 EFI.fat EXPECTED_EFI_SHA256 UBOOT.img NEW_DIRECTORY' >&2
    exit 2
fi
version=$1
shift
case $version in
    dev12.5)
        package_count=1112
        package_sha=ae129edd690fcd72820e3c286c6010474a70cefea622d53f4fe88b53f94afb21
        ;;
    dev12.6)
        package_count=1115
        package_sha=a5f46346523f60efb2545e290d209372daa983b094e42c37e7ced2cdb97b3d98
        ;;
    dev12.7)
        package_count=1124
        package_sha=bbb696086ce1bb4a425dbf63876f12548e7e6a6048ed89415e64cb6a793eba6a
        ;;
    *) echo "Unsupported board image version: $version" >&2; exit 2 ;;
esac
epoch=${SOURCE_DATE_EPOCH:-1795132800}
[[ $epoch =~ ^[0-9]+$ ]]
guide=DEV${version#dev}-IMAGE.md
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
root=$(realpath -e -- "$1")
esp=$(realpath -e -- "$3")
boot=$(realpath -e -- "$5")
dest=$(realpath -m -- "$6")
[[ $2 =~ ^[0-9a-f]{64}$ && $4 =~ ^[0-9a-f]{64}$ ]]
[[ -f $root && -f $esp && -f $boot && ! -e $dest && ! -L $dest && -d ${dest%/*} ]]
[[ $(stat -c %s "$root") == 6442450944 && $(stat -c %s "$esp") == 1073741824 && $(stat -c %s "$boot") == 41406464 ]]
boot_sha=f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8
printf '%s  %s\n' "$2" "$root" "$4" "$esp" "$boot_sha" "$boot" | sha256sum --strict -c -
e2fsck -fn "$root"
fsck.fat -n "$esp"
work=$(mktemp -d -- "${dest%/*}/.y700-$version-pack.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
name=y700-tb320fc-prc-debian-$version
bundle=$work/$name
base=$bundle/base
mkdir -- "$bundle" "$base" "$work/db" "$work/result"
cd "$work/db"
debugfs -R 'dump /var/lib/dpkg/status status' "$root" >/dev/null 2>&1
dpkg-query --admindir=. -W '-f=${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
    sed -n 's/^installed\t//p' | sort > packages.tsv
[[ $(wc -l < packages.tsv) == "$package_count" ]]
printf '%s  packages.tsv\n' "$package_sha" | sha256sum --strict -c -
[[ $(debugfs -R 'cat /etc/y700/image-id' "$root" 2>/dev/null) == y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f ]]
[[ $(blkid -p -o value -s UUID "$root") == 171a4adb-916b-4763-9e6f-722b4a99988f ]]
debugfs -R 'dump /etc/machine-id machine-id' "$root" >/dev/null 2>&1
[[ -f machine-id && ! -s machine-id ]]
for file in /etc/y700/bluetooth-address /etc/y700/user-configured /var/lib/y700-ssc/registry; do
    message=$(debugfs -R "stat $file" "$root" 2>&1 | tail -1)
    [[ ${message% } == "$file: File not found by ext2_lookup" ]]
done
debugfs -R 'cat /etc/shadow' "$root" 2>/dev/null | awk -F: '$1=="y700"{locked=($2 ~ /^[!*]/)} END{exit !locked}'
cat > "$base/identity.txt" <<EOF
image_id=y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f
root_uuid=171a4adb-916b-4763-9e6f-722b4a99988f
package_count=$package_count
package_digest=$package_sha
kernel_notes_sha256=c9fbc259802dfc4570c14df56043d37f1c08e9769341de3d7cde08f9be6f1564
fbdev_emulation=0
EOF
cd "$base"
zstd -q -T2 -3 "$boot" -o asphalt-prc-u-boot.img.zst
zstd -q -T2 -3 "$esp" -o linux-boot.fat.zst
zstd -q -T2 -3 "$root" -o root.ext4.zst
if [[ $version != dev12.5 ]]; then
    # zstd inherits input permissions, which can differ between verified copies.
    chmod 600 -- *.zst
fi
{
    printf '%s  %s\n' "$boot_sha" asphalt-prc-u-boot.img "$4" linux-boot.fat "$2" root.ext4
    sha256sum identity.txt
} > RAW-SHA256SUMS
sha256sum asphalt-prc-u-boot.img.zst linux-boot.fat.zst root.ext4.zst identity.txt RAW-SHA256SUMS > SHA256SUMS
install -m755 "$repo/scripts/unpack-kms-image.sh" unpack.sh
cd "$bundle"
install -m755 "$repo/scripts/unpack-kms-update.sh" unpack.sh
install -m644 "$repo/scripts/prepare-bluetooth-identity.py" .
install -m644 "$repo/docs/$guide" README.md
sha256sum base/SHA256SUMS base/unpack.sh unpack.sh prepare-bluetooth-identity.py README.md > SHA256SUMS
bash unpack.sh --verify
# The payloads already use Zstandard. The outer tar keeps the full distribution in one file.
cd "$work/result"
tar --sort=name --format=gnu --owner=0 --group=0 --numeric-owner --mtime="@$epoch" \
    -cf "$name.tar" -C "$work" "$name"
sha256sum "$name.tar" > SHA256SUMS
cd "$work"
mv -T --no-clobber -- result "$dest"
[[ ! -e result ]]
cat "$dest/SHA256SUMS"
