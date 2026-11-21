#!/bin/bash
# Apply or undo the package transaction without restarting anyone's browser.
set -euo pipefail
export LC_ALL=C
[[ $# == 3 && $EUID == 0 && ( $1 == install || $1 == rollback ) ]] || {
    echo "Usage as root: $0 install|rollback ORIGINAL_PLATFORM_DEB GPU_PLATFORM_DEB" >&2; exit 2;
}
original=$(realpath -e "$2"); updated=$(realpath -e "$3")
printf '%s  %s\n' 95b8e4419a40080e98b78dbfe63839476c20479714ffb7257cfb7bbafc927583 "$original" \
    2b6dd72510cc0a63744127cd68149ec28f4241a6acca587263ddcc8e3357e97e "$updated" | sha256sum --strict -c -
old=0.1.0~dev12.8; new=$old+gpu1
files=(etc/chromium.d/99-y700-software-rendering usr/share/glib-2.0/schemas/org.y700.chromium.gschema.xml
       usr/share/applications/y700-chromium-graphics.desktop usr/libexec/y700-chromium-graphics)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
dpkg-deb -x "$original" "$work/$old"
dpkg-deb -x "$updated" "$work/$new"
version() { dpkg-query -W -f='${Status} ${Version}' y700-platform; }
verify_files() {
    local ver=$1 f
    for f in "${files[@]}"; do
        if [[ -e $work/$ver/$f ]]; then
            [[ -f /$f && ! -L /$f ]] && cmp -s "/$f" "$work/$ver/$f" || {
                echo "Refusing unexpected installed file: /$f" >&2; return 1;
            }
        elif [[ -e /$f || -L /$f ]]; then
            echo "Refusing unrelated file: /$f" >&2; return 1
        fi
    done
}
case "$(version)" in
    "install ok installed $old") current=$old ;;
    "install ok installed $new") current=$new ;;
    *) echo 'Unexpected platform package status or version.' >&2; exit 1 ;;
esac
verify_files "$current"
target=$new; deb=$updated
if [[ $1 == rollback ]]; then target=$old; deb=$original; fi
if [[ $target != "$current" ]]; then
    # Keep locally edited unrelated conffiles; this hook was checked above.
    dpkg --force-confold -i "$deb"
fi
[[ $(version) == "install ok installed $target" ]]
verify_files "$target"
if [[ $target == "$new" ]]; then
    [[ -x /usr/libexec/y700-chromium-graphics &&
       $(GSETTINGS_BACKEND=memory gsettings get org.y700.chromium hardware-acceleration) == false ]]
fi
printf 'CHROMIUM_GRAPHICS_PACKAGE_OK version=%s\n' "$target"
