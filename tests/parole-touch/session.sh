#!/bin/bash
set -euo pipefail
export GDK_SCALE=${1:?} PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
export DISPLAY=:87 XDG_SESSION_TYPE=x11 GDK_BACKEND=x11 XDG_CURRENT_DESKTOP=XFCE NO_AT_BRIDGE=0
export XDG_RUNTIME_DIR="/run/parole-$2-$1"
install -d -o y700 -g y700 -m700 "$XDG_RUNTIME_DIR"
export XAUTHORITY=$XDG_RUNTIME_DIR/Xauthority
(printf '\377\377\000\000\000\00287\000\022MIT-MAGIC-COOKIE-1\000\020'; head -c16 /dev/urandom) > "$XAUTHORITY"
chown y700:y700 "$XAUTHORITY"
chmod 600 "$XAUTHORITY"
geom="$((1280 * GDK_SCALE))x$((800 * GDK_SCALE))x24"
/qa/Xvfb "$DISPLAY" -screen 0 "$geom" -nolisten tcp -auth "$XAUTHORITY" > "$XDG_RUNTIME_DIR/X.log" 2>&1 &
xpid=$!
trap 'kill "$xpid" 2>/dev/null || :; wait "$xpid" || :' EXIT
for _ in {1..70}; do if xdpyinfo >/dev/null 2>&1; then break; fi; sleep .1; done
xdpyinfo >/dev/null
runuser -u y700 -- env HOME=/home/y700 XDG_CACHE_HOME="$XDG_RUNTIME_DIR/cache" UV_CACHE_DIR="$XDG_RUNTIME_DIR/uv" \
    dbus-run-session -- bash -ec '
    dbus-update-activation-environment DISPLAY XAUTHORITY GDK_SCALE NO_AT_BRIDGE
    xfwm4 --compositor=off > "$XDG_RUNTIME_DIR/wm.log" 2>&1 &
    xfsettingsd --no-daemon > "$XDG_RUNTIME_DIR/xfce.log" 2>&1 &
    for i in {1..60}; do xprop -root _NET_SUPPORTING_WM_CHECK | grep -q "window id" && break; sleep .15; done
    if [[ -n ${Y700_PAROLE_TEST_THEME:-} ]]; then
        timeout 15 gdbus wait --session org.xfce.SettingsDaemon
        if xfconf-query -c xsettings -p /Net/ThemeName >/dev/null 2>&1; then
            xfconf-query -c xsettings -p /Net/ThemeName -s "$Y700_PAROLE_TEST_THEME"
        else
            xfconf-query -c xsettings -p /Net/ThemeName -n -t string -s "$Y700_PAROLE_TEST_THEME"
        fi
    fi
    if [[ -n ${Y700_PAROLE_TEST_SCRUB:-} ]]; then
        export GST_DEBUG=GST_EVENT:6 GST_DEBUG_NO_COLOR=1 GST_DEBUG_FILE="$XDG_RUNTIME_DIR/gst.log"
    fi
    /qa/uv run --offline --no-project --python /usr/bin/python3 python -B /qa/geometry.py /qa/clip.mp4'
