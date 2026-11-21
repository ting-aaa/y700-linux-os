#!/bin/bash
# Run from an extracted offline bundle, next to the two ARM64 packages.
set -euo pipefail
export LC_ALL=C
if [[ $EUID != 0 || $# != 1 || ! $1 =~ ^(install|check|reinstall|rollback)$ ]]; then
    echo 'Usage as root: update-blueman-manager.sh install|check|reinstall|rollback' >&2
    exit 2
fi
cd -- "$(dirname -- "$0")"
previous=2.4.4-1+y7002
next=2.4.4-1+y7003
deb() { printf './blueman_%s_arm64.deb' "$1"; }
state() { dpkg-query -W -f='${db:Status-Status} ${Version} ${Architecture}\n' blueman:arm64; }
exec 9>/run/y700-blueman-manager-update.lock
flock -n 9 || { echo 'Another Blueman update is running.' >&2; exit 1; }
[[ $(dpkg --print-architecture) == arm64 ]]
for version in "$previous" "$next"; do
    archive=$(deb "$version")
    [[ -f $archive && ! -L $archive ]]
    [[ $(dpkg-deb -W --showformat='${Package} ${Version} ${Architecture}' "$archive") == "blueman $version arm64" ]]
done
printf '%s  %s\n' \
    4fbb2eb45426a10620e75943f359715adec921fdc71e5d976f807f3295756367 "$(deb "$previous")" \
    f0b06bc9c290ce3d7b6ee78dbb1ca41fee5a2143a6af03c63cfeb80059c2597b "$(deb "$next")" | sha256sum --strict -c -

verify_files() {
    local version=$1 file
    for file in /usr/lib/python3/dist-packages/blueman/main/{Manager.py,applet/BluezAgent.py} \
                /usr/share/blueman/ui/manager-main.ui; do
        [[ -f $file && ! -L $file ]] || return 1
        dpkg-deb --fsys-tarfile "$(deb "$version")" | tar -xOf - ".$file" | cmp - "$file" || return 1
    done
}
read -r status current arch <<<"$(state)"
[[ $arch == arm64 && ( $current == "$previous" || $current == "$next" ) ]] || {
    echo 'Expected an installed Y700 Blueman package.' >&2; exit 1;
}
case $status in
    installed)
        if [[ $1 != reinstall ]]; then verify_files "$current"; fi ;;
    unpacked|half-configured|half-installed|triggers-awaited|triggers-pending)
        [[ $1 != check ]] || { echo "Blueman needs configuration ($status)." >&2; exit 1; } ;;
    *) echo "Unexpected package state ($status)." >&2; exit 1 ;;
esac
target=$current
case $1 in
    install) target=$next ;;
    rollback) target=$previous ;;
esac
if [[ $1 == reinstall || $current != "$target" || $status != installed ]]; then
    dpkg --force-confold --install "$(deb "$target")"
    echo BLUEMAN_DPKG_TRANSACTION
fi
[[ $(state) == "installed $target arm64" ]]
verify_files "$target"
echo "BLUEMAN_MANAGER_OK version=$target"
