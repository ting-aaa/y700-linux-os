#!/usr/bin/env bash
# Build the Debian-owned Xorg core and common packages on an ARM64 Debian host.
set -euo pipefail
if (( $# != 2 )); then
    echo 'Usage: build-xorg-dsi.sh AUTHENTICATED_SOURCE_DIRECTORY OUTPUT_DIRECTORY' >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd -P)
sources=$(realpath -e "$1")
output=$(realpath -e "$2")
test -d "$output"
test "$(dpkg --print-architecture)" = arm64
version='2:21.1.16-1.3+deb13u4+y7001'
source_version=21.1.16-1.3+deb13u4
(cd "$sources" && sha256sum --strict --check "$repo/config/xorg/debian-source.sha256")
work=$(mktemp -d "${TMPDIR:-/tmp}/y700-xorg-build.XXXXXXXX")
finish() {
    if (( $? == 0 )); then
        cd /
        rm -r --one-file-system -- "$work"
    else
        printf 'Build files retained in %s\n' "$work" >&2
    fi
}
trap finish EXIT
cd "$work"
dpkg-source --no-check -x "$sources/xorg-server_${source_version}.dsc" xorg-server
cd xorg-server
patchfile=modesetting-dsi-physical-size.patch
install -m644 "$repo/config/xorg/$patchfile" "debian/patches/$patchfile"
printf '%s\n' "$patchfile" >> debian/patches/series
{
    printf 'xorg-server (%s) trixie; urgency=medium\n\n' "$version"
    printf '  * Preserve KMS panel dimensions for DSI connectors without EDID dimensions.\n\n'
    printf ' -- Y700 Linux OS contributors <maintainers@example.invalid>  Thu, 19 Nov 2026 00:00:00 +0000\n\n'
    cat debian/changelog
} > debian/changelog.y700
mv debian/changelog.y700 debian/changelog
dpkg-buildpackage -b -us -uc
cd "$work"
for name_arch in xserver-xorg-core:arm64 xserver-common:all; do
    name=${name_arch%:*}
    arch=${name_arch#*:}
    file=${name}_${version#*:}_${arch}.deb
    test "$(dpkg-deb -f "$file" Package)" = "$name"
    test "$(dpkg-deb -f "$file" Architecture)" = "$arch"
    test "$(dpkg-deb -f "$file" Version)" = "$version"
    if [[ $name == xserver-xorg-core ]]; then
        dpkg-deb --fsys-tarfile "$file" | tar -xO ./usr/lib/xorg/modules/drivers/modesetting_drv.so > modesetting_drv.so
        readelf -h modesetting_drv.so | grep -F 'AArch64'
        dpkg-deb -f "$file" Depends | grep -F "xserver-common (>= $version)"
    fi
    if [[ -e $output/$file ]]; then
        cmp -- "$file" "$output/$file"
    else
        install -m644 -- "$file" "$output/$file"
    fi
    sha256sum -- "$output/$file"
done
