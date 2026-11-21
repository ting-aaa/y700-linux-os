#!/bin/bash
set -euo pipefail
umask 077
[[ $(id -un) == y700 && -z $(ls -A /sys) && ! -e /dev/input && ! -e /dev/dri && ! -e /dev/snd ]]
[[ ! -e /run/dbus/system_bus_socket && -z $(find /dev -type b -print -quit) ]]
[[ $(awk '/CapEff:/ {print $2}' /proc/self/status) == 0000000000000000 ]]
if [[ ${1:-} == dev12.8 || ${1:-} == dev12.9 || ${1:-} == dev12.10 ]]; then
    # Provide the system-bus connection expected by desktop clients without a
    # logind, sensor proxy, host bus or any activatable service directory.
    export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/qa-system-bus"
    cat >"$XDG_RUNTIME_DIR/system.conf" <<'BUS'
<busconfig>
  <type>system</type>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/>
  </policy>
</busconfig>
BUS
    dbus-daemon --config-file="$XDG_RUNTIME_DIR/system.conf" --address="$DBUS_SYSTEM_BUS_ADDRESS" --fork
    [[ $(gdbus call --system --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.ListActivatableNames) == "(['org.freedesktop.DBus'],)" ]]
    dbus-update-activation-environment DBUS_SYSTEM_BUS_ADDRESS
fi
export XAUTHORITY="$XDG_RUNTIME_DIR/Xauthority"
{ printf '\377\377\000\000\000\00273\000\022MIT-MAGIC-COOKIE-1\000\020'; head -c 16 /dev/urandom; } >"$XAUTHORITY"
Xvfb "$DISPLAY" -screen 0 2560x1600x24 -auth "$XAUTHORITY" -nolisten tcp >"$XDG_RUNTIME_DIR/xvfb.log" 2>&1 &
xserver=$!
cleanup() {
    local rc=$?
    if (( rc )); then
        xwininfo -root -tree 2>/dev/null | grep -Ei 'Thunar|Onboard' | head -12 >&2 || :
        tail -12 "$XDG_RUNTIME_DIR/thunar.log" >&2 2>/dev/null || :
        ls -A "$HOME/Y700-RAM-check" >&2 2>/dev/null || :
    fi
    kill "$xserver" 2>/dev/null || :
}
trap cleanup EXIT
trap 'echo "RAM_USERSPACE desktop_failed_at_line=$LINENO" >&2' ERR
for _ in {1..60}; do xdpyinfo >/dev/null 2>&1 && break; kill -0 "$xserver"; sleep .1; done
xdpyinfo | awk '/dimensions:/ {found=($2=="2560x1600")} END {exit !found}'
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GDK_SCALE
xfce4-session >"$XDG_RUNTIME_DIR/session.log" 2>&1 &
xfce=$!
for process in xfwm4 xfce4-panel xfdesktop onboard; do
    for _ in {1..120}; do pgrep -x "$process" >/dev/null && break; kill -0 "$xfce"; sleep .2; done
    if ! pgrep -x "$process" >/dev/null; then
        echo "Missing candidate desktop process $process" >&2
        tail -35 "$XDG_RUNTIME_DIR/session.log" >&2
        exit 1
    fi
done
echo 'RAM_USERSPACE ordinary_xfce=xfwm4,panel,xfdesktop,onboard display=2560x1600 gtk_scale=2'
rc=0
if [[ ${1:-} == dev12.8 || ${1:-} == dev12.9 || ${1:-} == dev12.10 ]]; then
    export UV_CACHE_DIR="$XDG_RUNTIME_DIR/uv" UV_PYTHON_DOWNLOADS=never
    if pgrep -u "$(id -u)" -f '^(/usr/bin/python3 )?/usr/libexec/y700-ambient-backlight$' >/dev/null; then
        echo 'RAM_USERSPACE ambient_client=ordinary'
    else
        echo 'RAM_USERSPACE ambient_client=missing' >&2
        rc=1
    fi
    uv run --no-project --offline --python /usr/bin/python3 python -B /qa/brightness.py || rc=1
fi
bash /qa/thunar.sh || rc=1
exit "$rc"
