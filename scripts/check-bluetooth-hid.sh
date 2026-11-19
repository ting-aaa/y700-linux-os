#!/usr/bin/env bash
# Read-only probe for the booted Debian system. Reports no controller/peer
# addresses, input names or keystrokes. Does not start Bluetooth services.
set -euo pipefail
shopt -s nullglob

state=$(systemctl is-active bluetooth.service 2>/dev/null) || true
printf 'bluez.service=%s\n' "${state:-unavailable}"
printf 'uhid.device=%s\n' "$(test -c /dev/uhid && echo present || echo absent)"

bluez_property() {
    # busctl get-property does not apply --auto-start in systemd 257.
    busctl --system --auto-start=no --timeout=2s call "$1" "$2" \
        org.freedesktop.DBus.Properties Get ss "$3" "$4" 2>/dev/null
}

controllers=0
for controller in /sys/class/bluetooth/hci*; do
    hci=${controller##*/}
    [[ $hci =~ ^hci[0-9]+$ ]] || continue
    ((controllers+=1))
    power=$(bluez_property org.bluez "/org/bluez/$hci" org.bluez.Adapter1 Powered) || power=unavailable
    case "$power" in
        'v b true') power=yes ;;
        'v b false') power=no ;;
        *) power=unavailable ;;
    esac
    printf '%s.bluez-powered=%s\n' "$hci" "$power"
    address=$(bluez_property org.bluez "/org/bluez/$hci" org.bluez.Adapter1 Address) || address=
    case "$address" in
        'v s "00:00:00:00:00:00"') address=zero ;;
        'v s "'??:??:??:??:??:??'"') address=nonzero ;;
        *) address=unavailable ;;
    esac
    printf '%s.bluez-address=%s\n' "$hci" "$address"
done
printf 'bluetooth.controllers=%s\n' "$controllers"

bluez_owner() {
    busctl --system --auto-start=no --timeout=2s call org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus GetNameOwner s org.bluez 2>/dev/null
}

hid_peers() {
    local reply owner paths path uuids property value has_classic has_le
    local classic=0 le=0
    local -A yes=([Paired]=0 [Bonded]=0 [Connected]=0 [ServicesResolved]=0)
    reply=$(bluez_owner) || return 1
    [[ $reply =~ ^s\ \"(:[0-9]+\.[0-9]+)\"$ ]] || return 1
    owner=${BASH_REMATCH[1]}
    # Introspect only this running daemon, including if it exits during the scan.
    paths=$(busctl --system --timeout=3s --list tree "$owner" 2>/dev/null) || return 1
    while IFS= read -r path; do
        [[ $path =~ ^/org/bluez/hci[0-9]+/dev_([0-9a-fA-F]{2}_){5}[0-9a-fA-F]{2}$ ]] || continue
        uuids=$(bluez_property "$owner" "$path" org.bluez.Device1 UUIDs) || return 1
        has_classic=0
        has_le=0
        if [[ $uuids == *'"00001124-0000-1000-8000-00805f9b34fb"'* ]]; then has_classic=1; fi
        if [[ $uuids == *'"00001812-0000-1000-8000-00805f9b34fb"'* ]]; then has_le=1; fi
        (( has_classic || has_le )) || continue
        classic=$((classic + has_classic))
        le=$((le + has_le))
        for property in Paired Bonded Connected ServicesResolved; do
            value=$(bluez_property "$owner" "$path" org.bluez.Device1 "$property") || return 1
            case "$value" in
                'v b true') yes[$property]=$((yes[$property] + 1));;
                'v b false') ;;
                *) return 1;;
            esac
        done
    done <<< "$paths"
    [[ $(bluez_owner) == "$reply" ]] || return 1
    printf 'bluetooth.hid-peer-inventory=available\n'
    printf 'bluetooth.hid-classic-profile-peers=%s\nbluetooth.hid-le-profile-peers=%s\n' "$classic" "$le"
    printf 'bluetooth.hid-paired-peers=%s\nbluetooth.hid-bonded-peers=%s\n' "${yes[Paired]}" "${yes[Bonded]}"
    printf 'bluetooth.hid-connected-peers=%s\nbluetooth.hid-resolved-peers=%s\n' "${yes[Connected]}" "${yes[ServicesResolved]}"
}
hid_peers || printf 'bluetooth.hid-peer-inventory=unavailable\n'

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
