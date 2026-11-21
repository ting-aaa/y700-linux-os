#!/bin/bash
# Run next to the two checked Debian archives. Package changes are offline.
set -euo pipefail
[[ $EUID == 0 && $# == 1 && $1 =~ ^(check|install|rollback)$ ]] || {
    echo 'Usage as root: bash update.sh check|install|rollback' >&2; exit 2;
}
action=$1
cd -- "$(dirname -- "$0")"
package=y700-camera-pipewire
prev=1.4.2-1+y700.4
next=1.4.2-1+y700.5
archive() { printf './%s_%s_arm64.deb' "$package" "$1"; }
printf '%s  %s\n' \
    9de518b05da6d4fafc26a6a284dd30d484eb47801c947c814bcfa3fe772b3e52 "$(archive "$prev")" \
    73cfdd2a0b1dad67f02aef3efbbb54b9129fb6a918bddc33b0574a08cd343cfc "$(archive "$next")" |
    sha256sum --strict -c -
spa=/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so
helper=/usr/libexec/y700-camera-orientation
entry=/etc/xdg/autostart/y700-camera-orientation.desktop
desktop_sha=182ed10efb22af8230800dc2571a1d4dbde2b94fc33009c8037652e1414c0276
status() { dpkg-query -W -f='${db:Status-Status} ${Version} ${Architecture}' "$package"; }
verify() {
    local version=$1 binary
    local files=("$spa" /usr/share/wireplumber/wireplumber.conf.d/65-y700-camera.conf)
    if [[ $version == "$next" ]]; then files+=("$helper"); fi
    for binary in "${files[@]}"; do
        [[ -f $binary && ! -L $binary ]]
        dpkg-deb --fsys-tarfile "$(archive "$version")" | tar -xOf - ".$binary" | cmp - "$binary"
    done
}
exec 9>/run/y700-browser-camera-update.lock
flock 9
read -r state version arch <<<"$(status)"
[[ $arch == arm64 && ( $version == "$prev" || $version == "$next" ) ]]
case $state in
    installed) verify "$version" ;;
    unpacked|half-installed|half-configured|triggers-awaited|triggers-pending) [[ $action != check ]] ;;
    *) echo "Unexpected installed state: $state" >&2; exit 1 ;;
esac
target=$version
case $action in install) target=$next ;; rollback) target=$prev ;; esac
changed=0
if [[ $version != "$target" || $state != installed ]]; then
    if [[ $target == "$next" && ( -e $entry || -L $entry ) ]]; then
        [[ -f $entry && ! -L $entry ]]
        echo "$desktop_sha  $entry" | sha256sum --strict -c -
    fi
    dpkg --force-confold --install "$(archive "$target")"
    changed=1
fi
[[ $(status) == "installed $target arm64" ]]
verify "$target"
if [[ $action == rollback && -f $entry && ! -L $entry ]]; then
    # dpkg retains obsolete conffiles after a downgrade. Preserve local edits.
    if [[ $(sha256sum "$entry" | cut -d' ' -f1) == "$desktop_sha" ]]; then rm -- "$entry"; fi
fi
apt-get --simulate --no-download check >/dev/null
printf 'BROWSER_CAMERA_PACKAGE version=%s configured=1 changed=%s\n' "$target" "$changed"
