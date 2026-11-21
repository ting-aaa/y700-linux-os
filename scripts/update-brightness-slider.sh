#!/bin/bash
# Apply or undo only the brightness UI update on a Chromium-enabled dev12.11.
set -euo pipefail
[[ $EUID == 0 && $# == 3 && ( $1 == install || $1 == rollback ) ]] || {
    echo "Usage as root: $0 install|rollback PREVIOUS_PLATFORM_DEB SLIDER_PLATFORM_DEB" >&2; exit 2;
}
old=$(realpath -e "$2")
new=$(realpath -e "$3")
check_package() {
    local digest
    case $(dpkg-deb -f "$1" Version) in
        0.1.0~dev12.8+gpu1) digest=2b6dd72510cc0a63744127cd68149ec28f4241a6acca587263ddcc8e3357e97e ;;
        0.1.0~dev12.8+gpu1.1) digest=aa39b033a89c8e295df4ba29a4a4fed26c91e6d4b9928fcf2e5d9cabde74d535 ;;
        0.1.0~dev12.8+gpu1.2) digest=479c59b518f42e035f9101feb5947ba972df32b1a5646f62b459bc13b5357518 ;;
        *) echo 'Unrecognized platform package.' >&2; return 1 ;;
    esac
    printf '%s  %s\n' "$digest" "$1" | sha256sum --strict -c -
}
check_package "$old"
check_package "$new"
old_version=$(dpkg-deb -f "$old" Version)
new_version=$(dpkg-deb -f "$new" Version)
dpkg --compare-versions "$old_version" lt "$new_version"
package_state() { dpkg-query -W -f='${Status} ${Version}' y700-platform; }
case $(package_state) in
    "install ok installed $old_version") current=$old ;;
    "install ok installed $new_version") current=$new ;;
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
