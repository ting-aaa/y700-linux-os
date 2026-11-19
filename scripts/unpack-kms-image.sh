#!/bin/bash
# Verify the complete compressed bundle, or unpack into a new directory.
set -euo pipefail
umask 077
usage() { echo "Usage: bash $0 --verify | NEW_DIRECTORY" >&2; exit 2; }
(( $# == 1 )) || usage
case $1 in --verify) verify_only=true ;; -*) usage ;; *) verify_only=false ;; esac
bundle=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
files=(asphalt-prc-u-boot.img linux-boot.fat root.ext4)
sizes=(41406464 1073741824 6442450944)
check_manifest_names() {
    local manifest=$1 rest filename index=0
    local -a lines
    shift
    mapfile -t lines < "$bundle/$manifest"
    (( ${#lines[@]} == $# )) || { echo "Unexpected records in $manifest" >&2; return 1; }
    for filename do
        rest=${lines[index]}
        [[ $rest =~ ^[a-f0-9]{64}[[:blank:]][[:blank:]] ]] && [[ ${rest:66} == "$filename" ]] || {
            echo "Invalid checksum record in $manifest for $filename" >&2
            return 1
        }
        (( index += 1 ))
    done
}
check_manifest_names SHA256SUMS "${files[@]/%/.zst}" identity.txt RAW-SHA256SUMS
check_manifest_names RAW-SHA256SUMS "${files[@]}" identity.txt
if ! $verify_only; then
    input=$1
    [[ $input != */ ]] || usage
    test ! -e "$input" && test ! -L "$input" || { echo 'The unpack destination already exists' >&2; exit 1; }
    parent=$(cd -- "$(dirname -- "$input")" && pwd -P)
    target=$parent/$(basename -- "$input")
fi
(cd "$bundle" && sha256sum --strict -c SHA256SUMS)
if $verify_only; then
    for file in "${files[@]}"; do
        expected=$(awk -v name="$file" '$2 == name { print $1 }' "$bundle/RAW-SHA256SUMS")
        actual=$(zstd -q -d -c -- "$bundle/$file.zst" | sha256sum)
        [[ ${actual%% *} == "$expected" ]] || { echo "Raw checksum mismatch for $file" >&2; exit 1; }
        printf '%s: raw stream OK\n' "$file"
    done
    expected=$(awk '$2 == "identity.txt" { print $1 }' "$bundle/RAW-SHA256SUMS")
    printf '%s  %s\n' "$expected" "$bundle/identity.txt" | sha256sum --strict -c -
    exit
fi
stage=$(mktemp -d --tmpdir="$parent" .y700-unpack.XXXXXXXX)
cleanup() {
    if [[ -d $stage ]]; then
        rm -f -- "$stage/"{asphalt-prc-u-boot.img,linux-boot.fat,root.ext4,identity.txt,SHA256SUMS}
        rmdir -- "$stage"
    fi
}
trap cleanup EXIT
for index in "${!files[@]}"; do
    file=${files[index]}
    zstd -q -d --sparse -o "$stage/$file" -- "$bundle/$file.zst"
    test "$(stat -c %s "$stage/$file")" = "${sizes[index]}"
done
cp -- "$bundle/identity.txt" "$stage/identity.txt"
cp -- "$bundle/RAW-SHA256SUMS" "$stage/SHA256SUMS"
(cd "$stage" && sha256sum --strict -c SHA256SUMS)
mv -T --no-clobber -- "$stage" "$target"
test ! -e "$stage" || { echo 'The unpack destination appeared during extraction' >&2; exit 1; }
printf 'Unpacked and verified %s\n' "$target"
