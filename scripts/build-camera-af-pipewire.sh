#!/bin/bash
# Extend the sealed backend's dependency after checking its actual AArch64 ELF imports.
set -euo pipefail
export LC_ALL=C
[[ $# == 4 ]] || { echo "Usage: $0 STOCK_PIPEWIRE_DEB STOCK_RUNTIME_DEB AF_RUNTIME_DEB OUTPUT_DIRECTORY" >&2; exit 2; }
stock=$(realpath -e "$1")
old=$(realpath -e "$2")
new=$(realpath -e "$3")
out=$(realpath -m "$4")
check_sha() { [[ $(sha256sum < "$1" | cut -d' ' -f1) == "$2" ]]; }
check_sha "$stock" f8c010932e9eb2a020a71bcc2a61cb322a24115e5b937a9e74ba4accd073c54d
check_sha "$old" 0cb078114ccf875b14fbe4018f4e969d655f637254c6f106a5ba73ef12dba1a8
[[ $(dpkg-deb -f "$new" Package) == y700-camera-runtime &&
   $(dpkg-deb -f "$new" Version) == '0.7.2-1~bpo13+1.y7002' &&
   $(dpkg-deb -f "$new" Architecture) == arm64 ]]
mkdir -p "$out"
work=$(mktemp -d)
pending=
trap 'rm -rf -- "$work"; if [[ -n $pending ]]; then rm -f -- "$pending"; fi' EXIT
dpkg-deb -R "$stock" "$work/package"
dpkg-deb -x "$old" "$work/old"
dpkg-deb -x "$new" "$work/new"
backend=$work/package/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so
readelf -h "$backend" | grep -F 'AArch64' >/dev/null
for side in old new; do
    lib=$work/$side/opt/y700-camera/lib
    for name in libcamera libcamera-base; do
        object=$lib/$name.so.0.7
        readelf -h "$object" | grep -F 'AArch64' >/dev/null
        readelf -d "$object" | grep -F "Library soname: [$name.so.0.7]" >/dev/null
        nm -D --defined-only "$object" | awk '{print $NF}'
    done | sort -u >"$work/exports.$side"
done
nm -D --undefined-only "$backend" | awk '{print $NF}' | sort -u >"$work/imports"
comm -12 "$work/imports" "$work/exports.old" >"$work/used"
[[ -s "$work/used" && ! $(comm -23 "$work/used" "$work/exports.new") ]]
printf 'Verified %d shipped SPA imports against both runtimes.\n' "$(wc -l <"$work/used")"
control=$work/package/DEBIAN/control
original='y700-camera-runtime (= 0.7.2-1~bpo13+1.y7001)'
grep -F "$original," "$control" >/dev/null
sed -i -e 's/^Version: 1\.4\.2-1+y700\.3$/Version: 1.4.2-1+y700.4/' \
    -e "s|$original,|$original \\| y700-camera-runtime (= 0.7.2-1~bpo13+1.y7002),|" "$control"
[[ $(dpkg-deb --field "$stock" Architecture) == arm64 ]]
export SOURCE_DATE_EPOCH=1795257600
name=y700-camera-pipewire_1.4.2-1+y700.4_arm64.deb
find "$work/package/DEBIAN" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
dpkg-deb -Zxz -z6 --uniform-compression --root-owner-group --build "$work/package" "$work/metadata.deb"
# Preserve the sealed data member byte-for-byte, including directory timestamps.
data=$(ar t "$stock" | grep -E '^data\.tar(\.[a-z0-9]+)?$')
control_member=$(ar t "$work/metadata.deb" | grep -E '^control\.tar(\.[a-z0-9]+)?$')
ar p "$stock" debian-binary >"$work/debian-binary"
ar p "$stock" "$data" >"$work/$data"
ar p "$work/metadata.deb" "$control_member" >"$work/$control_member"
(cd "$work" && ar rcD "$name" debian-binary "$control_member" "$data")
[[ $(dpkg-deb -f "$work/$name" Version) == '1.4.2-1+y700.4' &&
   $(dpkg-deb -f "$work/$name" Depends) == *"$original | y700-camera-runtime (= 0.7.2-1~bpo13+1.y7002),"* ]]
ar p "$work/$name" "$data" | cmp "$work/$data" -
dpkg-deb --fsys-tarfile "$work/$name" | tar -tf - >/dev/null
pending=$(mktemp "$out/.$name.XXXXXXXX")
install -m 644 "$work/$name" "$pending"
mv -fT "$pending" "$out/$name"
sha256sum "$out/$name"
