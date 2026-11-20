#!/usr/bin/env bash
# Run a single private Xfce tray and Wi-Fi applet on an authenticated Xvfb.
set -euo pipefail
bundle=$(cd -- "$(dirname -- "$0")" && pwd -P)
mode=${1:?physical or fixture}
security=${2:-open}
case "$mode" in physical|fixture) ;; *) exit 2;; esac
case "$mode:$security" in physical:open|fixture:open|fixture:wpa2|fixture:sae) ;; *) exit 2;; esac
if [[ ${3:-} != session ]]; then
    if [[ $mode == physical ]]; then test "$(id -u)" != 0; fi
    if [[ $mode == fixture ]]; then grep -qw 'y700.wifi_fixture=1' /proc/cmdline; fi
    run=$(mktemp -d "${TMPDIR:-/tmp}/y700-wifi-session.XXXXXXXX")
    test "$(realpath -e "$run")" = "$run"
    cleanup_run() {
        # GTK can start the document portal even when no file chooser is used.
        for _ in {1..30}; do
            if ! mountpoint -q "$run/runtime/doc"; then break; fi
            sleep 0.1
        done
        if mountpoint -q "$run/runtime/doc"; then
            fusermount3 -u "$run/runtime/doc"
        fi
        rm -r --one-file-system -- "$run"
    }
    trap cleanup_run EXIT
    export HOME=$run/home XDG_RUNTIME_DIR=$run/runtime
    export XDG_CONFIG_HOME=$HOME/.config XDG_CACHE_HOME=$HOME/.cache
    export XDG_DATA_HOME=$HOME/.local/share XDG_STATE_HOME=$HOME/.local/state
    export UV_CACHE_DIR=$XDG_CACHE_HOME/uv UV_OFFLINE=1 PYTHONUNBUFFERED=1
    export LC_ALL=C XDG_SESSION_TYPE=x11 GDK_BACKEND=x11 XDG_CURRENT_DESKTOP=XFCE
    export GTK_USE_PORTAL=0
    mkdir -m700 "$HOME" "$XDG_RUNTIME_DIR"
    unset DISPLAY XAUTHORITY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS AT_SPI_BUS_ADDRESS
    unset SESSION_MANAGER GTK_MODULES NO_AT_BRIDGE G_MESSAGES_DEBUG
    export PATH=$bundle/bin:/usr/local/bin:/usr/bin:/bin
    cd -- "$HOME"
    dbus-run-session -- bash "$bundle/session.sh" "$mode" "$security" session \
        2> >(grep --line-buffered -E '^(WIFI_PROBE_ERROR|WIFI_SESSION_ERROR) ' >&2) | grep --line-buffered -E '^WIFI_'
    exit
fi

py=(uv run --offline --no-project --python /usr/bin/python3 python)
export XAUTHORITY=$XDG_RUNTIME_DIR/Xauthority
display=
for n in {224..239}; do
    if [[ ! -e /tmp/.X11-unix/X$n && ! -e /tmp/.X$n-lock ]]; then display=$n; break; fi
done
test -n "$display"
export DISPLAY=:$display
"${py[@]}" - "$display" "$XAUTHORITY" <<'PY'
import os
import struct
import sys

with open(sys.argv[2], 'xb', opener=lambda path, flags: os.open(path, flags, 0o600)) as authority:
    authority.write(struct.pack('>H', 65535))
    for field in (b'', sys.argv[1].encode(), b'MIT-MAGIC-COOKIE-1', os.urandom(16)):
        authority.write(struct.pack('>H', len(field)) + field)
PY

mkdir -p "$XDG_CONFIG_HOME/xfce4/xfconf/xfce-perchannel-xml"
cp -- "$bundle/xfce4-panel.xml" "$XDG_CONFIG_HOME/xfce4/xfconf/xfce-perchannel-xml/"
if [[ $mode == fixture ]] && grep -Eq 'y700.wifi_attempt=(editor|onboard)( |$)' /proc/cmdline; then
    # Expose the image's standard Applications menu on this isolated panel.
    xml=$XDG_CONFIG_HOME/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml
    sed -i '/name="plugin-ids" type="array"/a\        <value type="int" value="2"/>' "$xml"
    sed -i '/name="plugins" type="empty"/a\    <property name="plugin-2" type="string" value="applicationsmenu"/>' "$xml"
fi
xp= wm= panel= applet= settings= keyboard=
cleanup_session() {
    for pid in "$keyboard" "$applet" "$panel" "$wm" "$settings" "$xp"; do
        if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    done
}
trap cleanup_session EXIT
screen=1024x768x24
unset Y700_WIFI_ONBOARD
if [[ $mode == fixture ]] && grep -qw y700.wifi_attempt=onboard /proc/cmdline; then
    screen=2560x1600x24
    export Y700_WIFI_ONBOARD=1 XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg
fi
Xvfb "$DISPLAY" -auth "$XAUTHORITY" -screen 0 "$screen" -nolisten tcp >/dev/null 2>&1 & xp=$!
for _ in {1..40}; do
    kill -0 "$xp" || { echo 'WIFI_SESSION_ERROR xvfb-exited' >&2; exit 1; }
    if xdpyinfo >/dev/null 2>&1; then break; fi
    sleep 0.1
done
xdpyinfo >/dev/null || { echo 'WIFI_SESSION_ERROR x-display-not-ready' >&2; exit 1; }
activation=(DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR HOME)
if [[ -n ${Y700_WIFI_ONBOARD:-} ]]; then activation+=(XDG_CONFIG_DIRS); fi
dbus-update-activation-environment "${activation[@]}"
# The session bus only hosts this private desktop and its accessibility bus.
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
    --method org.a11y.Bus.GetAddress >/dev/null 2>&1 || { echo 'WIFI_SESSION_ERROR accessibility-bus' >&2; exit 1; }
if [[ $security != open ]]; then xfwm4 --compositor=off >/dev/null 2>&1 & wm=$!; fi
if [[ -n ${Y700_WIFI_ONBOARD:-} ]]; then
    xfsettingsd --no-daemon >/dev/null 2>&1 & settings=$!
    timeout 20 gdbus wait --session org.xfce.SettingsDaemon
    onboard --startup-delay=2.0 >/dev/null 2>&1 & keyboard=$!
    timeout 30 gdbus wait --session org.onboard.Onboard
fi
xfce4-panel --disable-wm-check >/dev/null 2>&1 & panel=$!
if [[ -n ${Y700_WIFI_ONBOARD:-} ]]; then
    timeout 25 gdbus wait --session org.xfce.Panel
fi
agent_args=()
if [[ $security == open ]]; then agent_args+=(--no-agent); fi
nm-applet "${agent_args[@]}" >/dev/null 2>&1 & applet=$!
"${py[@]}" "$bundle/probe.py" "$mode" "$applet"
if [[ $mode == fixture ]] && grep -Eq 'y700.wifi_rejoin=[12]( |$)' /proc/cmdline; then
    "${py[@]}" "$bundle/rejoin/observer.py" "$applet"
fi
