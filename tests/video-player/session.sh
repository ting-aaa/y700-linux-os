#!/bin/bash
set -euo pipefail
export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg XDG_SESSION_TYPE=x11 GDK_BACKEND=x11
dbus-update-activation-environment XAUTHORITY DISPLAY XDG_CURRENT_DESKTOP XDG_CONFIG_DIRS
xfsettingsd --no-daemon --replace > "$XDG_RUNTIME_DIR/xfsettingsd.log" 2>&1 &
settings=$!
xfwm4 --compositor=off > "$XDG_RUNTIME_DIR/xfwm4.log" 2>&1 &
wm=$!
trap 'kill "$wm" "$settings" 2>/dev/null || :' EXIT
timeout 20 gdbus wait --session org.xfce.SettingsDaemon
xfconf-query -c xsettings -p /Gdk/WindowScalingFactor | grep -Fx 2
xrandr --current | sed -n '1,15p'
xrandr --output DUMMY0 --mode 2560x1600
for opener in gio thunar; do
    /opt/video-userspace/uv run --offline --no-project --python /usr/bin/python3 \
        python -B /opt/video-userspace/check-x11.py --opener "$opener"
done
