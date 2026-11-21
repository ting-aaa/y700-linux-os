#!/bin/bash
set -euo pipefail
cd /opt/y700-topology
[[ -n $XDG_SESSION_ID && $(id -u) == 1000 ]]
property() { loginctl show-session "$XDG_SESSION_ID" -p "$1" --value; }
[[ $(property Active) == yes && $(property Remote) == no && $(property Seat) == seat0 && $(property Type) == x11 ]]
echo 'UPDATER_SEAT active=1 remote=0 seat=seat0 type=x11 uid=1000'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C.UTF-8 LANGUAGE=en XDG_CURRENT_DESKTOP=XFCE GDK_SCALE=2
export GTK_USE_PORTAL=0 GDK_BACKEND=x11 NO_AT_BRIDGE=0
/usr/bin/xrandr --output DUMMY0 --mode portrait --primary --pos 0x0 --fb 1600x2560
dbus-run-session -- bash -ec '
    dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR GDK_SCALE NO_AT_BRIDGE
    xfwm4 --compositor=off >"$XDG_RUNTIME_DIR/wm.log" 2>&1 &
    for _ in {1..90}; do xprop -root _NET_SUPPORTING_WM_CHECK |grep -q "window id" && break; sleep .2; done
    exec ./uv run --offline --no-project --python /usr/bin/python3 python -B ./probe.py'
