#!/bin/bash
# Preserve stock tools, other device plugins, conffiles, service policy and dependencies.
set -euo pipefail
umask 022
[[ $# == 3 && $(dpkg --print-architecture) == arm64 ]] || exit 2
stock=$(realpath -e "$1")
build=$(realpath -e "$2")
out=$(realpath -e "$3")
here=$(cd "$(dirname "$0")" && pwd)
version=1.52.1-1+0y7001
name=network-manager_${version}_arm64.deb
export SOURCE_DATE_EPOCH=1795182000
[[ $(sha256sum "$stock" | cut -d' ' -f1) == 97a91921a83199c35b847807c323e647483bef56353262cc39e52531bda61aa1 ]]
dpkg --compare-versions 1.52.1-1 lt "$version"
dpkg --compare-versions "$version" lt 1.52.1-1+deb13u1
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
root=$work/pkg
dpkg-deb --raw-extract "$stock" "$root"
wifi=usr/lib/aarch64-linux-gnu/NetworkManager/1.52.1/libnm-device-plugin-wifi.so
daemon=usr/sbin/NetworkManager
changelog=usr/share/doc/network-manager/changelog.Debian.gz
size=$(dpkg-deb -f "$stock" Installed-Size)
for f in "$daemon" "$wifi" "$changelog"; do
    bytes=$(stat -c %s "$root/$f")
    size=$((size - (bytes + 1023) / 1024))
done
install -m755 "$build/src/core/NetworkManager" "$root/$daemon"
install -m644 "$build/src/core/devices/wifi/libnm-device-plugin-wifi.so" "$root/$wifi"
for file in "$root/$daemon" "$root/$wifi"; do
    readelf -h "$file" | grep -F 'AArch64' >/dev/null
    strip --strip-unneeded --remove-section=.comment "$file"
done
{ cat "$here/changelog"; echo; gzip -cd "$root/$changelog"; } | gzip -9n >"$work/changelog.gz"
install -m644 "$work/changelog.gz" "$root/$changelog"
sed -i "s/^Version: 1.52.1-1$/Version: $version/" "$root/DEBIAN/control"
# Keep the stock conffile exclusion and ordering of Debian's checksum file.
cd "$root"
for f in "$daemon" "$wifi" "$changelog"; do
    bytes=$(stat -c %s "$f")
    size=$((size + (bytes + 1023) / 1024))
    digest=$(md5sum "$f" | cut -d' ' -f1)
    awk -v path="$f" -v digest="$digest" \
        '$2 == path { $0 = digest "  " path; hits++ } { print } END { exit hits != 1 }' \
        DEBIAN/md5sums >"$work/md5sums"
    install -m644 "$work/md5sums" DEBIAN/md5sums
done
md5sum --strict --status -c DEBIAN/md5sums
# Preserve the stock Installed-Size accounting and adjust the three changed files.
sed -i "s/^Installed-Size: .*/Installed-Size: $size/" DEBIAN/control
find . -newermt "@$SOURCE_DATE_EPOCH" -exec touch --no-dereference -d "@$SOURCE_DATE_EPOCH" {} +
dpkg-deb --root-owner-group -Zxz -z6 --build . "$work/$name"
[[ $(dpkg-deb -f "$work/$name" Version) == "$version" ]]
[[ $(dpkg-deb -f "$work/$name" Depends) == "$(dpkg-deb -f "$stock" Depends)" ]]
stage=$(mktemp "$out/.network-manager.XXXXXXXX")
trap 'rm -rf -- "$work"; rm -f -- "$stage"' EXIT
install -m644 "$work/$name" "$stage"
ln "$stage" "$out/$name" || cmp "$stage" "$out/$name"
(cd "$out"; sha256sum "$name")
