#!/usr/bin/env bash
# Use a private X11 display while keeping the ordinary user's real system bus.
set -euo pipefail
bundle=$(cd -- "$(dirname -- "$0")" && pwd -P)
lang=${1:?en or zh}
shift
case "$lang" in
    en) export LANG=en_US.UTF-8 LANGUAGE=en ;;
    zh) export LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh ;;
    *) exit 2 ;;
esac
test "$(id -u)" != 0
unset LC_ALL DISPLAY XAUTHORITY WAYLAND_DISPLAY SESSION_MANAGER GTK_MODULES NO_AT_BRIDGE
unset AT_SPI_BUS_ADDRESS DBUS_SESSION_BUS_ADDRESS GDK_SCALE GDK_DPI_SCALE
home=$(mktemp -d /tmp/y700-brightness-session.XXXXXXXX)
[[ $(realpath -e "$home") == "$home" ]]
xp=
cleanup() {
    local result=$?
    if (( result != 0 )); then
        for log in xvfb settings application; do
            if [[ -e $home/$log.log ]]; then tail -15 "$home/$log.log"; fi
        done
    fi
    if [[ -n $xp ]]; then kill "$xp" 2>/dev/null || :; wait "$xp" 2>/dev/null || :; fi
    rm -r --one-file-system -- "$home"
}
trap cleanup EXIT
export HOME=$home XDG_RUNTIME_DIR=$home/runtime XDG_DATA_HOME=$home/data
export XDG_CONFIG_HOME=$home/config XDG_CACHE_HOME=$home/cache XDG_STATE_HOME=$home/state
export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg
export XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 GDK_BACKEND=x11 GTK_USE_PORTAL=0
export PATH=$bundle/bin:/usr/bin:/bin
export UV_OFFLINE=1 UV_CACHE_DIR=$home/cache/uv PYTHONDONTWRITEBYTECODE=1
mkdir -m 700 "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME"
py=(uv run --offline --no-project --python /usr/bin/python3 python)
for number in {241..255}; do
    if [[ ! -e /tmp/.X11-unix/X$number && ! -e /tmp/.X$number-lock ]]; then
        export DISPLAY=:$number XAUTHORITY=$home/Xauthority
        break
    fi
done
test -n "${DISPLAY:-}"
"${py[@]}" - "${DISPLAY#:}" "$XAUTHORITY" <<'PY'
import os
import struct
import sys

with open(sys.argv[2], "xb", opener=lambda path, flags: os.open(path, flags, 0o600)) as authority:
    authority.write(struct.pack(">H", 65535))
    for field in (b"", sys.argv[1].encode(), b"MIT-MAGIC-COOKIE-1", os.urandom(16)):
        authority.write(struct.pack(">H", len(field)) + field)
PY
Xvfb "$DISPLAY" -auth "$XAUTHORITY" -screen 0 1600x2560x24 -nolisten tcp >"$home/xvfb.log" 2>&1 & xp=$!
for _ in {1..60}; do
    if xdpyinfo >/dev/null 2>&1; then break; fi
    kill -0 "$xp"
    sleep .10
done
xdpyinfo >/dev/null

# Only the executable path differs from the installed Settings menu item.
desktop=$home/y700-tablet-brightness.desktop
sed "s|^Exec=.*|Exec=uv run --offline --no-project --python /usr/bin/python3 python $bundle/y700-tablet-brightness|" \
    "$bundle/y700-tablet-brightness.desktop" >"$desktop"
dbus-run-session -- bash -ec '
    bundle=$1
    home=$2
    desktop=$3
    shift 3
    dbus-update-activation-environment DISPLAY XAUTHORITY HOME XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP
    xfsettingsd --no-daemon --replace >"$home/settings.log" 2>&1 &
    settings=$!
    trap "kill $settings 2>/dev/null || :" EXIT
    timeout 15 gdbus wait --session org.xfce.SettingsDaemon
    gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress >/dev/null
    gio launch "$desktop" >"$home/application.log" 2>&1
    uv run --offline --no-project --python /usr/bin/python3 python "$bundle/probe.py" "$@"
' bash "$bundle" "$home" "$desktop" "$lang" "$@"
