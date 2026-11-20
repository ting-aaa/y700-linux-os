#!/usr/bin/env bash
set -euo pipefail
work=/run/rotation-touch
exec >> "$work/actor.log" 2>&1
test "$(id -un)" = y700
property() { loginctl show-session "${XDG_SESSION_ID:?}" -p "$1" --value; }
test "$(property Active)" = yes
test "$(property Remote)" = no
test "$(property Seat)" = seat0
test "$(property Type)" = x11
test "$(property LockedHint)" = no
echo 'ROTATION_SEAT ordinary_user=yes active=yes locked=no seat=seat0 type=x11'
cd /opt/ssc-test
export LC_ALL=C XDG_CURRENT_DESKTOP=XFCE GDK_BACKEND=x11 PYTHONDONTWRITEBYTECODE=1
export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg
export UV_CACHE_DIR="$XDG_RUNTIME_DIR/rotation-fixture-uv"
if [[ -f desktop-probe.py ]]; then
    ./uv run --offline --no-project --python /usr/bin/python3 python desktop-probe.py
fi
dbus-run-session -- bash -ec '
    xfsettingsd --no-daemon & settings=$!
    trap "kill $settings 2>/dev/null || :" EXIT
    ./uv run --offline --no-project --python /usr/bin/python3 python check.py desktop
'
