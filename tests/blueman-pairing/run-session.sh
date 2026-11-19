#!/usr/bin/env bash
set -euo pipefail
bundle=/opt/blueman-pairing
runtime=/run/blueman-pairing
test "$(id -un)" = y700
test -d "$runtime"
test ! -e /sys/class/bluetooth
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
set -euo pipefail
bundle=/opt/blueman-pairing
py=("$bundle/uv" run --offline --no-project --python /usr/bin/python3 python)
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/system"
export DISPLAY=:226
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
Xvfb "$DISPLAY" -screen 0 2560x1600x24 -nolisten tcp >"$HOME/xvfb.log" 2>&1 &
children+=("$!")
for _ in {1..50}; do if xdpyinfo >/dev/null 2>&1; then break; fi; sleep .1; done
xdpyinfo >/dev/null 2>&1
dbus-update-activation-environment DISPLAY GDK_BACKEND XDG_CURRENT_DESKTOP XDG_RUNTIME_DIR HOME
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
    --method org.a11y.Bus.GetAddress >/dev/null
xfconf-query -c xsettings -p /Gdk/WindowScalingFactor -n -t int -s 2
xfconf-query -c xsettings -p /Xft/DPI -n -t int -s 192
xfsettingsd --no-daemon --replace >"$HOME/xfsettingsd.log" 2>&1 &
children+=("$!")
timeout 15 gdbus wait --session org.xfce.SettingsDaemon
"${py[@]}" -m dbusmock --system -t bluez5 >"$HOME/bluez-mock.log" 2>&1 &
children+=("$!")
"${py[@]}" "$bundle/probe.py"
SESSION
