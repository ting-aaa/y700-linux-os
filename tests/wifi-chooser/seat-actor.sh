#!/usr/bin/env bash
set -euo pipefail
exec >/run/wifi-fixture/seat-receipt 2>&1
fail() { echo "WIFI_SEAT_ERROR $1" >&2; exit 1; }
test "$(id -un)" = y700 && test "$(id -u)" != 0 || fail account
session=${XDG_SESSION_ID:-}
test -n "$session" || fail pam-session-id-missing
property() { loginctl show-session "$session" -p "$1" --value; }
for _ in {1..30}; do [[ $(property Active) != yes ]] || break; sleep 0.1; done
test "$(property Active)" = yes || fail inactive-seat
test "$(property Remote)" = no || fail remote-seat
test "$(property Seat)" = seat0 || fail wrong-seat
test "$(property Type)" = x11 || fail wrong-type
test "$(property Class)" = user || fail wrong-class
nmcli --colors no -t -f PERMISSION,VALUE general permissions \
    | grep -Fxq 'org.freedesktop.NetworkManager.network-control:yes' || fail network-control-denied
echo 'WIFI_SEAT ordinary_uid=1 active=1 local=1 type=x11 network_control=yes'
exec bash /opt/wifi-test/session.sh fixture "${1:?security mode}"
