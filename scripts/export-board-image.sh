#!/usr/bin/env bash
# Export the exact tested files to a new private, portable directory.
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd)
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
        files=(EFI/y700-test/kernel.efi EFI/y700-test/board.dtb EFI/y700-test/initrd loader/entries/y700-test.conf)
        members=("${files[@]}" SHA256SUMS)
        for file in "${members[@]}"; do [[ -f $entry/$file && ! -L $entry/$file ]]; done
        (cd "$entry" && sha256sum "${files[@]}") | cmp - "$entry/SHA256SUMS"
        # Rebuild from the encoded card so all four supplied files match this release.
        bash "$repo/scripts/build-trial-entry.sh" --bounded-return "$card" "$work/expected-entry"
        cmp --silent "$entry/SHA256SUMS" "$work/expected-entry/SHA256SUMS" || {
            echo 'Build the trial entry with --bounded-return from this card' >&2; exit 1;
        }
        # Bind this export to the unpacked candidate, including its optional per-unit files.
        [[ -f $card/y700-test-card.img && -f $card/card-esp.fat && -f $candidate/root.ext4 ]]
        cmp --silent -n 1073741824 "$card/card-esp.fat" "$card/y700-test-card.img" 0 1048576
        cmp --silent -n 6442450944 "$candidate/root.ext4" "$card/y700-test-card.img" 0 1074790400
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
        install -m644 "$repo/packaging/sd-trial/README.zh_CN.md" README.md
        sha256sum SHA256SUMS SOURCE-SHA256SUMS PROBE-SHA256SUMS identity.txt verify-physical-boot.sh README.md >> TRANSPORT-SHA256SUMS
    fi
fi
cd "$work"
mv -T --no-clobber -- export "$dest"
test ! -e export
