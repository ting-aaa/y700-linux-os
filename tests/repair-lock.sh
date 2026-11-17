#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
source=$(realpath -e "${1:?repair archive directory}")
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT
cp "$source/"*.deb "$temp/"
verify() {
    "${UV_BIN:-uv}" run --python "${UV_PYTHON:-3.13}" --no-project python "$repo/scripts/repair-inputs.py" \
        verify "$temp" "$repo/config/desktop-repair.lock.json"
}
verify
archives=("$temp/"*.deb)
first=${archives[0]}
printf 'tamper' >> "$first"
if verify > "$temp/tamper.log" 2>&1; then
    echo 'Corrupt archive was accepted' >&2; exit 1
fi
cp "$source/$(basename "$first")" "$first"
mv "$first" "$first.missing"
if verify > "$temp/missing.log" 2>&1; then
    echo 'Missing archive was accepted' >&2; exit 1
fi
mv "$first.missing" "$first"
cp "$first" "$temp/unexpected.deb"
if verify > "$temp/extra.log" 2>&1; then
    echo 'Extra archive was accepted' >&2; exit 1
fi
rm -- "$temp/unexpected.deb"
mv "$first" "$temp/by-hash.deb"
verify
echo 'PASS: tampered, missing and extra archives rejected; renamed identical archive accepted.'
