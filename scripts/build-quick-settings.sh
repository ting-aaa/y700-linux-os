#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")/../packaging/quick-settings" && pwd)
out=$(realpath -m "${1:-out/quick-settings}")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
tree=$work/pkg
install -Dm644 "$here/control" "$tree/DEBIAN/control"
install -Dm755 "$here/panel.py" "$tree/usr/libexec/y700-quick-settings/panel.py"
install -Dm644 "$here/devices.py" "$tree/usr/libexec/y700-quick-settings/devices.py"
install -Dm644 "$here/y700-quick-settings.desktop" "$tree/usr/share/applications/y700-quick-settings.desktop"
install -Dm644 "$here/tray.desktop" "$tree/etc/xdg/autostart/y700-quick-settings.desktop"
install -Dm644 "$here/../../LICENSE" "$tree/usr/share/doc/y700-quick-settings/copyright"
mkdir -p "$tree/usr/bin" "$out"
ln -s ../libexec/y700-quick-settings/panel.py "$tree/usr/bin/y700-quick-settings"
export SOURCE_DATE_EPOCH=1795219200
version=$(sed -n 's/^Version: //p' "$here/control")
name="y700-quick-settings_${version}_all.deb"
dpkg-deb --root-owner-group --build "$tree" "$work/$name"
install -m644 "$work/$name" "$out/$name"
(cd "$out"; sha256sum "$name")
