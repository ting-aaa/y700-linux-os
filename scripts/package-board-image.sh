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
guide=DEV${version#dev}-IMAGE.md
notes_sha=c9fbc259802dfc4570c14df56043d37f1c08e9769341de3d7cde08f9be6f1564
player_esp=495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6
player_ledger=5e820094693eca3db71affff0a7845f489c60ed5d556b76d62664c1b3b325dce
has_player=false
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
    dev12.8)
        package_count=1124
        package_sha=a1a2498f80dc382dde6db1f3e0282193c10b78110089ea0db8ae002b1c3abb84
        guide=ADAPTIVE-BRIGHTNESS-IMAGE.md
        ;;
    dev12.9)
        has_player=true
        package_count=1240
        package_sha=89aa7038cac0d6591b9977608f137e1412bebdd52f6125ac2521d882f8633d1d
        ;;
    dev12.10)
        has_player=true
        package_count=1240
        package_sha=ffb8818f1fd41efb3b7c7a14782abd62b37bf5dd687cfaa923d3419d785f51c3
        ;;
    dev12.11)
        has_player=true
        package_count=1240
        package_sha=be0f181db24f72e2166b418e7b4e38999a672ffc89cb735a5afb7fd9a931941d
        player_esp=92d47c14c4606d106ebad21ece8f5e23f244bd5aecea0c377bbe8966f8261b36
        player_ledger=17473ab98cdf1190d573276bba00ceca7e0cee05688b8b496de37df8fc600d82
        notes_sha=35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6
        ;;
    dev12.12)
        has_player=true
        package_count=1240
        package_sha=ef9dea42fb4990e05025bdaa9ac6aac8b0f49e48f14cd57a4ff13d0207e08047
        player_esp=1f6d75c17b5f38ff69d57e13c671bd0c1cbccf0c74cf1ea3f79e2011445ed091
        player_ledger=5fa586a125d52580771c923bec05985e32906be36acf1b88dec29e5791b89ccd
        notes_sha=c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063
        ;;
    dev12.13)
        has_player=true
        package_count=1241
        package_sha=5f991636f274f7d21c38f4eaf4e119d6491a1c7c901fdb818518548333574098
        player_esp=cdd0e35bf0d0cd859f521bf74fafa594388ea3093c33ea81c189da56cb3dea0d
        player_ledger=3d77058cde509e6f3256f332d4a2469d9448490ce6628001defdadd08711b5b8
        notes_sha=c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063
        ;;
    *) echo "Unsupported board image version: $version" >&2; exit 2 ;;
esac
epoch=${SOURCE_DATE_EPOCH:-1795132800}
[[ $epoch =~ ^[0-9]+$ ]]
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
root=$(realpath -e -- "$1")
esp=$(realpath -e -- "$3")
boot=$(realpath -e -- "$5")
dest=$(realpath -m -- "$6")
[[ $2 =~ ^[0-9a-f]{64}$ && $4 =~ ^[0-9a-f]{64}$ ]]
[[ -f $root && -f $esp && -f $boot && ! -e $dest && ! -L $dest && -d ${dest%/*} ]]
[[ $(stat -c %s "$root") == 6442450944 && $(stat -c %s "$esp") == 1073741824 && $(stat -c %s "$boot") == 41406464 ]]
source "$repo/scripts/build-storage-guard.sh" release "${dest%/*}"
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
if [[ $version == dev12.8 ]] || $has_player; then
    debugfs -R 'dump /var/lib/y700/build/platform.lock.json platform.lock.json' "$root" >/dev/null 2>&1
    cmp "$repo/config/platform.lock.json" platform.lock.json
fi
if $has_player; then
    [[ $4 == "$player_esp" ]]
    original_lock=video-player.lock.json
    if [[ $version != dev12.9 ]]; then original_lock=video-player-dev12.9.lock.json; fi
    debugfs -R "dump /var/lib/y700/build/$original_lock media.lock" "$root" >/dev/null 2>&1
    debugfs -R 'dump /var/lib/y700/build/video-player-debian.lock.json media-packages.lock' "$root" >/dev/null 2>&1
    cmp "$repo/config/video-player.lock.json" media.lock
    cmp "$repo/tests/video-player/debian.lock.json" media-packages.lock
    media_locks=(media.lock)
    if [[ $version != dev12.9 ]]; then
        debugfs -R 'dump /var/lib/y700/build/video-player-update.lock.json media-update.lock' "$root" >/dev/null 2>&1
        cmp "$repo/config/video-player-update.lock.json" media-update.lock
        debugfs -R 'dump /var/lib/y700/build/video-player.lock.json media-active.lock' "$root" >/dev/null 2>&1
        cmp media-update.lock media-active.lock
        media_locks+=(media-update.lock)
        debugfs -R 'dump /var/lib/y700/build/packages.tsv recorded-packages.tsv' "$root" >/dev/null 2>&1
        printf '%s  recorded-packages.tsv\n' "$player_ledger" | sha256sum --strict -c -
    fi
    if [[ $version == dev12.11 || $version == dev12.12 || $version == dev12.13 ]]; then
        for layer in camera-autofocus wifi-sae-update; do
            debugfs -R "dump /var/lib/y700/build/$layer.lock.json $layer.lock" "$root" >/dev/null 2>&1
            cmp "$repo/config/$layer.lock.json" "$layer.lock"
        done
        debugfs -R 'dump /etc/os-release image-os-release' "$root" >/dev/null 2>&1
        grep -Fxq "IMAGE_VERSION=$version" image-os-release
        grep -Fxq IMAGE_ID=y700-prc-debian image-os-release
        media_locks+=(camera-autofocus.lock)
    fi
    if [[ $version == dev12.12 || $version == dev12.13 ]]; then
        debugfs -R 'dump /var/lib/y700/build/platform-desktop-update.lock.json desktop-update.lock' "$root" >/dev/null 2>&1
        cmp "$repo/config/platform-desktop-update.lock.json" desktop-update.lock
        media_locks+=(desktop-update.lock)
    fi
    if [[ $version == dev12.13 ]]; then
        debugfs -R 'dump /var/lib/y700/build/tablet-desktop.lock.json tablet-desktop.lock' "$root" >/dev/null 2>&1
        cmp "$repo/config/tablet-desktop.lock.json" tablet-desktop.lock
        media_locks+=(tablet-desktop.lock)
    fi
    jq -sr 'map(.links // {}) | add | to_entries[] | [.key, .value] | @tsv' "${media_locks[@]}" > links.tsv
    while IFS=$'\t' read -r path target; do
        debugfs -R "stat /$path" "$root" 2>/dev/null | grep -Fx "Fast link dest: \"$target\"" >/dev/null
    done < links.tsv
    # The update replaces the player's private plugin while the Debian plugin,
    # desktop entry, launcher and license files retain their original locks.
    jq -ser 'map(.files) | add | to_entries[] | [.value, .key] | @tsv' "${media_locks[@]}" > media-files.tsv
    while IFS=$'\t' read -r digest path; do
        actual=$(debugfs -R "cat /$path" "$root" 2>/dev/null | sha256sum)
        [[ ${actual%% *} == "$digest" ]] || { echo "Image file mismatch: /$path" >&2; exit 1; }
    done < media-files.tsv
fi
dpkg-query --admindir=. -W '-f=${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
    sed -n 's/^installed\t//p' | sort > packages.tsv
[[ $(wc -l < packages.tsv) == "$package_count" ]]
printf '%s  packages.tsv\n' "$package_sha" | sha256sum --strict -c -
if [[ -f recorded-packages.tsv ]]; then
    # binary:Package in the guest ledger qualifies Multi-Arch:same packages.
    # The independent status query uses Package and an explicit architecture.
    sed -E 's/^([^[:space:]:]+):[^[:space:]]+\t/\1\t/' recorded-packages.tsv | sort | cmp packages.tsv -
fi
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
kernel_notes_sha256=$notes_sha
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
if $has_player; then
    install -m644 "$work/db/packages.tsv" packages.tsv
    sha256sum packages.tsv >> SHA256SUMS
fi
cd "$work"
mv -T --no-clobber -- result "$dest"
[[ ! -e result ]]
cat "$dest/SHA256SUMS"
