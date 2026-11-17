#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT
bash "$repo/scripts/build-platform.sh" "$temp/one"
bash "$repo/scripts/build-platform.sh" "$temp/two"
package=y700-platform_0.1.0~dev1_all.deb
cmp "$temp/one/$package" "$temp/two/$package"
dpkg-deb -x "$temp/one/$package" "$temp/root"
test -z "$(find "$temp/root" -perm /0022 -print)"
test "$(stat -c %a "$temp/root/usr/lib/systemd/system/y700-usb-maintenance.service")" = 644
test -x "$temp/root/usr/bin/y700-display"
test -x "$temp/root/usr/libexec/y700-session"
test ! -e "$temp/root/etc/xdg/autostart/onboard-autostart.desktop"
test -e "$temp/root/etc/xdg/autostart/y700-onboard.desktop"
test ! -e "$temp/root/etc/y700/maintenance.env"
test ! -e "$temp/root/etc/systemd/system/multi-user.target.wants"
echo 'PASS: deterministic package, safe file modes, no shared identity or automatic service activation.'
