#!/usr/bin/env bash
# Read-only probe for the booted Debian system. Reports no controller/peer
# addresses, input names or keystrokes. Does not start Bluetooth services.
set -euo pipefail
shopt -s nullglob

state=$(systemctl is-active bluetooth.service 2>/dev/null) || true
printf 'bluez.service=%s\n' "${state:-unavailable}"
printf 'uhid.device=%s\n' "$(test -c /dev/uhid && echo present || echo absent)"

adapter_property() {
    # busctl get-property does not apply --auto-start in systemd 257.
    busctl --system --auto-start=no --timeout=2s call org.bluez "/org/bluez/$1" \
        org.freedesktop.DBus.Properties Get ss org.bluez.Adapter1 "$2" 2>/dev/null
}

controllers=0
for controller in /sys/class/bluetooth/hci*; do
    hci=${controller##*/}
    [[ $hci =~ ^hci[0-9]+$ ]] || continue
    ((controllers+=1))
    power=$(adapter_property "$hci" Powered) || power=unavailable
    case "$power" in
        'v b true') power=yes ;;
        'v b false') power=no ;;
        *) power=unavailable ;;
    esac
    printf '%s.bluez-powered=%s\n' "$hci" "$power"
    address=$(adapter_property "$hci" Address) || address=
    case "$address" in
        'v s "00:00:00:00:00:00"') address=zero ;;
        'v s "'??:??:??:??:??:??'"') address=nonzero ;;
        *) address=unavailable ;;
    esac
    printf '%s.bluez-address=%s\n' "$hci" "$address"
done
printf 'bluetooth.controllers=%s\n' "$controllers"

keyboards=0
mice=0
for event in /sys/class/input/event*; do
    # Linux input bus type 0x0005 is BUS_BLUETOOTH.
    [[ -r $event/device/id/bustype ]] || continue
    IFS= read -r bus < "$event/device/id/bustype" || continue
    [[ $bus == 0005 ]] || continue
    properties=$(udevadm info --query=property --path="$event") || continue
    if [[ $'\n'$properties$'\n' == *$'\nID_INPUT_KEYBOARD=1\n'* ]]; then
        ((keyboards+=1))
    fi
    if [[ $'\n'$properties$'\n' == *$'\nID_INPUT_MOUSE=1\n'* ]]; then
        ((mice+=1))
    fi
done
printf 'bluetooth.keyboard-event-nodes=%s\nbluetooth.mouse-event-nodes=%s\n' "$keyboards" "$mice"
