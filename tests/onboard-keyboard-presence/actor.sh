#!/usr/bin/env bash
set -euo pipefail
cd /opt/onboard-test
export LC_ALL=C.UTF-8 XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=xfce GDK_BACKEND=x11
export HOME=/run/onboard-presence/user/home XDG_RUNTIME_DIR=/run/onboard-presence/user/runtime
export XDG_CONFIG_HOME=$HOME/.config XDG_CACHE_HOME=$HOME/.cache XDG_STATE_HOME=$HOME/.local/state
export UV_CACHE_DIR=$XDG_CACHE_HOME/uv
export PYTHONFAULTHANDLER=1
mkdir -p -m700 "$HOME" "$XDG_RUNTIME_DIR"
exec >/run/onboard-presence/user/actor.log 2>&1
property() { loginctl show-session "${XDG_SESSION_ID:?}" -p "$1" --value; }
[[ $(id -un) == y700 && $(id -u) != 0 && $(property Active) == yes && $(property Remote) == no && $(property Seat) == seat0 ]]
echo 'ONBOARD_SEAT y700=1 active=1 seat=seat0'
exec dbus-run-session -- bash -ec '
    dbus-update-activation-environment DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
    xfconf-query -c xsettings -p /Gdk/WindowScalingFactor -n -t int -s 2
    xfce4-session >/run/onboard-presence/user/session.log 2>&1 & desktop=$!
    trap "kill $desktop 2>/dev/null || :; wait $desktop 2>/dev/null || :" EXIT
    ./uv run --offline --no-project --python /usr/bin/python3 python -B check.py
'
