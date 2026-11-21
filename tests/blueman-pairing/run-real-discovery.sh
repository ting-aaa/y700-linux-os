#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: run-real-discovery.sh USB_SSH_WRAPPER ARM64_XVFB_DEB ARM64_UV' >&2; exit 2; }
here=$(cd -- "$(dirname -- "$0")" && pwd)
ssh=(bash "$1")
work=$(mktemp -d)
stage=
cleanup() {
    if [[ $stage =~ ^/run/y700-bt-discovery\.[a-zA-Z0-9]{8}$ ]]; then
        "${ssh[@]}" "test \"\$(findmnt -nro FSTYPE -T '$stage')\" = tmpfs && test \"\$(realpath -e '$stage')\" = '$stage' && rm -r --one-file-system -- '$stage'" </dev/null || :
    fi
    rm -r -- "$work"
}
trap cleanup EXIT
[[ $(dpkg-deb -f "$2" Package) == xvfb && $(dpkg-deb -f "$2" Architecture) == arm64 ]]
dpkg-deb -x "$2" "$work/archive"
mkdir "$work/tools"
install -m755 "$work/archive/usr/bin/Xvfb" "$3" "$work/tools/"
install -m644 "$here/probe.py" "$here/real-discovery.py" "$work/tools/"
stage=$("${ssh[@]}" 'test "$(findmnt -nro FSTYPE /run)" = tmpfs && mktemp -d /run/y700-bt-discovery.XXXXXXXX' </dev/null)
[[ $stage =~ ^/run/y700-bt-discovery\.[a-zA-Z0-9]{8}$ ]]
tar -C "$work" -czf - tools | "${ssh[@]}" "tar --no-same-owner -C '$stage' -xzf - && chmod 0755 '$stage'"
"${ssh[@]}" "bash -s -- '$stage'" <<'REMOTE'
set -euo pipefail
s=$1
test "$(dpkg-query -W -f='${db:Status-Status} ${Version}' blueman)" = 'installed 2.4.4-1+y7003'
seat=$(loginctl show-seat seat0 -p ActiveSession --value)
test -n "$seat" && test "$(loginctl show-session "$seat" -p Name --value)" = y700
install -d -o y700 -g y700 -m700 "$s/home"
# Keep the stock desktop applet and system BlueZ bus. The X server, settings
# and scratch home belong to this test. The physical X server is unreachable.
unshare --mount --net --propagation private bash -se -- "$s" <<'NAMESPACE'
s=$1
mount -t tmpfs -o mode=1777,nodev,nosuid tmpfs /tmp
uid=$(id -u y700)
runuser -u y700 -- env -i PATH=/usr/bin:/bin HOME="$s/home" XDG_RUNTIME_DIR="/run/user/$uid" \
    LC_ALL=C.UTF-8 LANGUAGE=en GDK_BACKEND=x11 GDK_SCALE=2 GSETTINGS_BACKEND=memory GTK_USE_PORTAL=0 \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" DISPLAY=:263 XAUTHORITY="$s/home/Xauthority" \
    bash -se -- "$s" <<'USER'
set -o pipefail
s=$1
umask 077
# The daily image has libXau but need not install xauth. Write one FamilyLocal record.
"$s/tools/uv" run --no-config --no-project --no-cache --offline --python /usr/bin/python3 python -B - <<'COOKIE'
import os
import socket
import struct
with open(os.environ["XAUTHORITY"], "xb") as record:
    record.write(struct.pack(">H", 256))
    for field in (socket.gethostname().encode(), b"263", b"MIT-MAGIC-COOKIE-1", os.urandom(16)):
        record.write(struct.pack(">H", len(field)) + field)
COOKIE
"$s/tools/Xvfb" "$DISPLAY" -screen 0 1600x2560x24 -nolisten tcp -auth "$XAUTHORITY" >"$HOME/xvfb.log" 2>&1 &
xpid=$!
trap 'kill "$xpid" 2>/dev/null || :; wait "$xpid" 2>/dev/null || :' EXIT
echo "$xpid" >"$HOME/xvfb.pid"
for n in {1..50}; do xdpyinfo >/dev/null 2>&1 && break; sleep .1; done
xdpyinfo >/dev/null
if XAUTHORITY=/dev/null xdpyinfo >/dev/null 2>&1; then exit 1; fi
"$s/tools/uv" run --no-config --no-project --no-cache --offline --python /usr/bin/python3 python -B "$s/tools/real-discovery.py"
USER
NAMESPACE
test "$(loginctl show-seat seat0 -p ActiveSession --value)" = "$seat"
echo 'BLUEMAN_REAL_SEAT original_session=1'
REMOTE
