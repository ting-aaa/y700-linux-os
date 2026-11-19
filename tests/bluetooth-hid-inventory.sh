#!/usr/bin/env bash
# Requires systemd busctl, uv, dbus-daemon and python3-dbusmock's bluez5 template.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
dbus-run-session -- bash -eu -o pipefail -s -- "$repo" "$work" <<'SESSION'
export DBUS_SYSTEM_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS
repo=$1
work=$2
# This private bus has no system manager. Exercise the BlueZ interface directly.
systemctl() { echo inactive; return 3; }
export -f systemctl
probe() { bash "$repo/scripts/check-bluetooth-hid.sh"; }
report=$(probe)
grep -Fxq 'bluetooth.hid-peer-inventory=unavailable' <<< "$report"
uv run --no-project --python /usr/bin/python3 python -m dbusmock -t bluez5 --logfile "$work/mock.log" &
mock=$!
trap 'kill "$mock" 2>/dev/null || true; wait "$mock" 2>/dev/null || true' EXIT
gdbus wait --system --timeout 12 org.bluez
call() { busctl --system --auto-start=no --timeout=2s call org.bluez "$@"; }
call / org.bluez.Mock AddAdapter ss hci0 fixture >/dev/null
add_peer() {
    local address path
    printf -v address '02:%02X:%02X:%02X:%02X:%02X' 0 0 0 0 "$1"
    path=/org/bluez/hci0/dev_${address//:/_}
    call / org.bluez.Mock AddDevice sss hci0 "$address" "fixture-$1" >/dev/null
    call "$path" org.freedesktop.DBus.Mock AddProperty ssv org.bluez.Device1 Bonded b "$4"
    call "$path" org.freedesktop.DBus.Mock UpdateProperties 'sa{sv}' org.bluez.Device1 4 \
        UUIDs as 1 "$2-0000-1000-8000-00805f9b34fb" Paired b "$3" Connected b "$5" ServicesResolved b "$5"
}
add_peer 1 00001124 true true false  # previously bonded classic HID
add_peer 2 00001812 true true true   # connected LE HID
add_peer 3 0000110b true true true   # audio peer
add_peer 4 00001812 true false false # paired without a stored bond
add_peer 5 00001124 false false false
report=$(probe)
for field in classic-profile:2 le-profile:2 paired:3 bonded:2 connected:1 resolved:1; do
    grep -Fxq "bluetooth.hid-${field%:*}-peers=${field#*:}" <<< "$report"
done
[[ $report != *fixture-* && $report != *dev_* && $report != *02:00:* ]]
echo 'PASS: no-owner state, Classic and LE HID peers, audio exclusion and aggregate-only output.'
SESSION
