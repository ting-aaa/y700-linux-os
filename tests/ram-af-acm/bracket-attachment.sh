#!/usr/bin/env bash
# Append only the bracket files and revised service to the verified signal receiver.
set -euo pipefail
export LC_ALL=C
umask 077
[[ $# == 3 ]] || { echo 'Usage: bracket-attachment.sh SEALED_SIGNAL_RECEIVER BRACKET_ARTIFACTS NEW_DIRECTORY' >&2; exit 2; }
here=$(dirname "$(realpath "$0")")
base=$(realpath -e "$1"); artifacts=$(realpath -e "$2"); out=$(realpath -m "$3")
parent=$(dirname "$out")
[[ -d $parent && ! -e $out && ! -L $out && $(stat -c %d "$base") == "$(stat -c %d "$parent")" ]]
check() { printf '%s  %s\n' "$1" "$2" | sha256sum --strict --quiet -c -; }
check 8e66df7f74fcc357bcf4035f5145d26d1c4c076352689664e27bdaa9665b9405 "$base/SHA256SUMS"
check 7cb1175f64c66f22c782087fd8b2d566bde156ccd7790697db1ebc7871b2e525 "$artifacts/SHA256SUMS"
(cd "$base"; sha256sum --strict --quiet -c SHA256SUMS)
(cd "$artifacts"; sha256sum --strict --quiet -c SHA256SUMS)
work=$(mktemp -d -- "$parent/.bracket-receiver.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
mkdir "$work/tree" "$work/bundle"
cd "$work/tree"
tail -c +11842149 "$base/initrd" | cpio --quiet -id --no-absolute-filenames
cd y700-af-acm
sha256sum --strict --quiet -c SHA256SUMS
patch --batch --forward --fuzz=0 -p1 < "$here/bracket-service.patch"
bash -n diagnostic.sh; bash -n measure-board.sh
mapfile -t original < <(cut -c67- SHA256SUMS)
new=(y700-bracket-measure ipa_bracket.so bracket-test bracket_receipt.py)
install -m755 "$artifacts/y700-bracket-measure" "$artifacts/bracket-test" .
install -m644 "$artifacts/ipa_bracket.so" "$here/bracket_receipt.py" .
sha256sum "${original[@]}" "${new[@]}" > SHA256SUMS
sha256sum --strict --quiet -c SHA256SUMS
cd ..
members=(y700-af-acm/{SHA256SUMS,diagnostic.sh,measure-board.sh} "${new[@]/#/y700-af-acm/}")
touch -h -d @1795150416 "${members[@]}"
bundle=$work/bundle
cp -- "$base/initrd" "$bundle/initrd"
chmod u+w "$bundle/initrd"
printf '%s\0' "${members[@]}" | sort -z | cpio --null --quiet --reproducible --owner=0:0 -o -H newc >> "$bundle/initrd"
for name in kernel.efi board.dtb cmdline.txt carrier.squashfs; do ln -- "$base/$name" "$bundle/$name"; done
(cd "$bundle"; sha256sum kernel.efi board.dtb initrd cmdline.txt carrier.squashfs > SHA256SUMS)
if (( EUID == 0 )); then
    for name in . initrd SHA256SUMS; do
        chown --reference="$base/$name" "$bundle/$name"
        chmod --reference="$base/$name" "$bundle/$name"
    done
fi
mv -Tn -- "$bundle" "$out"; [[ ! -e $bundle ]]
sha256sum "$out/SHA256SUMS" "$out/initrd"
