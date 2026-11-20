#!/usr/bin/env bash
# Survey beacons once from the connected tablet. Print counts, never network identities.
set -euo pipefail
export LC_ALL=C
dev=$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '$2 == "wifi" && $3 == "connected" {print $1; exit}')
test -n "$dev" && test -d "/sys/class/net/$dev/phy80211"
assoc=$(nmcli -g GENERAL.CON-UUID device show "$dev")
state() { wpa_cli -i "$dev" status | sed -n '/^wpa_state=/p; /^freq=/p; /^key_mgmt=/p'; }
state
timeout 40 iw dev "$dev" scan passive | awk '
    function finish() {
        if (freq >= 2400 && freq < 2500) low++
        else if (freq >= 4900 && freq < 5925) mid++
        else if (freq >= 5925 && freq <= 7125) high++
    }
    /^BSS / {finish(); freq = 0}
    /^[[:space:]]*freq: [0-9]+/ {freq = $2}
    END {
        finish()
        printf "BSS observed by frequency: 2.4 GHz=%d, 5 GHz=%d, 6 GHz=%d\n", low, mid, high
        if (!low && !mid && !high) exit 1
    }'
test -n "$assoc" && test "$assoc" = "$(nmcli -g GENERAL.CON-UUID device show "$dev")"
state
