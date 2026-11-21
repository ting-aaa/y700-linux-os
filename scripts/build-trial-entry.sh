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
card_esp=y700-test-card.img@@1048576
if mdir -b -i "$card_esp" ::/loader/entries/debian-120.conf >/dev/null 2>&1; then
    name=y700-sd-12-12
    mkdir -p "$out/EFI/$name" "$out/loader/entries"
    for file in kernel.efi kernel-120.efi board.dtb initrd; do
        mcopy -i "$card_esp" "::/EFI/debian/$file" "$out/EFI/$name/$file"
    done
    for variant in '' -120; do
        source_entry=$(mtype -i "$card_esp" "::/loader/entries/debian$variant.conf" | tr -d '\r')
        expected=49a12578e3a92c39a3636c51a5fb06be932dfb915e47ac6b62794dda9b152d04
        if [[ -n $variant ]]; then expected=3de4e351392958102ac3a325d2e5f517d206ba840a1307f25d9ba23574db3dfe; fi
        [[ $(printf '%s\n' "$source_entry" | sha256sum | cut -d' ' -f1) == "$expected" ]]
        sed -e 's/^title Y700 dev12.12 /title Y700 dev12.12 microSD /' \
            -e "s|/EFI/debian/|/EFI/$name/|g" <<<"$source_entry" >"$out/loader/entries/$name$variant.conf"
    done
    cd "$out/EFI/$name"
    sha256sum --strict -c <<'HASHES'
0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60  kernel.efi
b103d0fcd65a08cadb592fbdc69c8c483a7727ef212c15e464208f5c30a1a625  kernel-120.efi
53bc719146da49baff7b975c06942892278639909e48d0f998b894220c7d05b7  board.dtb
f024ed471d61cdad1033b6c88feeeb1e57a0690874154772a391ba3924211fc4  initrd
HASHES
    cd "$out"
    sha256sum "EFI/$name/"{kernel.efi,kernel-120.efi,board.dtb,initrd} "loader/entries/$name"{,-120}.conf >SHA256SUMS
    exit
fi
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
