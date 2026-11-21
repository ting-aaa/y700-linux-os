#!/bin/bash
set -eu
cd "$HOME"
mkfifo "$XDG_RUNTIME_DIR"/contact.{req,ack}
exec 7<> "$XDG_RUNTIME_DIR/contact.req" 8<> "$XDG_RUNTIME_DIR/contact.ack"
/qa/touch <&7 >&8 &
worker=$!
trap 'kill "$worker" 2>/dev/null || :' EXIT
xinput test-xi2 --root 'Y700 private XI2 touch' >xi.log 2>&1 &
xi=$!
sleep .4
/qa/adapter.sh tap 1210 680
/qa/adapter.sh hold 1150 750
sleep .3
kill "$xi" 2>/dev/null || :
test "$(grep -c '(RawTouchBegin)' xi.log)" = 2
test "$(grep -c '(RawTouchEnd)' xi.log)" = 2
echo THUNAR_PRIVATE_XI2_VALID
export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg Y700_THUNAR_TOUCH=/qa/adapter.sh GTK_USE_PORTAL=0 LANGUAGE=en
dbus-update-activation-environment XDG_CONFIG_DIRS XDG_CURRENT_DESKTOP XDG_RUNTIME_DIR GDK_SCALE NO_AT_BRIDGE DISPLAY
xfwm4 --replace --compositor=off --vblank=off >wm.log 2>&1 &
for i in {1..70}; do xprop -root _NET_SUPPORTING_WM_CHECK | grep -q 'window id' && break; sleep .1; done
xfsettingsd --no-daemon >xfsettings.log 2>&1 &
timeout 12 gdbus wait --session org.xfce.SettingsDaemon
gio launch /etc/xdg/autostart/y700-onboard.desktop >onboard.log 2>&1
timeout 20 gdbus wait --session org.onboard.Onboard
if [[ -e /qa/expect-stock ]]; then export Y700_THUNAR_STOCK=1; fi
uv run --offline --no-project --python /usr/bin/python3 python -B /qa/exercise.py
