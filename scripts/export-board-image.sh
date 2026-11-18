#!/usr/bin/env bash
# Export the exact tested files to a new private, portable directory.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
candidate=$(realpath -e "${1:?candidate directory}")
dest=$(realpath -m "${2:?new export directory}")
if (( $# == 4 )); then
    card=$(realpath -e "$3")
    entry=$(realpath -e "$4")
else
    test "$#" = 2
fi
mkdir -m700 "$dest"
cd "$candidate"
sha256sum -c SHA256SUMS
cp asphalt-prc-u-boot.img SHA256SUMS identity.txt "$dest/"
for image in root.ext4 linux-boot.fat; do
    zstd --no-asyncio -q -T2 -3 "$image" -o "$dest/$image.zst"
    expected=$(awk -v name="$image" '$2 == name {print $1}' SHA256SUMS)
    test "$(zstd --no-asyncio -dc "$dest/$image.zst" | sha256sum | cut -d' ' -f1)" = "$expected"
done
cd "$dest"
sha256sum asphalt-prc-u-boot.img root.ext4.zst linux-boot.fat.zst > TRANSPORT-SHA256SUMS
install -m644 "$repo/tests/verify-physical-boot.sh" verify-physical-boot.sh
sha256sum identity.txt verify-physical-boot.sh > PROBE-SHA256SUMS
if [[ -n ${card:-} ]]; then
    (cd "$card" && sha256sum -c SHA256SUMS)
    (cd "$entry" && sha256sum -c SHA256SUMS)
    zstd --no-asyncio -q -T2 -3 "$card/y700-test-card.img" -o y700-test-card.img.zst
    test "$(zstd --no-asyncio -dc y700-test-card.img.zst | sha256sum | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$card/SHA256SUMS")"
    cat "$card/SHA256SUMS" >> SHA256SUMS
    tar -C "$entry" -czf trial-entry.tar.gz EFI loader SHA256SUMS
    tar -C "$entry" -dzf trial-entry.tar.gz
    sha256sum y700-test-card.img.zst trial-entry.tar.gz >> TRANSPORT-SHA256SUMS
fi
