#!/usr/bin/env bash
# Run with y700-platform, Xvfb, xdotool and Thunar installed, as a desktop user.
set -euo pipefail
if [[ ${1:-} != --session ]]; then
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    for state in external fresh empty standard; do
        export HOME=$work/$state XDG_CONFIG_HOME=$work/$state/.config
        export XDG_RUNTIME_DIR=$work/$state/run
        mkdir -pm 700 "$XDG_RUNTIME_DIR"
        export XDG_CONFIG_DIRS=/etc/xdg
        if [[ $state != external ]]; then
            XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:$XDG_CONFIG_DIRS
        fi
        if [[ $state == empty || $state == standard ]]; then
            folder=$XDG_CONFIG_HOME/xfce4/xfconf/xfce-perchannel-xml
            mkdir -p "$folder"
            value='type="empty"'
            [[ $state != standard ]] || value='type="int" value="1"'
            printf '<channel name="xsettings" version="1.0"><property name="Gdk" type="empty"><property name="WindowScalingFactor" %s/></property></channel>\n' "$value" > "$folder/xsettings.xml"
        fi
        unset AT_SPI_BUS_ADDRESS GDK_SCALE GDK_DPI_SCALE WAYLAND_DISPLAY
        export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE LC_ALL=C
        dbus-run-session -- bash "$0" --session "$state" | tee "$work/$state.log"
    done
    width() { sed -n 's/^THUNAR_WIDTH=//p' "$work/$1.log"; }
    [[ $(width external) -gt 0 && $(width fresh) -eq $(( $(width external) * 2 )) ]]
    [[ $(width empty) -eq $(width fresh) && $(width standard) -eq $(width external) ]]
    echo 'PASS inherited tablet scale, persisted override and actual GTK window widths'
    exit
fi

state=$2
Xvfb -displayfd 3 -screen 0 1600x2560x24 -nolisten tcp 3>"$XDG_RUNTIME_DIR/display" &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in {1..100}; do [[ ! -s $XDG_RUNTIME_DIR/display ]] || break; sleep .1; done
export DISPLAY=":$(cat "$XDG_RUNTIME_DIR/display")"
xdpyinfo >/dev/null
expected=1
[[ $state != fresh && $state != empty ]] || expected=2
[[ $(xfconf-query -c xsettings -p /Gdk/WindowScalingFactor) == "$expected" ]]
# This setting comes from Debian's own xsettings.xml.
xfconf-query -c xsettings -p /Net/ThemeName >/dev/null
xfsettingsd --no-daemon --replace &
settings=$!
trap 'kill "$settings" "$server" 2>/dev/null || true' EXIT
# Wait until xfsettingsd has registered its session bus service.
timeout 20 gdbus wait --session org.xfce.SettingsDaemon
thunar "$HOME" >/dev/null 2>&1 &
window=$(timeout 25 xdotool search --sync --onlyvisible --class '^thunar$' | head -n 1)
w=$(xwininfo -id "$window" | awk '/Width:/ { print $2 }')
echo "profile=$state scale=$expected"
echo "THUNAR_WIDTH=$w"
