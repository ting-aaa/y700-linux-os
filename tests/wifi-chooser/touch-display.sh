# Sourced by fixture-guest.sh on the private ARM64 radio test seat.
start_touch_display() {
    local run=/run/wifi-fixture display=:222 auth=/run/wifi-fixture/Xauthority
    grep -qw y700.touch_gesture_fixture=1 /proc/cmdline || return 1
    dpkg-deb -x /opt/wifi-test/dummy.deb /
    (umask 077; { printf '\377\377\000\000\000\003222\000\022MIT-MAGIC-COOKIE-1\000\020'; head -c16 /dev/urandom; } > "$auth")
    chown y700:y700 "$auth"
    mkfifo -m600 "$run/touch-command" "$run/touch-response"
    chown y700:y700 "$run/touch-command" "$run/touch-response"
    exec {command_fd}<>"$run/touch-command" {response_fd}<>"$run/touch-response"
    evdev-touch <&"$command_fd" >&"$response_fd" & pids+=("$!")
    local response
    IFS= read -r -t 10 -u "$response_fd" response && [[ $response =~ ^READY\ input[0-9]+$ ]] || return 1
    udevadm trigger --action=add --subsystem-match=input
    udevadm settle --timeout=10
    Xorg "$display" -config /opt/wifi-test/xorg.conf -auth "$auth" -nolisten tcp -noreset \
        -logfile "$run/Xorg.log" >/dev/null 2>&1 & pids+=("$!")
    for _ in {1..80}; do
        if DISPLAY="$display" XAUTHORITY="$auth" xinput list --id-only 'NT36523N Capacitive Touchscreen' >/dev/null 2>&1; then break; fi
        sleep .15
    done
    grep -Fq "Using input driver 'libinput' for 'NT36523N Capacitive Touchscreen'" "$run/Xorg.log" || return 1
    DISPLAY="$display" XAUTHORITY="$auth" xrandr --current | grep -q 'current 2560 x 1600' || return 1
    echo 'WIFI_INPUT virtual_type_b=1 xorg_libinput=1 pixels=2560x1600'
}
