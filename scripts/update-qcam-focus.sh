#!/usr/bin/env bash
# Both local packages stay available for an offline install or rollback.
set -euo pipefail
[[ $EUID == 0 && $# == 1 && ( $1 == install || $1 == rollback ) ]] || {
    echo 'Usage as root: update-qcam-focus.sh install|rollback' >&2; exit 2;
}
cd -- "$(dirname -- "$0")"
package=y700-camera-qcam
prev='0.7.2-1~bpo13+1.y7005'
next='0.7.2-1~bpo13+1.y7007'
deb() { printf './%s_%s_arm64.deb' "$package" "$1"; }
printf '%s  %s\n' \
    4e79033cc61128049b32c0265b09c00a7930a1f6bb45d48f97849709cf497d56 "$(deb "$prev")" \
    3bfbc1bf91892b621af6a2ccf86b7ef4a137583f7edcf0e0cb40c2a2f353244f "$(deb "$next")" |
    sha256sum --strict -c -
for version in "$prev" "$next"; do
    file=$(deb "$version")
    [[ $(dpkg-deb -f "$file" Package) == "$package" && $(dpkg-deb -f "$file" Version) == "$version" &&
       $(dpkg-deb -f "$file" Architecture) == arm64 ]]
done
installed() { dpkg-query -W -f='${db:Status-Status} ${Version}' "$package"; }
read -r state current <<<"$(installed)"
[[ $current == "$prev" || $current == "$next" ]] || { echo 'Unexpected installed qcam version.' >&2; exit 1; }
verify_binary() {
    local path=/opt/y700-camera/bin/qcam
    [[ -x $path && ! -L $path ]]
    dpkg-deb --fsys-tarfile "$(deb "$1")" | tar -xOf - ".$path" | cmp - "$path"
}
case $state in
    installed) verify_binary "$current" ;;
    unpacked|half-configured|half-installed|triggers-awaited|triggers-pending) ;;
    *) echo 'Unexpected qcam package state.' >&2; exit 1 ;;
esac
target=$next
if [[ $1 == rollback ]]; then target=$prev; fi
if [[ $current != "$target" || $state != installed ]]; then
    dpkg -i "$(deb "$target")"
fi
[[ $(installed) == "installed $target" ]]
verify_binary "$target"
printf 'QCAM_PACKAGE_OK version=%s\n' "$target"
