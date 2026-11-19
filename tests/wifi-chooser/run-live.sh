#!/usr/bin/env bash
# Stage only the X11 tools and read-only physical probe over an existing SSH wrapper.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
ssh=(bash "${1:?verified SSH wrapper}")
assets=$(realpath -e "${2:?directory with Debian 13 ARM64 Xvfb, xdotool and libxdo3 debs}")
user=${3:-y700}
[[ $user =~ ^[A-Za-z_][A-Za-z0-9_-]*$ && $user != root ]]
work=$(mktemp -d /tmp/y700-wifi-live.XXXXXXXX)
[[ $(realpath -e "$work") =~ ^/tmp/y700-wifi-live\.[a-zA-Z0-9]{8}$ ]]
stage=
cleanup() {
    if [[ $stage =~ ^/var/tmp/y700-wifi-probe\.[a-zA-Z0-9]{8}$ ]]; then
        "${ssh[@]}" "test \"\$(realpath -e '$stage')\" = '$stage' && rm -r --one-file-system -- '$stage'" >/dev/null 2>&1 || true
    fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir -p "$work/bundle/bin" "$work/bundle/lib" "$work/debian"
for deb in "$assets/"{xvfb,xdotool,libxdo3}_*.deb; do dpkg-deb -x "$deb" "$work/debian"; done
cp -- "$work/debian/usr/bin/Xvfb" "$work/bundle/bin/"
cp -- "$work/debian/usr/bin/xdotool" "$work/bundle/bin/xdotool.real"
cp -L -- "$work/debian/usr/lib/aarch64-linux-gnu/libxdo.so.3" "$work/bundle/lib/"
cat > "$work/bundle/bin/xdotool" <<'TOOL'
#!/bin/sh
exec /lib/ld-linux-aarch64.so.1 --library-path "${0%/*}/../lib" "${0%/*}/xdotool.real" "$@"
TOOL
chmod 755 "$work/bundle/bin/xdotool"
cp -- "$here/"{session.sh,xfce4-panel.xml,probe.py} "$work/bundle/"
stage=$("${ssh[@]}" 'mktemp -d /var/tmp/y700-wifi-probe.XXXXXXXX')
[[ $stage =~ ^/var/tmp/y700-wifi-probe\.[a-zA-Z0-9]{8}$ ]]
tar -C "$work/bundle" -cf - . | "${ssh[@]}" "tar -C '$stage' -xf - && chown -R '$user' '$stage'"
"${ssh[@]}" "timeout -k 4s 86s setpriv --reuid='$user' --regid='$user' --init-groups bash '$stage/session.sh' physical"
