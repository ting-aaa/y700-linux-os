#!/bin/bash
set -euo pipefail
cd /opt/y700-topology
[[ -n $XDG_SESSION_ID && $(id -u) == 1000 ]]
property() { loginctl show-session "$XDG_SESSION_ID" -p "$1" --value; }
[[ $(property Active) == yes && $(property Remote) == no && $(property Seat) == seat0 && $(property Type) == x11 ]]
echo 'UPDATER_SEAT active=1 remote=0 seat=seat0 type=x11 uid=1000'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C.UTF-8 LANGUAGE=en XDG_CURRENT_DESKTOP=XFCE GDK_SCALE=2
export GTK_USE_PORTAL=0 GDK_BACKEND=x11 NO_AT_BRIDGE=0
if [[ -e touch-auth-mode ]]; then
    xrandr --newmode landscape 268.50 2560 2608 2640 2720 1600 1603 1609 1646 +HSync -VSync
    xrandr --addmode DUMMY0 landscape
    xrandr --output DUMMY0 --mode landscape --primary --pos 0x0 --fb 2560x1600
    export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg
else
    /usr/bin/xrandr --output DUMMY0 --mode portrait --primary --pos 0x0 --fb 1600x2560
fi
dbus-run-session -- bash -ec '
    dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR GDK_SCALE NO_AT_BRIDGE
    xfwm4 --compositor=off >"$XDG_RUNTIME_DIR/wm.log" 2>&1 &
    for _ in {1..90}; do xprop -root _NET_SUPPORTING_WM_CHECK |grep -q "window id" && break; sleep .2; done
    if [[ -e touch-auth-mode ]]; then
        dbus-update-activation-environment XDG_CONFIG_DIRS XDG_CURRENT_DESKTOP
        xfsettingsd --no-daemon >"$XDG_RUNTIME_DIR/settings.log" 2>&1 &
        timeout 40 gdbus wait --session org.xfce.SettingsDaemon
        gio launch /etc/xdg/autostart/polkit-mate-authentication-agent-1.desktop
        gio launch /etc/xdg/autostart/y700-onboard.desktop
        timeout 65 gdbus wait --session org.onboard.Onboard
    fi
    exec ./uv run --offline --no-project --python /usr/bin/python3 python -B ./probe.py'
