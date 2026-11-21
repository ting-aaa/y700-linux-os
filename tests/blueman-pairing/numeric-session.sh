#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == y700 && $DISPLAY == :1 ]]
export LC_ALL=C XDG_CURRENT_DESKTOP=XFCE GDK_BACKEND=x11 UV_CACHE_DIR="$XDG_RUNTIME_DIR/cache"
export HOME="$XDG_RUNTIME_DIR/home"
export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg
mkdir -m700 "$HOME"
dbus-update-activation-environment DISPLAY XAUTHORITY HOME XDG_CONFIG_DIRS XDG_CURRENT_DESKTOP XDG_RUNTIME_DIR GDK_BACKEND LC_ALL
xfsettingsd --no-daemon >"$HOME/xsettings.log" 2>&1 & settings=$!
trap 'kill "$settings" 2>/dev/null || :' EXIT
timeout 18 gdbus wait --session org.xfce.SettingsDaemon
[[ $(dpkg-query -W -f='${Version}' blueman) == 2.4.4-1+y7002 ]]
grep -Fxq Exec=blueman-applet /etc/xdg/autostart/blueman.desktop
observer=numeric-link.py
if grep -qw y700.blueman_keyboard=1 /proc/cmdline; then observer=keyboard-link.py; fi
./uv run --offline --no-project --python /usr/bin/python3 python -B "$observer"
