#!/usr/bin/env bash
# Produce just the supplementary files for the existing working UFS ESP.
# The caller supplies a NEW host directory. Deployment is a separate operation.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
bounded=0
if [[ ${1:-} == --bounded-return ]]; then bounded=1; shift; fi
[[ $# == 2 ]]
card=$(realpath -e "${1:?test-card build directory}")
out=$(realpath -m "${2:?new host overlay directory}")
mkdir -m700 -- "$out"
cd "$card"
sha256sum -c SHA256SUMS
mkdir -p "$out/EFI/y700-test" "$out/loader/entries"
for name in kernel.efi board.dtb initrd; do
    mcopy -i y700-test-card.img@@1048576 "::/EFI/debian/$name" "$out/EFI/y700-test/$name"
done
mtype -i y700-test-card.img@@1048576 ::/loader/entries/debian.conf | tr -d '\r' | \
    sed -e 's|^title .*|title Y700 candidate (microSD)|' -e 's|/EFI/debian/|/EFI/y700-test/|g' > "$out/loader/entries/y700-test.conf"
grep -q 'y700.media=sd' "$out/loader/entries/y700-test.conf"
if (( bounded )); then
    entry="$out/loader/entries/y700-test.conf"
    grep -Eq '^options rdinit=/init root=PARTLABEL=y700-test-root y700.media=sd ' "$entry"
    if grep -Eq '( |^)panic=' "$entry"; then echo 'Conflicting panic option' >&2; exit 1; fi
    bash "$repo/scripts/add-sd-trial-return.sh" "$out/EFI/y700-test/initrd" "$out/EFI/y700-test/bounded-initrd"
    mv -T -- "$out/EFI/y700-test/bounded-initrd" "$out/EFI/y700-test/initrd"
    sed -i '/^options /{ s| rdinit=/init | rdinit=/y700-sd-trial-init |; s/$/ panic=15/; }' "$entry"
fi
cd "$out"
sha256sum EFI/y700-test/{kernel.efi,board.dtb,initrd} loader/entries/y700-test.conf > SHA256SUMS
