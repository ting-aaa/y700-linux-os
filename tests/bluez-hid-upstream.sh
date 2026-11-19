#!/bin/sh
# Run the BlueZ 5.82 native suites from a configured, built Debian source tree.
# Configure with --enable-testing. Run make first to generate BlueZ's local headers,
# then make unit/test-hog unit/test-uhid tools/mgmt-tester.
# Default cases use socketpairs and /dev/null. The guest option adds kernel UHID
# mouse creation and pairing through VHCI on an empty, headless disposable guest.
set -eu
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 BUILT_BLUEZ_TREE [--virtual-kernel]" >&2
    exit 2
fi
bluez=$1
mode=${2:-}
if [ -n "$mode" ]; then
    [ "$mode" = --virtual-kernel ]
    case " $(cat /proc/cmdline) " in
        *' y700.bluez_fixture=1 '*) ;;
        *) echo 'The virtual kernel checks require a marked test guest.' >&2; exit 2 ;;
    esac
    [ -c /dev/uhid ]
    [ -c /dev/vhci ]
    [ "$(id -u)" = 0 ]
    [ -d /sys/class/bluetooth ]
    [ -z "$(ls /sys/class/bluetooth)" ]
fi

log=$(mktemp)
trap 'rm -f -- "$log"' EXIT
check() {
    title=$1 count=$2
    shift 2
    if timeout 90 "$@" >"$log" 2>&1 &&
        grep -q "Total: $count," "$log" &&
        grep -Fq "Passed: $count (100.0%)" "$log" &&
        grep -q 'Not Run: 0' "$log"; then
        printf 'PASS %s (%s/%s)\n' "$title" "$count" "$count"
    else
        printf 'FAIL %s\n' "$title" >&2
        grep 'Total:' "$log" >&2 || :
        return 1
    fi
}

check 'HoG ATT host transactions' 6 "$bluez/unit/test-hog"
check 'UHID commands via socketpair' 4 "$bluez/unit/test-uhid" -p /uhid/command/
check 'UHID callbacks via socketpair' 2 "$bluez/unit/test-uhid" -p /uhid/event/
if [ "$mode" = --virtual-kernel ]; then
    check 'MX Anywhere 3 descriptor via guest /dev/uhid' 1 "$bluez/unit/test-uhid" -p /uhid/device/mx_anywhere_3
    for scenario in 'SSP Confirm Success 1' 'LE Success 2' 'LE SC Success 2'; do
        check "Pair Device - $scenario" 1 "$bluez/tools/mgmt-tester" -p "Pair Device - $scenario"
    done
fi
