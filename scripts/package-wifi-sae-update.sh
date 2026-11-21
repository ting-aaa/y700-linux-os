#!/bin/bash
# Assemble two ARM64 client packages and their matching Debian rollback.
set -euo pipefail
umask 022
if [[ $# != 3 && $# != 4 ]]; then
    echo 'Usage: package-wifi-sae-update.sh CANDIDATE_DEBS DEBIAN_DEBS NEW_DIRECTORY [NEW_TAR]' >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd -P)
dest=$(realpath -m "$3")
[[ ! -e $dest && ! -L $3 && -d ${dest%/*} ]]
if [[ $# == 4 ]]; then
    archive=$(realpath -m "$4")
    [[ $archive != "$dest" && ! -e $archive && ! -L $4 && -d ${archive%/*} ]]
fi
work=$(mktemp -d "${dest%/*}/.wifi-sae.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
mkdir -p "$work/update/"{candidate,stock}
cp "$here/../config/wifi-sae-update.sha256" "$work/update/SHA256SUMS"
while read -r hash path; do
    [[ $hash =~ ^[[:xdigit:]]{64}$ && $path =~ ^(candidate|stock)/(network-manager|wpasupplicant)_[0-9a-z.+-]+_arm64\.deb$ ]]
    category=${BASH_REMATCH[1]}
    package=${BASH_REMATCH[2]}
    src=$1
    if [[ $category == stock ]]; then src=$2; fi
    file=$src/${path##*/}
    [[ -f $file && ! -L $file ]]
    [[ $(dpkg-deb -f "$file" Package) == "$package" && $(dpkg-deb -f "$file" Architecture) == arm64 ]]
    install -m644 "$file" "$work/update/$path"
done < "$work/update/SHA256SUMS"
[[ $(wc -l < "$work/update/SHA256SUMS") == 4 ]]
(cd "$work/update" && sha256sum --strict -c SHA256SUMS)
install -m644 "$here/../docs/WIFI-PASSWORD-RETRY.md" "$work/update/README.md"
if [[ -n ${archive:-} ]]; then
    # Files and directories have fixed, distinct permissions regardless of host umask or DrvFS.
    (cd "$work" && tar --sort=name --format=ustar --mtime=@1795233600 --owner=0 --group=0 --numeric-owner \
        --mode='a=r,u+w,a+X' -cf bundle.tar update)
    mkdir "$work/check"
    tar -xf "$work/bundle.tar" -C "$work/check"
    diff -qr -- "$work/update" "$work/check/update"
fi
mv -T --no-clobber "$work/update" "$dest"
[[ ! -e $work/update ]]
if [[ -n ${archive:-} ]]; then
    mv -T --no-clobber "$work/bundle.tar" "$archive"; [[ ! -e $work/bundle.tar ]]
    sha256sum -- "$archive"
fi
