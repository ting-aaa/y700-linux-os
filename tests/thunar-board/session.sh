#!/bin/bash
set -euo pipefail
[[ ! -e /dev/tty0 && ! -e /dev/input && ! -e /dev/dri && ! -S /run/dbus/system_bus_socket ]]
[[ -z $(find /dev -type b -print -quit) ]]
mkdir -p /empty-xorg /run/dbus
dbus-daemon --system --fork --nopidfile
/usr/lib/xorg/Xorg "$DISPLAY" -seat seat-y700-qa -novtswitch -noreset -nolisten tcp -config /qa/dummy.conf -configdir /empty-xorg -modulepath /qa/modules,/usr/lib/xorg/modules -logfile /tmp/Xorg.log >/tmp/xorg-stderr 2>&1 &
xp=$!
cleanup() {
 rc=$?
 if ((rc)); then tail -40 /tmp/Xorg.log; tail -10 /tmp/xorg-stderr; fi
 kill "$xp" 2>/dev/null || :
}
trap cleanup EXIT
for i in {1..70}; do
    if [[ -S /run/y700-xi.sock ]] && xdpyinfo >/dev/null 2>&1; then break; fi
    sleep .1
done
xrandr --newmode qa2560 268.50 2560 2608 2640 2720 1600 1603 1609 1646 +hsync -vsync
xrandr --addmode DUMMY0 qa2560
xrandr --output DUMMY0 --mode qa2560
xdpyinfo | grep 'dimensions: *2560x1600'
xinput list --name-only | grep -Fx 'Y700 private XI2 touch'
chown y700:y700 /run/y700-xi.sock
chmod 600 /run/y700-xi.sock
chmod -R a+rX /qa
sha256sum /usr/bin/thunar
setpriv --reuid=1000 --regid=1000 --clear-groups --no-new-privs env HOME=/home/y700 USER=y700 LOGNAME=y700 XDG_RUNTIME_DIR=/run/user/1000 XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 NO_AT_BRIDGE=0 GDK_BACKEND=x11 UV_OFFLINE=1 UV_CACHE_DIR=/home/y700/.cache/uv PYTHONDONTWRITEBYTECODE=1 dbus-run-session -- bash /qa/user.sh
