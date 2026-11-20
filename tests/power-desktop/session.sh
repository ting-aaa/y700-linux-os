#!/bin/bash
set -euo pipefail
cd "$HOME"
[[ $(findmnt -nro OPTIONS -T /sys) == ro,* && -z $(find /dev -type b -print -quit) ]]
[[ ! -e /run/dbus/system_bus_socket && ! -e /dev/input && ! -e /dev/dri && ! -e /dev/snd ]]
BASESTARTUP=startxfce4
. /qa/board-default
[[ $XDG_CONFIG_DIRS == /etc/xdg:/usr/share/y700/power-xdg ]]
. /qa/board-default
[[ $XDG_CONFIG_DIRS == /etc/xdg:/usr/share/y700/power-xdg ]]
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/system-bus
cat >bus.conf <<XML
<busconfig><type>system</type><listen>$DBUS_SYSTEM_BUS_ADDRESS</listen>
<policy context="default"><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy>
</busconfig>
XML
dbus-daemon --config-file=bus.conf --fork --print-pid >bus.pid
export UPOWER_STATE_DIR=$HOME/data UPOWER_HISTORY_DIR=$HOME/data
mkdir -m700 "$HOME/data"
/usr/libexec/upowerd --debug >upower.log 2>&1 &
service=$!
trap 'kill "$service" "$(cat bus.pid)" 2>/dev/null || :' EXIT
timeout 12 gdbus wait --system org.freedesktop.UPower
bash /qa/board-readings.sh
login_owner=$(gdbus call --system --dest org.freedesktop.DBus \
    --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner \
    org.freedesktop.login1)
[[ $login_owner == '(false,)' ]]
echo 'POWER_UI backend=board-sysfs-ro uid=1000 desktop_bus=private logind=absent'
export Y700_TRAY_SCREEN=2560x1600 Y700_TRAY_PANEL_SIZE=64
dbus-run-session -- bash /run/tray.sh
