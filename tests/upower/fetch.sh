#!/usr/bin/env bash
# Collect the six missing runtime packages from the authenticated ARM64 index.
set -euo pipefail
[[ $# == 4 ]] || { echo 'Usage: fetch.sh TRIXIE_INRELEASE ARM64_PACKAGES DEBIAN_KEYRING NEW_DIR' >&2; exit 2; }
release=$(realpath -e "$1")
index=$(realpath -e "$2")
keyring=$(realpath -e "$3")
mkdir -m700 -- "$4"
cd "$4"
printf '%s  %s\n' 0584fba32e13e0ab8285fb16c27adea1ec03a73669c18702821094fd6ca86675 "$release" | sha256sum --strict -c -
gpgv --keyring "$keyring" "$release"
digest=$(awk '$1=="SHA256:" {on=1;next} /^[^ ]/ {on=0} on && $3=="main/binary-arm64/Packages"{print $1}' "$release")
[[ $digest == f97011263173eaccb1a215a28a6ec7ba1f6e5cebd8bb68e8fa0475b1d4021161 ]]
printf '%s  %s\n' "$digest" "$index" | sha256sum --strict -c -
mkdir runtime
for name in upower libupower-glib3 libimobiledevice-1.0-6 libimobiledevice-glue-1.0-0 libplist-2.0-4 libusbmuxd-2.0-7; do
    read -r version filename hash < <(awk -v RS='' -v n="$name" -F '\n' '$1 == "Package: " n {
        for(i=2;i<=NF;i++){split($i, a, " "); if(a[1]=="Version:")v=a[2]; if(a[1]=="Filename:")f=a[2]; if(a[1]=="SHA256:")h=a[2]}; print v,f,h
    }' "$index")
    [[ $filename == pool/main/* && $hash =~ ^[a-f0-9]{64}$ ]]
    path=runtime/${filename##*/}
    curl -fsSL --retry 2 "https://deb.debian.org/debian/$filename" -o "$path"
    printf '%s  %s\n' "$hash" "$path" | tee -a SHA256SUMS | sha256sum --strict -c -
    printf 'runtime\t%s\t%s\t%s\t%s\n' "$name" "$version" "$hash" "$filename" >> archives.tsv
done
