#!/usr/bin/env bash
# Run as an ordinary user in a disposable Debian 13 Xfce test guest.
set -euo pipefail
if (( EUID == 0 )); then
    echo 'Use an ordinary user in a disposable Debian desktop guest.' >&2
    exit 2
fi
fixture=$(cd -- "$(dirname -- "$0")" && pwd)
if [[ ${1:-} != --session ]]; then
    case "${1:-desktop}" in
        desktop|transport|timing-fresh|timing-existing|first-login|first-login-shortcut|first-login-existing) ;;
        *) echo 'Usage: run.sh [desktop|transport|timing-fresh|timing-existing|first-login[-shortcut|-existing]]' >&2; exit 2 ;;
    esac
    export QA_UV QA_PACTL QA_HELPER
    QA_UV=$(command -v uv)
    QA_HELPER=${Y700_PANEL_QA_HELPER:-/usr/libexec/y700-panel-audio}
    test -x "$QA_HELPER"
    if [[ ${1:-desktop} != timing-* ]]; then
        QA_PACTL=$(command -v "${Y700_PANEL_QA_PACTL:-pactl}")
        test -r /etc/xdg/autostart/y700-session.desktop
    fi
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    export HOME=$work/home XDG_RUNTIME_DIR=$work/run XDG_CONFIG_HOME=$work/config
    export XDG_STATE_HOME=$work/state XDG_CACHE_HOME=$work/cache XDG_DATA_HOME=$work/data
    export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg XDG_DATA_DIRS=/usr/share
    export XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 GDK_BACKEND=x11 LC_ALL=C.UTF-8
    export UV_CACHE_DIR=$XDG_CACHE_HOME/uv
    export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$work/no-system-bus"
    mkdir -m 700 "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
    unset DISPLAY WAYLAND_DISPLAY XAUTHORITY SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
    unset GDK_SCALE GDK_DPI_SCALE GSETTINGS_BACKEND GSETTINGS_SCHEMA_DIR
    unset PULSE_SERVER PULSE_SINK PIPEWIRE_REMOTE PIPEWIRE_RUNTIME_DIR
    if ! timeout -k 5 200 dbus-run-session -- bash "$0" --session "${1:-desktop}"; then
        for file in "$work/run/"*.log; do
            [[ -f $file ]] || continue
            echo "=== ${file##*/} ===" >&2
            tail -n 20 "$file" >&2
        done
        exit 1
    fi
    exit
fi

mode=$2
run_probe() {
    "$QA_UV" run --offline --no-project --python /usr/bin/python3 python "$@"
}
if [[ $mode == timing-* ]]; then
    run_probe "$fixture/timing.py" "$QA_HELPER" "${mode#timing-}"
    exit
fi
if [[ -e /dev/snd ]]; then
    echo 'The desktop fixture must not have an ALSA device.' >&2
    exit 2
fi

declare -a pids=()
stop() {
    if (( ${#pids[@]} )); then
        kill "${pids[@]}" 2>/dev/null || true
        wait "${pids[@]}" 2>/dev/null || true
    fi
}
trap stop EXIT
cd "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d"
cat >"$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/90-test.conf" <<'WIREPLUMBER'
wireplumber.profiles = {
  main = {
    hardware.audio = disabled
    hardware.bluetooth = disabled
    hardware.video-capture = disabled
  }
}
WIREPLUMBER

Xvfb -displayfd 3 -screen 0 2560x1600x24 -nolisten tcp 3>display >x.log 2>&1 &
pids+=("$!")
for _ in {1..100}; do [[ ! -s display ]] || break; sleep 0.1; done
export DISPLAY=":$(cat display)"
xdpyinfo >/dev/null
dbus-update-activation-environment DISPLAY XDG_RUNTIME_DIR
if [[ $mode == first-login* ]]; then
    export Y700_PANEL_ORIGINAL_CONFIG_DIRS=$XDG_CONFIG_DIRS
    run_probe "$fixture/first-login.py" prepare "$mode"
    BASESTARTUP=xfce4-session
    . /etc/X11/Xsession.d/61y700_panel_default
    run_probe "$fixture/first-login.py" verify-pre-start "$mode"
fi
if [[ $mode == transport ]]; then
    shortcut=(xfconf-query -c xfce4-keyboard-shortcuts)
    "${shortcut[@]}" -p /xfwm4/custom/override -n -t bool -s true
    "${shortcut[@]}" -p /xfwm4/custom/XF86AudioPlay -n -t string -s show_desktop_key
fi

xfsettingsd --no-daemon >settings.log 2>&1 &
pids+=("$!")
xfwm4 --compositor=off >xfwm.log 2>&1 &
pids+=("$!")
pipewire >pipewire.log 2>&1 &
pids+=("$!")
for _ in {1..100}; do [[ ! -S pipewire-0 ]] || break; sleep 0.1; done
test -S pipewire-0
wireplumber >wireplumber.log 2>&1 &
pids+=("$!")
pipewire-pulse >pulse.log 2>&1 &
pids+=("$!")
for _ in {1..100}; do [[ ! -S pulse/native ]] || break; sleep 0.1; done
test -S pulse/native
export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"
sink=y700_test_sink
"$QA_PACTL" load-module module-null-sink sink_name="$sink" channels=2 channel_map=front-left,front-right
for _ in {1..100}; do
    [[ $("$QA_PACTL" get-default-sink 2>/dev/null) != "$sink" ]] || break
    sleep 0.1
done
test "$("$QA_PACTL" get-default-sink)" = "$sink"
pw-cat --playback --raw --target "$sink" --rate 48000 --channels 2 --format s16 - </dev/zero >stream.log 2>&1 &
pids+=("$!")
# The Pulse volume bridge needs an actual negotiated PCM format.
for _ in {1..100}; do "$QA_PACTL" list short sinks | grep -F 'RUNNING' -q && break; sleep 0.1; done
"$QA_PACTL" list short sinks | grep -F 'RUNNING'
"$QA_PACTL" set-sink-volume "$sink" 40%
"$QA_PACTL" set-sink-mute "$sink" 1
if [[ $mode == first-login* ]]; then
    run_probe "$fixture/first-login.py" verify "$mode"
else
    run_probe "$fixture/desktop.py" "$mode"
fi
