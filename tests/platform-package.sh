#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT
bash "$repo/scripts/build-platform.sh" "$temp/one"
bash "$repo/scripts/build-platform.sh" "$temp/two"
package="y700-platform_$(sed -n 's/^Version: //p' "$repo/packaging/control")_all.deb"
cmp "$temp/one/$package" "$temp/two/$package"
dpkg-deb -x "$temp/one/$package" "$temp/root"
test -z "$(find "$temp/root" -perm /0022 -print)"
test "$(stat -c %a "$temp/root/usr/lib/systemd/system/y700-usb-maintenance.service")" = 644
test -x "$temp/root/usr/bin/y700-display"
test -x "$temp/root/usr/libexec/y700-session"
test -x "$temp/root/usr/libexec/y700-tablet-scale"
test -x "$temp/root/usr/libexec/y700-bluetooth-identity"
grep -Fxq 'Exec=/usr/libexec/y700-tablet-scale' "$temp/root/usr/share/applications/y700-tablet-scale.desktop"
if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$temp/root/usr/share/applications/y700-tablet-scale.desktop"
fi
test ! -e "$temp/root/etc/xdg/autostart/onboard-autostart.desktop"
test -e "$temp/root/etc/xdg/autostart/y700-onboard.desktop"
test ! -e "$temp/root/etc/y700/maintenance.env"
test ! -e "$temp/root/etc/y700/bluetooth-address"
test ! -e "$temp/root/etc/systemd/system/multi-user.target.wants"
if SOURCE_DATE_EPOCH=9999999999 bash "$repo/scripts/build-platform.sh" "$temp/future" > "$temp/future.log" 2>&1; then
    echo 'Future early-boot clock seed was accepted' >&2; exit 1
fi
test ! -e "$temp/future/$package"
echo 'PASS: deterministic package, safe file modes, no shared identity or automatic service activation.'
