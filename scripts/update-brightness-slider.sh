#!/bin/bash
# Apply or undo only the brightness UI update on a Chromium-enabled dev12.11.
set -euo pipefail
[[ $EUID == 0 && $# == 3 && ( $1 == install || $1 == rollback ) ]] || {
    echo "Usage as root: $0 install|rollback GPU_PLATFORM_DEB SLIDER_PLATFORM_DEB" >&2; exit 2;
}
old=$(realpath -e "$2")
new=$(realpath -e "$3")
printf '%s  %s\n' 2b6dd72510cc0a63744127cd68149ec28f4241a6acca587263ddcc8e3357e97e "$old" \
    aa39b033a89c8e295df4ba29a4a4fed26c91e6d4b9928fcf2e5d9cabde74d535 "$new" | sha256sum --strict -c -
package_state() { dpkg-query -W -f='${Status} ${Version}' y700-platform; }
case $(package_state) in
    "install ok installed 0.1.0~dev12.8+gpu1") current=$old ;;
    "install ok installed 0.1.0~dev12.8+gpu1.1") current=$new ;;
    *) echo 'Unexpected platform version or incomplete installation.' >&2; exit 1 ;;
esac
verify() {
    local binary=/usr/libexec/y700-tablet-brightness
    [[ -f $binary && ! -L $binary && -x $binary ]]
    dpkg-deb --fsys-tarfile "$1" | tar -xOf - ".$binary" | cmp - "$binary"
}
verify "$current"
target=$new
if [[ $1 == rollback ]]; then target=$old; fi
if [[ $target != "$current" ]]; then dpkg --force-confold -i "$target"; fi
[[ $(package_state) == "install ok installed $(dpkg-deb -f "$target" Version)" ]]
verify "$target"
printf 'BRIGHTNESS_PACKAGE_OK version=%s\n' "$(dpkg-deb -f "$target" Version)"
