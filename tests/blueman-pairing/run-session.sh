#!/usr/bin/env bash
set -euo pipefail
bundle=/opt/blueman-pairing
runtime=/run/blueman-pairing
test "$(id -un)" = y700
test -d "$runtime"
if [[ ${BLUEMAN_TYPE_B:-0} == 1 ]]; then
    grep -qw y700.topology_fixture=1 /proc/cmdline
    [[ ! -d /sys/class/bluetooth || -z $(ls -A /sys/class/bluetooth) ]]
else
    test ! -e /sys/class/bluetooth
fi
export BLUEMAN_EXPECTED_VERSION=${1:?expected package version}
export LC_ALL=C PATH=/usr/local/bin:/usr/bin:/bin
export HOME=$runtime/home XDG_RUNTIME_DIR=$runtime/user
export XDG_CONFIG_HOME=$HOME/.config XDG_CACHE_HOME=$HOME/.cache
export XDG_DATA_HOME=$HOME/.local/share XDG_STATE_HOME=$HOME/.local/state
export UV_CACHE_DIR=$XDG_CACHE_HOME/uv UV_OFFLINE=1
export GDK_BACKEND=x11 XDG_CURRENT_DESKTOP=XFCE GTK_USE_PORTAL=0
unset LD_LIBRARY_PATH WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS
unset DBUS_SYSTEM_BUS_ADDRESS AT_SPI_BUS_ADDRESS NO_AT_BRIDGE GTK_MODULES
mkdir -m700 "$HOME" "$XDG_RUNTIME_DIR"
cd "$HOME"
test "$(dpkg --print-architecture)" = arm64
test "$(dpkg-query -W -f='${Version}' blueman)" = "$BLUEMAN_EXPECTED_VERSION"
grep -Fxq Exec=blueman-applet /etc/xdg/autostart/blueman.desktop
printf 'BLUEMAN_PACKAGES architecture=arm64 blueman=%s\n' "$BLUEMAN_EXPECTED_VERSION"
exec dbus-run-session -- /bin/bash -s <<'SESSION'
set -Eeu -o pipefail
trap 'echo BLUEMAN_SESSION_FAIL line=$LINENO >&2' ERR
bundle=/opt/blueman-pairing
py=("$bundle/uv" run --offline --no-project --python /usr/bin/python3 python)
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/system"
export DISPLAY=:226
if [[ ${BLUEMAN_TYPE_B:-0} == 1 ]]; then
    grep -qw y700.topology_fixture=1 /proc/cmdline
    grep -zFxq linux,dummy-virt /proc/device-tree/compatible
    test -p /run/topology/feed
    export DISPLAY=:1 XAUTHORITY=/run/topology/Xauthority
fi
children=()
cleanup() {
    for pid in "${children[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${children[@]}"; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT
dbus-daemon --session --address="$DBUS_SYSTEM_BUS_ADDRESS" --nofork >"$HOME/system.log" 2>&1 &
children+=("$!")
for _ in {1..40}; do [[ ! -S $XDG_RUNTIME_DIR/system ]] || break; sleep .1; done
test -S "$XDG_RUNTIME_DIR/system"
geometry=2560x1600
if [[ -f "$bundle/orientation" && $(cat "$bundle/orientation") == portrait ]]; then geometry=1600x2560; fi
if [[ ${BLUEMAN_TYPE_B:-0} != 1 ]]; then
    Xvfb "$DISPLAY" -screen 0 "${geometry}x24" -nolisten tcp >"$HOME/xvfb.log" 2>&1 &
    children+=("$!")
fi
for _ in {1..50}; do if xdpyinfo >/dev/null 2>&1; then break; fi; sleep .1; done
xdpyinfo >/dev/null 2>&1
dbus-update-activation-environment DISPLAY GDK_BACKEND XDG_CURRENT_DESKTOP XDG_RUNTIME_DIR HOME ${XAUTHORITY:+XAUTHORITY}
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
    --method org.a11y.Bus.GetAddress >/dev/null
xfconf-query -c xsettings -p /Gdk/WindowScalingFactor -n -t int -s 2
dpi=192
if [[ -f "$bundle/manager.py" ]]; then dpi=96; fi
xfconf-query -c xsettings -p /Xft/DPI -n -t int -s "$dpi"
xfsettingsd --no-daemon --replace >"$HOME/xfsettingsd.log" 2>&1 &
children+=("$!")
timeout 15 gdbus wait --session org.xfce.SettingsDaemon
if [[ ${BLUEMAN_TOUCH_ENTRY:-0} == 1 ]]; then
    wm=(xfwm4 --compositor=off)
    if [[ ${BLUEMAN_TYPE_B:-0} == 1 ]]; then
        # Xfwm uses the guest's own system bus. Only Blueman and its peers
        # use our mock radio bus. No host bus is available inside QEMU.
        wm=(env NO_AT_BRIDGE=1 GDK_SCALE=2 DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket "${wm[@]}")
    fi
    "${wm[@]}" >"$HOME/window-manager.log" 2>&1 &
    wm_pid=$!
    children+=("$!")
    for _ in {1..120}; do
        if xprop -root _NET_SUPPORTING_WM_CHECK | grep -q 'window id # 0x'; then break; fi
        sleep .3
    done
    if ! xprop -root _NET_SUPPORTING_WM_CHECK | grep -q 'window id # 0x'; then
        cat "$HOME/window-manager.log" >&2
        ps -o pid,stat,etime,wchan:20,comm -p "$wm_pid" >&2 || :
        xprop -root _NET_SUPPORTING_WM_CHECK >&2
        echo 'Missing Xfwm window manager' >&2
        exit 1
    fi
    if [[ ! -f "$bundle/manager.py" ]]; then
        onboard >"$HOME/onboard.log" 2>&1 &
        children+=("$!")
        timeout 25 gdbus wait --session org.onboard.Onboard
    fi
fi
"${py[@]}" -m dbusmock --system -t bluez5 >"$HOME/bluez-mock.log" 2>&1 &
children+=("$!")
if [[ -f "$bundle/manager.py" ]]; then
    "${py[@]}" -B "$bundle/manager.py"
else
    "${py[@]}" "$bundle/probe.py"
fi
SESSION
