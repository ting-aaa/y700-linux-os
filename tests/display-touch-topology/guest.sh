#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
grep -qw y700.topology_fixture=1 /proc/cmdline
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
cd /opt/y700-topology
work=/run/topology
mkdir -p "$work/bin" /run/udev /run/dbus /dev/shm
mount -t tmpfs -o mode=1777 tmpfs /dev/shm
dbus-daemon --system --fork
/usr/lib/systemd/systemd-udevd --daemon
dpkg-deb -x dummy.deb /
export DISPLAY=:1 XAUTHORITY=$work/Xauthority XDG_SESSION_TYPE=x11 XDG_RUNTIME_DIR=$work/user
install -d -m700 -o y700 -g y700 "$XDG_RUNTIME_DIR"
umask 077
{
    printf '\377\377\000\000\000\0011\000\022MIT-MAGIC-COOKIE-1\000\020'
    head -c 16 /dev/urandom
} > "$XAUTHORITY"
chown y700:y700 "$XAUTHORITY"
umask 022
mkfifo -m660 "$work/feed"
chown y700:y700 "$work/feed"
exec 8<> "$work/feed"
./evdev-touch <&8 > "$work/input.log" & input=$!
xorg=
cleanup() {
    rc=$?
    if (( rc )); then tail -30 "$work/Xorg.log" "$work/input.log" 2>/dev/null || :; fi
    kill "$input" ${xorg:+"$xorg"} 2>/dev/null || :
}
trap cleanup EXIT
for _ in {1..60}; do grep -Eq '^READY input[0-9]+$' "$work/input.log" && break; sleep .1; done
grep -Eq '^READY input[0-9]+$' "$work/input.log"
udevadm trigger --action=add --subsystem-match=input
udevadm settle --timeout=8
cat > "$work/xorg.conf" <<'XORG'
Section "ServerFlags"
    Option "AutoAddGPU" "false"
EndSection
Section "Device"
    Identifier "Dummy card"
    Driver "dummy"
    DacSpeed 400
    VideoRam 131072
EndSection
Section "Monitor"
    Identifier "Virtual panel"
    HorizSync 5-200
    VertRefresh 5-200
    Modeline "portrait" 349.32 1600 1728 1896 2192 2560 2563 2573 2656 -HSync +VSync
EndSection
Section "Screen"
    Identifier "Two outputs"
    Device "Dummy card"
    Monitor "Virtual panel"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Virtual 3200 2560
        Modes "portrait"
    EndSubSection
EndSection
XORG
Xorg "$DISPLAY" -config "$work/xorg.conf" -logfile "$work/Xorg.log" -auth "$XAUTHORITY" \
    -nolisten tcp -noreset > "$work/xorg.stderr" 2>&1 & xorg=$!
for _ in {1..80}; do xinput list --id-only 'NT36523N Capacitive Touchscreen' >/dev/null 2>&1 && break; sleep .15; done
grep -F "Using input driver 'libinput' for 'NT36523N Capacitive Touchscreen'" "$work/Xorg.log"
# Only the virtual output's name is translated; RandR geometry and every
# XInput property, mapping operation and touch event come from the real server.
cat > "$work/bin/xrandr" <<'WRAPPER'
#!/bin/bash
set -eo pipefail
[[ $# == 1 && ( $1 == --query || $1 == --current ) ]]
/usr/bin/xrandr "$1" | sed 's/^DUMMY0 /DSI-1 /'
echo poll >> "$XDG_RUNTIME_DIR/queries"
WRAPPER
cat > "$work/bin/xinput" <<'WRAPPER'
#!/bin/bash
set -eu
if [[ ${1:-} == map-to-output ]]; then
    [[ $# == 3 && $3 == DSI-1 ]]
    /usr/bin/xinput map-to-output "$2" DUMMY0
    echo mapped >> "$XDG_RUNTIME_DIR/writes"
else
    exec /usr/bin/xinput "$@"
fi
WRAPPER
chmod 755 "$work/bin/"*
printf 'TOPOLOGY_STACK kernel=%s platform=%s xserver=%s libinput=%s\n' "$(uname -r)" \
    "$(dpkg-query -W -f='${Version}' y700-platform)" "$(dpkg-query -W -f='${Version}' xserver-xorg-core)" \
    "$(dpkg-query -W -f='${Version}' xserver-xorg-input-libinput)"
sha256sum old-watcher /usr/bin/y700-display
runuser -u y700 -- env PATH="$work/bin:$PATH" /bin/bash ./cases.sh
