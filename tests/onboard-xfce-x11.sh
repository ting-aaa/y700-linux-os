#!/usr/bin/env bash
# Verify the installed platform package through the real Xfce session autostart.
set -euo pipefail

if [[ ${1:-} != --session ]]; then
    mode=${1:-fresh}
    [[ $mode == fresh || $mode == opt-out ]] || exit 2
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    mkdir -m 700 "$work/home" "$work/config" "$work/cache" "$work/run" "$work/state" "$work/tmp"
    export HOME=$work/home XDG_CONFIG_HOME=$work/config XDG_CACHE_HOME=$work/cache
    export XDG_RUNTIME_DIR=$work/run XDG_STATE_HOME=$work/state TMPDIR=$work/tmp
    export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=xfce
    export XDG_CONFIG_DIRS=/etc/xdg XDG_DATA_DIRS=/usr/local/share:/usr/share LC_ALL=C.UTF-8
    unset DISPLAY WAYLAND_DISPLAY XAUTHORITY GSETTINGS_BACKEND GSETTINGS_SCHEMA_DIR NO_AT_BRIDGE AT_SPI_BUS_ADDRESS SESSION_MANAGER
    dbus-run-session -- bash "$0" --session "$mode"
    exit
fi

mode=$2
session= entry=
Xvfb -displayfd 3 -screen 0 1280x800x24 -nolisten tcp 3>"$XDG_RUNTIME_DIR/display" &
xserver=$!
cleanup() {
    if [[ -n $entry ]]; then kill "$entry" 2>/dev/null || true; fi
    if [[ -n $session ]]; then kill "$session" 2>/dev/null || true; fi
    kill "$xserver" 2>/dev/null || true
}
trap cleanup EXIT

for _ in {1..100}; do
    [[ ! -s "$XDG_RUNTIME_DIR/display" ]] || break
    sleep 0.1
done
export DISPLAY=":$(cat "$XDG_RUNTIME_DIR/display")"
xdpyinfo >/dev/null
dbus-update-activation-environment DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE

toolkit=(org.gnome.desktop.interface toolkit-accessibility)
autoshow=(org.onboard.auto-show enabled)
height=(org.onboard.window.landscape dock-height)
if [[ $mode == opt-out ]]; then
    gsettings set "${toolkit[@]}" false
    gsettings set "${autoshow[@]}" false
    gsettings set "${height[@]}" 356
    gsettings set org.onboard start-minimized true
fi

xfce4-session >"$XDG_RUNTIME_DIR/session.log" 2>&1 &
session=$!
keyboard_visible() {
    local owner
    owner=$(gdbus call --session --timeout 1 --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.GetNameOwner \
        org.onboard.Onboard 2>/dev/null | sed -nE "s/^\('(:[0-9.]+)',\)$/\1/p")
    [[ -n $owner ]] || return 1
    gdbus call --session --timeout 1 --dest "$owner" \
        --object-path /org/onboard/Onboard/Keyboard --method org.freedesktop.DBus.Properties.Get \
        org.onboard.Onboard.Keyboard Visible 2>/dev/null
}
wait_visible() {
    for _ in {1..120}; do
        [[ $(keyboard_visible) != "(<$1>,)" ]] || return 0
        sleep 0.1
    done
    echo "Expected Onboard Visible=$1" >&2
    tail -60 "$XDG_RUNTIME_DIR/session.log" >&2
    xwininfo -root -tree | grep -Ei 'onboard|thunar' >&2 || true
    return 1
}

wait_visible false
for _ in {1..120}; do
    [[ ! -e "$XDG_STATE_HOME/y700/desktop-defaults-v1" ]] || break
    sleep 0.1
done
test -f "$XDG_STATE_HOME/y700/desktop-defaults-v1"
if [[ $mode == fresh ]]; then
    [[ $(gsettings get "${toolkit[@]}") == true && $(gsettings get "${autoshow[@]}") == true ]]
    [[ $(gsettings get "${height[@]}") == 420 ]]
    gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
        --method org.a11y.Bus.GetAddress >/dev/null
else
    [[ $(gsettings get "${toolkit[@]}") == false && $(gsettings get "${autoshow[@]}") == false ]]
    [[ $(gsettings get "${height[@]}") == 356 ]]
    [[ $(gsettings get org.onboard start-minimized) == true ]]
fi

mkdir "$HOME/keyboard-fixture"
thunar "$HOME/keyboard-fixture" >"$XDG_RUNTIME_DIR/thunar.log" 2>&1 &
entry=$!
window=$(timeout 20 xdotool search --sync --onlyvisible --name '^keyboard-fixture - Thunar$')
xdotool windowactivate --sync "$window"
xdotool key ctrl+l
if [[ $mode == fresh ]]; then
    wait_visible true
    xdotool key alt+F4
    wait_visible false
    echo 'PASS: fresh Xfce account, AT-SPI focus showed Onboard without a modal and blur hid it.'
else
    sleep 2
    [[ $(keyboard_visible) == '(<false>,)' ]]
    echo 'PASS: explicit accessibility, auto-show, startup and dock-height choices survived a first Xfce login.'
fi
