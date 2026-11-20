# Sourced inside the three-radio QEMU fixture; both APs share its private bridge.
wifi_crossband() {
    local base_ap=$ap phase mhz cfg ack frames gap old_pid client
    local py=(uv run --offline --no-project --python /usr/bin/python3 python -B rejoin/stream.py)
    printf '0\n' > "$root/epoch"
    "${ap_net[@]}" "${py[@]}" server & pids+=("$!")
    wifi_rejoin_wait 10 tcp-listener test -f "$root/listening"
    "${py[@]}" "$station" & client=$!; pids+=("$client")
    wifi_rejoin_wait 10 tcp-initial test -s "$root/ack"
    iw dev "$station" link | grep -Eq 'freq: 2412(\.0)?$' || fail tcp-initial-band
    for phase in 1 2; do
        old_pid=$ap_process
        if (( phase == 1 )); then
            ap=$alternate_ap; mhz=5180; cfg=$config.alt
        else
            ap=$base_ap; mhz=2412; cfg=$config
        fi
        "${ap_net[@]}" hostapd "$cfg" >"$root/ap-start" 2>&1 & ap_process=$!; pids+=("$ap_process")
        sleep .5
        if ! kill -0 "$ap_process" 2>/dev/null; then
            grep -Ei 'frequency|channel|not allowed|could not|failed' "$root/ap-start" | head -5 || :
            fail tcp-destination-ap-start
        fi
        wifi_rejoin_wait 15 tcp-destination-ap ap_ready
        # Switching off the old AP is the only mobility stimulus.
        kill -TERM "$old_pid"
        wait "$old_pid" || :
        wifi_rejoin_wait 65 tcp-crossband-association bash -c 'iw dev "$1" link | grep -Eq "freq: ${2}(\\.0)?$"' _ "$station" "$mhz"
        wifi_rejoin_wait 15 tcp-profile-active wifi_rejoin_up
        wifi_rejoin_verify_link
        [[ $(wifi_rejoin_profile) == "$profile" && $(nmcli -t -f UUID connection show | sort) == "$inventory" ]] || fail tcp-profile-inventory
        printf '%s\n' "$phase" > "$root/epoch.tmp"; mv "$root/epoch.tmp" "$root/epoch"
        wifi_rejoin_wait 70 tcp-ack-after-band grep -q "^$phase " "$root/ack"
        echo "WIFI_TCP_CHECKPOINT mhz=$mhz sae=1 pmf=1 dhcp=1 retained_socket=1 fresh_sha=1"
    done
    printf '3\n' > "$root/epoch.tmp"; mv "$root/epoch.tmp" "$root/epoch"
    wait "$client" || fail tcp-stream
    read -r ack frames gap < "$root/ack"
    [[ $ack == 3 ]] || fail tcp-finish
    echo "WIFI_TCP_BANDS mhz=2412,5180,2412 one_connection=1 verified_frames=$frames bytes_each_way=$((4096*frames)) longest_ack_gap_s=$gap"
}
