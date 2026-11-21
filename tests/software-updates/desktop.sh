#!/bin/bash
# Run from a private QA directory as the ordinary user on its own PAM session.
set -euo pipefail
work=$(realpath -e "$1")
[[ $(id -u) != 0 && $(findmnt -nro FSTYPE -T "$work") == tmpfs ]]
cd "$work"
export HOME=$work/home XDG_RUNTIME_DIR=$work/runtime
export XDG_CONFIG_HOME=$HOME/.config XDG_CACHE_HOME=$HOME/.cache XDG_DATA_HOME=$HOME/.local/share
export LANG=C.UTF-8 LANGUAGE=en GDK_SCALE=2 GDK_DPI_SCALE=1 GDK_BACKEND=x11 XDG_CURRENT_DESKTOP=XFCE
export GTK_MODULES=atk-bridge NO_AT_BRIDGE=0 GSETTINGS_BACKEND=memory
mkdir -m700 -p "$HOME" "$XDG_RUNTIME_DIR"
# PrivateTmp makes the display number and the X11 sockets private to this unit.
export DISPLAY=:98 XAUTHORITY=$work/xauthority
umask 077
{
    printf '\377\377\000\000\000\00298\000\022MIT-MAGIC-COOKIE-1\000\020'
    head -c16 /dev/urandom
} >"$XAUTHORITY"
./Xvfb "$DISPLAY" -screen 0 2560x1600x24 -auth "$XAUTHORITY" -nolisten tcp >"$work/xvfb.log" 2>&1 &
xpid=$!
trap 'kill "$xpid" 2>/dev/null || :' EXIT
for i in {1..40}; do if xrandr --current >/dev/null 2>&1; then break; fi; sleep .1; done
xrandr --current >/dev/null
unset DBUS_SESSION_BUS_ADDRESS
dbus-run-session -- bash -ec '
    dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR GDK_SCALE
    xfwm4 --sm-client-disable --vblank=off --compositor=off >xfwm.log 2>&1 &
    ./uv run --offline --no-project --python /usr/bin/python3 python -B observe.py "$@"
' bash "${@:2}"
