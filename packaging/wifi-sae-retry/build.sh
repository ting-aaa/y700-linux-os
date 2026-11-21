#!/bin/bash
# Rebuild the daemon and Wi-Fi plugin together, preserving Debian's private ABI.
set -euo pipefail
umask 022
[[ $# == 2 && $(dpkg --print-architecture) == arm64 ]] || {
    echo 'Usage on Debian trixie arm64: build.sh DEBIAN_INPUTS OUTPUT_DIRECTORY' >&2
    exit 2
}
here=$(cd "$(dirname "$0")" && pwd)
inputs=$(realpath -e "$1")
mkdir -p "$2"
out=$(realpath -e "$2")
(cd "$inputs"; sha256sum --strict -c "$here/sources.sha256")

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
dpkg-source --no-check -x "$inputs/network-manager_1.52.1-1.dsc" "$work/src"
cd "$work/src"
patch --fuzz=0 -p1 < "$here/sae-retry.patch"
export SOURCE_DATE_EPOCH=1795182000
export DEB_BUILD_MAINT_OPTIONS='hardening=+all optimize=-lto'
export DEB_BUILD_OPTIONS="parallel=${JOBS:-4} nocheck"
debian/rules override_dh_auto_configure
ninja -C obj-aarch64-linux-gnu -j "${JOBS:-4}" \
    src/core/NetworkManager src/core/devices/wifi/libnm-device-plugin-wifi.so
bash "$here/assemble.sh" "$inputs/network-manager_1.52.1-1_arm64.deb" \
    "$PWD/obj-aarch64-linux-gnu" "$out"
