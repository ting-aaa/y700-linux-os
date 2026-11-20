#!/bin/bash
set -euo pipefail
[[ $$ == 1 && -f /etc/y700-private-lock-fixture ]]
[[ ! -e /dev/input && ! -e /dev/dri && ! -e /dev/snd && ! -e /run/dbus/system_bus_socket ]]
[[ -z $(ls -A /sys) && ! -e /etc/shadow && $(ls -A /home) == locktest ]]
[[ $(findmnt -nro FSTYPE /) == tmpfs && $(findmnt -nro OPTIONS /usr) == ro,* ]]
ulimit -c 0
umask 077
testuser=(setpriv --reuid=47319 --regid=47319 --clear-groups)
export XAUTHORITY=$XDG_RUNTIME_DIR/Xauthority
{
    printf '\377\377\000\000\000\00273\000\022MIT-MAGIC-COOKIE-1\000\020'
    head -c 16 /dev/urandom
} >"$XAUTHORITY"
chown 47319:47319 "$XAUTHORITY"
"${testuser[@]}" Xvfb "$DISPLAY" -screen 0 "${PRIVATE_GEOMETRY}x24" -auth "$XAUTHORITY" -nolisten tcp >/run/xvfb.log 2>&1 &
x=$!
for _ in {1..60}; do xdpyinfo >/dev/null 2>&1 && break; kill -0 "$x"; sleep .1; done
xdpyinfo >/dev/null
echo 'PRIVATE_LOCK isolation=private-mount,pid,network,ipc root=tmpfs system-bus=absent display=Xvfb'
uv=/qa/uv
[[ -x $uv ]] || uv=$(command -v uv)
exec "$uv" run --offline --no-project --python /usr/bin/python3 python -B /qa/exercise.py
