#!/usr/bin/env bash
# Append-only diagnostic attachment. Existing RAM bundle files are opened read-only.
set -euo pipefail
umask 077
[[ $# == 4 ]] || { echo 'Usage: build.sh SEALED_RAM_BUNDLE Y700_AF_MEASURE DIAGNOSTIC_LIB NEW_DIR' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd -P)
base=$(realpath -e "$1"); tool=$(realpath -e "$2"); library=$(realpath -e "$3"); out=$(realpath -m "$4")
[[ ! -e $out && ! -L $out ]]
echo "2cdddecb410b4aa3d9b63b229fc8df5fc8de61b00ed3a209a34c633d82adb453  $base/SHA256SUMS" | sha256sum --strict -c -
(cd "$base"; sha256sum --strict -c SHA256SUMS)
printf '%s  %s\n' \
    472008d206303c671233deb556570a5e2a8760959d53349dd8e028930372eecc "$tool" \
    6521ee7a227580b1108e1643f9c5889be6a9f6fdfedd73833cfab0a42ed971ce "$library" \
    df565cb8108acb42c0d2912c1b1a7786e2bebf9fe71c8900e5ed7168f22b66bc "$here/../camera-lens-graph/measure-board.sh" | sha256sum --strict -c -
w=$(mktemp -d "${out%/*}/.y700-ram-af.XXXXXXXX"); trap 'rm -r --one-file-system -- "$w"' EXIT
mkdir -p "$w/tree/y700-af-acm" "$w/result"
tail -c +11637349 "$base/initrd" | cpio --quiet -i --to-stdout y700-ram-trial-init > "$w/base-init"
echo "d8abb55835640662d315deda35dbfc0ccee5e338680981b1350ac17b2ab5e322  $w/base-init" | sha256sum --strict -c -
awk -v hook="$here/install-in-overlay" '
    /^for fs in dev proc sys run; do$/ { count++; while ((getline line < hook) > 0) print line; close(hook) }
    {print}
    END { exit count != 1 }
' "$w/base-init" > "$w/tree/y700-af-acm-init"
chmod 755 "$w/tree/y700-af-acm-init" "$w/tree/y700-af-acm"
sh -n "$w/tree/y700-af-acm-init"
install -m755 "$tool" "$w/tree/y700-af-acm/y700-af-measure"
install -m755 "$here/../camera-lens-graph/measure-board.sh" "$here/diagnostic.sh" "$here/filter.sh" "$w/tree/y700-af-acm/"
install -m644 "$library" "$w/tree/y700-af-acm/libcamera.so.0.7"
install -m644 "$here/diagnostic.service" "$w/tree/y700-af-acm/"
(cd "$w/tree/y700-af-acm"; sha256sum diagnostic.service diagnostic.sh filter.sh libcamera.so.0.7 measure-board.sh y700-af-measure > SHA256SUMS)
find "$w/tree" -exec touch -d @1795150416 {} +
(cd "$w/tree"; find y700-af-acm y700-af-acm-init -print0 | LC_ALL=C sort -z | cpio --null --quiet -o -H newc --reproducible --owner=0:0) > "$w/result/af-acm.cpio"
sed 's,^rdinit=/y700-ram-trial-init ,rdinit=/y700-af-acm-init y700.ram_af_acm=1 ,' "$base/cmdline.txt" > "$w/result/cmdline.txt"
grep -q '^rdinit=/y700-af-acm-init y700.ram_af_acm=1 ' "$w/result/cmdline.txt"
(cd "$w/result"; sha256sum af-acm.cpio cmdline.txt > SHA256SUMS; sha256sum --strict -c SHA256SUMS)
mv -T --no-clobber -- "$w/result" "$out"; [[ ! -e $w/result ]]
