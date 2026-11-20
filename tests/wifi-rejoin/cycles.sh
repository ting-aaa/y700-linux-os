# Sourced only by the guarded, networkless QEMU Wi-Fi fixture.
wifi_rejoin_setup() {
    local extra_phy
    install -d -m755 /run/wifi-fixture/rejoin
    install -d -m700 -o y700 -g y700 /run/wifi-fixture/rejoin/user
    if (( rejoin >= 2 )); then
        alternate_ap=${radios[2]##*/}
        extra_phy=$(basename "$(readlink -f "/sys/class/net/$alternate_ap/phy80211")")
        [[ $extra_phy =~ ^phy[0-9]+$ ]] || fail rejoin-alternate-phy
        iw phy "$extra_phy" set netns name wifi-ap
        test ! -e "/sys/class/net/$alternate_ap" || fail rejoin-ap-namespace
        ap_l3=wifi-ap-br
        "${ap_net[@]}" ip link add name "$ap_l3" type bridge
        "${ap_net[@]}" ip link set "$ap_l3" up
    fi
}

wifi_rejoin_configs() {
    local base=/run/wifi-fixture/hostapd.conf
    # Two guest radios share the same test gateway and ESS. Only one hostapd
    # instance will be running at any time.
    printf 'bridge=%s\n' "$ap_l3" >> "$base"
    (umask 077; sed "s/^interface=.*/interface=$alternate_ap/" "$base" > "$base.alt")
}

wifi_rejoin_wait() {
    local deadline=$((SECONDS + $1)) label=$2
    shift 2
    until "$@"; do
        if (( SECONDS >= deadline )); then fail "$label"; fi
        sleep 0.3
    done
}

wifi_rejoin_down() {
    [[ $(station_state) != 100 ]] &&
        [[ $(iw dev "$station" link) == 'Not connected.' ]] &&
        [[ -z $(ip -4 -o address show dev "$station" scope global) ]]
}

wifi_rejoin_up() {
    [[ $(station_state) == 100 ]] &&
        [[ $(nmcli -g GENERAL.CON-UUID device show "$station") == "$uuid" ]] &&
        iw dev "$station" link | grep -Eq '^Connected to[[:space:]]'
}

wifi_rejoin_bssid() {
    iw dev "$station" link | awk '/^Connected to / {print $3}'
}

wifi_rejoin_verify_link() {
    local details peer ap_bssid
    peer=$(cat "/sys/class/net/$station/address")
    details=$(hostapd_cli -p /run/wifi-fixture/hostapd -i "$ap" sta "$peer")
    grep -Fxq 'AKMSuiteSelector=00-0f-ac-8' <<<"$details" || fail rejoin-sae
    grep -Eq '^flags=.*\[AUTHORIZED\].*\[MFP\]|^flags=.*\[MFP\].*\[AUTHORIZED\]' <<<"$details" || fail rejoin-pmf
    ap_bssid=$(hostapd_cli -p /run/wifi-fixture/hostapd -i "$ap" status |
        sed -n 's/^bssid\[0\]=//p')
    [[ -n $ap_bssid && $(wifi_rejoin_bssid) == "$ap_bssid" ]] || fail rejoin-wrong-ap
    ip -4 address show dev "$station" | grep -Eq 'inet 192\.0\.2\.(1[1-9])/24' || fail rejoin-ipv4
    nmcli -g DHCP4.OPTION device show "$station" |
        grep -Fq 'dhcp_server_identifier = 192.0.2.1' || fail rejoin-dhcp-server
    ip route get 192.0.2.1 oif "$station" | grep -Eq " dev $station " || fail rejoin-wifi-route
    ping -q -I "$station" -c 2 -W 1 192.0.2.1 >/dev/null || fail rejoin-bound-ping
}

wifi_rejoin_profile() {
    nmcli -g connection.autoconnect,802-11-wireless-security.key-mgmt,ipv4.method connection show uuid "$uuid"
}

wifi_rejoin_applet_ready() {
    if ! kill -0 "$seat_job"; then
        grep -E '^WIFI_(PROBE_ERROR|SEAT_ERROR|SESSION_ERROR) ' /run/wifi-fixture/seat-receipt >&2 || :
        fail rejoin-initial-app-interaction
    fi
    test -f /run/wifi-fixture/rejoin/user/ready
}

wifi_rejoin_cycles() {
    local root=/run/wifi-fixture/rejoin config=/run/wifi-fixture/hostapd.conf
    local i started original_bssid profile inventory activated previous_activation new_bssid expected_bssid
    local uuid
    wifi_rejoin_wait 110 rejoin-initial-app-interaction wifi_rejoin_applet_ready
    uuid=$(nmcli -g GENERAL.CON-UUID device show "$station")
    [[ $uuid =~ ^[a-f0-9-]{36}$ ]] || fail rejoin-initial-profile
    profile=$(wifi_rejoin_profile)
    [[ $profile == $'yes\nsae\nauto' ]] || fail rejoin-profile-not-automatic
    inventory=$(nmcli -t -f UUID connection show | sort)
    previous_activation=$(nmcli -g GENERAL.CON-PATH device show "$station")
    [[ $previous_activation == /org/freedesktop/NetworkManager/ActiveConnection/* ]] || fail rejoin-initial-activation
    wifi_rejoin_verify_link
    original_bssid=$(wifi_rejoin_bssid)
    echo 'WIFI_REJOIN_BASELINE applet=1 autoconnect=1 sae=1 pmf=1 dhcp=1 ping=1'
    if (( rejoin == 3 )); then
        wifi_crossband
        touch "$root/done"
        return
    fi
    for ((i=1; i<=rejoin+1; i++)); do
        kill -0 "$seat_job" || fail rejoin-seat-closed
        # Only stop the owned AP process. No client disconnect commands, scans,
        # connection activation, password entry or packet injection here.
        kill -TERM "$ap_process" || fail rejoin-ap-stop
        wait "$ap_process" || :
        wifi_rejoin_wait 25 rejoin-offline wifi_rejoin_down
        if ping -q -I "$station" -c 1 -W 1 192.0.2.1 >/dev/null 2>&1; then fail rejoin-ping-still-works; fi
        echo "WIFI_REJOIN_OFFLINE cycle=$i association=0 nm_active=0 ipv4=0 ping=0"
        if (( i == 3 )); then
            ap=$alternate_ap
            config=$config.alt
        fi
        started=$SECONDS
        "${ap_net[@]}" hostapd "$config" >/dev/null 2>&1 &
        ap_process=$!
        pids+=("$ap_process")
        wifi_rejoin_wait 15 rejoin-ap-did-not-return ap_ready
        wifi_rejoin_wait 66 rejoin-not-automatic wifi_rejoin_up
        [[ $(wifi_rejoin_profile) == "$profile" ]] || fail rejoin-profile-changed
        [[ $(nmcli -t -f UUID connection show | sort) == "$inventory" ]] || fail rejoin-profile-inventory-changed
        activated=$(nmcli -g GENERAL.CON-PATH device show "$station")
        [[ $activated == /org/freedesktop/NetworkManager/ActiveConnection/* &&
            $activated != "$previous_activation" ]] || fail rejoin-did-not-reactivate
        previous_activation=$activated
        wifi_rejoin_verify_link
        kill -0 "$seat_job" || fail rejoin-seat-closed
        new_bssid=$(wifi_rejoin_bssid)
        expected_bssid=same
        if (( i == 3 )); then
            expected_bssid=alternate
            [[ $new_bssid != "$original_bssid" ]] || fail rejoin-expected-alternate-bssid
        else
            [[ $new_bssid == "$original_bssid" ]] || fail rejoin-expected-same-bssid
        fi
        echo "WIFI_REJOIN_RECOVERED cycle=$i bssid=$expected_bssid elapsed_s=$((SECONDS-started)) same_profile=1 new_activation=1 sae=1 pmf=1 dhcp=1 ping=1"
    done
    touch "$root/done"
}
