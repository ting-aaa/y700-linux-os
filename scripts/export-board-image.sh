#!/usr/bin/env bash
# Export the exact tested files to a new private, portable directory.
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/packaging/sd-trial/dual-release.sh"
card_only=false
if [[ ${1:-} == --card-only ]]; then
    [[ $# == 5 ]] || { echo 'Usage: export-board-image.sh --card-only IMAGES NEW_DIRECTORY CARD ENTRY' >&2; exit 2; }
    card_only=true
    shift
fi
candidate=$(realpath -e "${1:?candidate directory}")
dest=$(realpath -m "${2:?new export directory}")
if (( $# == 4 )); then
    card=$(realpath -e "$3")
    entry=$(realpath -e "$4")
else
    test "$#" = 2
fi
[[ ! -e $dest && ! -L $dest ]]
work=$(mktemp -d -- "${dest%/*}/.y700-export.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
mkdir -m700 "$work/export"
cd "$candidate"
sha256sum -c SHA256SUMS
cp identity.txt "$work/export/"
if $card_only; then
    cp SHA256SUMS "$work/export/SOURCE-SHA256SUMS"
else
    cp asphalt-prc-u-boot.img SHA256SUMS "$work/export/"
    for image in root.ext4 linux-boot.fat; do
        zstd --no-asyncio -q -T2 -3 "$image" -o "$work/export/$image.zst"
        expected=$(awk -v name="$image" '$2 == name {print $1}' SHA256SUMS)
        test "$(zstd --no-asyncio -dc "$work/export/$image.zst" | sha256sum | cut -d' ' -f1)" = "$expected"
    done
fi
cd "$work/export"
if ! $card_only; then
    sha256sum asphalt-prc-u-boot.img root.ext4.zst linux-boot.fat.zst > TRANSPORT-SHA256SUMS
fi
install -m644 "$repo/tests/verify-physical-boot.sh" verify-physical-boot.sh
sha256sum identity.txt verify-physical-boot.sh > PROBE-SHA256SUMS
if [[ -n ${card:-} ]]; then
    (cd "$card" && sha256sum -c SHA256SUMS)
    members=(EFI loader SHA256SUMS)
    if $card_only; then
        root_image=$candidate/root.ext4
        entry_options=(--bounded-return)
        readme=$repo/packaging/sd-trial/README.zh_CN.md
        if mdir -b -i "$candidate/linux-boot.fat" ::/loader/entries/debian-120.conf >/dev/null 2>&1; then
            sd_release "$(mtype -i "$candidate/linux-boot.fat" ::/loader/entries/debian.conf | sed -n 's/^title Y700 \(dev[0-9.]*\) .*/\1/p')"
            grep -Fxq "$sd_esp  linux-boot.fat" "$candidate/SHA256SUMS"
            grep -Fxq "$sd_root  root.ext4" "$candidate/SHA256SUMS"
            grep -Fxq "package_digest=$sd_inventory" "$candidate/identity.txt"
            files=("EFI/$sd_name/"{kernel.efi,kernel-120.efi,board.dtb,initrd} "loader/entries/$sd_name"{,-120}.conf)
            cmp "$candidate/SHA256SUMS" "$card/SOURCE-SHA256SUMS"
            root_image=$card/card-root.ext4
            entry_options=()
            readme=$repo/packaging/sd-trial/$edition.zh_CN.md
            [[ $(stat -c %s "$root_image") == 6442450944 ]]
            debugfs -R 'cat /etc/os-release' "$root_image" 2>/dev/null | grep -Fxq "IMAGE_VERSION=$edition"
            debugfs -R 'cat /var/lib/y700/build/packages.tsv' "$root_image" 2>/dev/null |
                sha256sum | grep -Fq "$sd_ledger  -"
        else
            files=(EFI/y700-test/kernel.efi EFI/y700-test/board.dtb EFI/y700-test/initrd loader/entries/y700-test.conf)
        fi
        members=("${files[@]}" SHA256SUMS)
        for file in "${members[@]}"; do [[ -f $entry/$file && ! -L $entry/$file ]]; done
        # Derive the exact filenames and digests independently from the encoded card.
        bash "$repo/scripts/build-trial-entry.sh" "${entry_options[@]}" "$card" "$work/expected-entry"
        cmp "$entry/SHA256SUMS" "$work/expected-entry/SHA256SUMS"
        (cd "$entry" && sha256sum --strict -c SHA256SUMS)
        # Bind this export to the unpacked candidate, including its optional per-unit files.
        [[ -f $card/y700-test-card.img && -f $card/card-esp.fat && -f $root_image ]]
        cmp --silent -n 1073741824 "$card/card-esp.fat" "$card/y700-test-card.img" 0 1048576
        cmp --silent -n 6442450944 "$root_image" "$card/y700-test-card.img" 0 1074790400
    else
        (cd "$entry" && sha256sum --strict -c SHA256SUMS)
    fi
    zstd --no-asyncio -q -T2 -3 "$card/y700-test-card.img" -o y700-test-card.img.zst
    test "$(zstd --no-asyncio -dc y700-test-card.img.zst | sha256sum | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$card/SHA256SUMS")"
    cat "$card/SHA256SUMS" >> SHA256SUMS
    tar -C "$entry" -czf trial-entry.tar.gz "${members[@]}"
    tar -C "$entry" -dzf trial-entry.tar.gz
    sha256sum y700-test-card.img.zst trial-entry.tar.gz >> TRANSPORT-SHA256SUMS
    if $card_only; then
        install -m644 "$readme" README.md
        sha256sum SHA256SUMS SOURCE-SHA256SUMS PROBE-SHA256SUMS identity.txt verify-physical-boot.sh README.md >> TRANSPORT-SHA256SUMS
    fi
fi
cd "$work"
mv -T --no-clobber -- export "$dest"
test ! -e export
