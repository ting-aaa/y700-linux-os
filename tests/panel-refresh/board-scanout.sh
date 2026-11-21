#!/bin/bash
# Measure the advertised refresh rates on the DSI using the DRM vblank timestamps.
set -euo pipefail
export LC_ALL=C DISPLAY=:0 XAUTHORITY=/run/lightdm/root/:0
[[ $EUID == 0 && $# == 1 ]]
probe=$(realpath -e "$1")
grep -Fwq y700.panel_probe=60hz /proc/cmdline
[[ $(sha256sum /sys/kernel/notes | cut -d' ' -f1) == c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063 ]]
[[ $(findmnt -nro UUID -M /) == c0e447e4-82db-59ee-91d6-0e1ec9d5f45e ]]
sid=$(loginctl show-seat seat0 -p ActiveSession --value)
guard() {
    [[ $(loginctl show-seat seat0 -p Sessions --value) == "$sid" &&
       $(loginctl show-seat seat0 -p ActiveSession --value) == "$sid" &&
       $(loginctl show-session "$sid" -p Class --value) == greeter &&
       $(loginctl show-session "$sid" -p Type --value) == x11 ]]
}
guard
connector=(/sys/class/drm/card*-DSI-1)
[[ ${#connector[@]} == 1 && $(cat "${connector[0]}/status") == connected ]]
card=${connector[0]##*/}; card=/dev/dri/${card%-DSI-1}
mode=1600x2560
rate() {
    xrandr --current | awk -v mode="$mode" '
        $2 == "connected" {n++; d=($1=="DSI-1"); next}
        $2 == "disconnected" {d=0}
        d && $1==mode {for(i=2;i<=NF;i++) if ($i ~ /\*/) {r=$i+0; selected++}}
        END {if(n!=1 || selected!=1) exit 1; print r}'
}
lit() {
    [[ $(xset q | awk '/Monitor is/{print $3}') == On &&
       $(cat /sys/class/backlight/ktz8866-backlight/bl_power) == 0 ]]
}
measure() {
    local expected=$1 i
    guard && lit || return 1
    [[ $(rate) == "$expected" ]]
    for i in 1 2 3; do
        timeout -k 1 4 "$probe" "$card" | awk -v expected="$expected" '
            NR==1 {seq=$1; t=$2}
            END {
                count=$1-seq; delta=$2-t;
                if (NR!=16 || count<15 || delta<=0) exit 1;
                hz=1000000*count/delta;
                printf "PANEL_SCAN expected=%d intervals=%d delta_us=%d measured_hz=%.3f\n",expected,count,delta,hz;
                if (hz<expected*.98 || hz>expected*1.02) exit 1
            }'
    done
}
switch_rate() {
    guard && lit || return 1
    timeout -k 1 8 xrandr --output DSI-1 --mode "$mode" --rate "$1"
}
[[ $(rate) == 120 ]]
measure 120
dirty=0
cleanup() {
    local rc=$?
    trap - EXIT HUP INT TERM
    if (( dirty )) && guard && [[ $(rate) == 60 ]]; then switch_rate 120 || rc=1; fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cursor=$(journalctl -k -b -n0 --show-cursor --no-pager | sed -n 's/^-- cursor: //p')
[[ -n $cursor ]]
for pass in 1 2; do
    dirty=1
    switch_rate 60
    measure 60
    switch_rate 120
    measure 120
    dirty=0
done
recent=$(journalctl -k -b --after-cursor="$cursor" -o cat --no-pager -q)
if grep -Ei '(dsi|dpu|drm|vblank|crtc|underrun).*(timeout|timed out|fail|underflow|underrun)|pending.*ctl.*reset' <<<"$recent"; then exit 1; fi
echo 'PANEL_SCANOUT_PASS switches=4 original_and_final=120 connector=DSI-1'
