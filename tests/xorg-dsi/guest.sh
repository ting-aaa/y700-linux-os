#!/bin/bash
set -euo pipefail
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
grep -qw y700.panel_fixture=1 /proc/cmdline
cd /opt/panel-test
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix
cat >/run/panel.conf <<'XORG'
Section "ServerFlags"
 Option "AutoAddDevices" "false"
 Option "AutoAddGPU" "false"
EndSection
Section "Device"
 Identifier "panel"
 Driver "modesetting"
 Option "kmsdev" "/dev/dri/card0"
 Option "AccelMethod" "none"
EndSection
Section "Screen"
 Identifier "proof"
 Device "panel"
EndSection
XORG
export DISPLAY=:22 XAUTHORITY=/run/panel.Xauthority
umask 077
{ printf "\377\377\000\000\000\00222\000\022MIT-MAGIC-COOKIE-1\000\020"; head -c16 /dev/urandom; } > "$XAUTHORITY"
xorg_pid=
stop_server() {
    if [[ -n $xorg_pid ]]; then
        kill "$xorg_pid" 2>/dev/null || :
        wait "$xorg_pid" || :
        xorg_pid=
    fi
}
finish() {
    result=$?
    stop_server
    if (( result != 0 )); then
        tail -n 32 /run/test-xorg.log 2>/dev/null || :
    fi
}
trap finish EXIT

check_geometry() {
    local mode=$1 connector=$2 type=$3 width=$4 height=$5 edid=$6 expected=$7 line query
    local sys=/sys/class/drm/card0-$connector
    insmod ./vkms.ko enable_writeback=0 fixture_type="$type" fixture_width="$width" \
        fixture_height="$height" fixture_edid="$edid"
    for _ in {1..60}; do
        [[ ! -f $sys/status ]] || break
        sleep .1
    done
    test "$(cat "$sys/status")" = connected
    /usr/lib/xorg/Xorg "$DISPLAY" vt1 -nolisten tcp -auth "$XAUTHORITY" -noreset -novtswitch \
        -config /run/panel.conf -logfile /run/test-xorg.log >/run/xorg-stderr 2>&1 &
    xorg_pid=$!
    for _ in {1..70}; do
        kill -0 "$xorg_pid" || { cat /run/xorg-stderr; exit 1; }
        if [[ -S /tmp/.X11-unix/X22 ]] && xrandr --current >/run/query 2>/dev/null; then
            break
        fi
        sleep .1
    done
    for query in --query --current --query; do
        xrandr "$query" >/run/query
        line=$(grep "^$connector connected" /run/query)
        echo "PANEL_PROBE $mode edid=$edid raw=${width}x$height reported=$line"
        [[ $line == *"$expected" ]]
    done
    grep -Fq 'Loading /usr/lib/xorg/modules/drivers/modesetting_drv.so' /run/test-xorg.log
    test "$(wc -c <"$sys/edid")" -eq "$((edid * 128))"
    printf 'PANEL_XORG %s %s\n' "$mode" "$line"
    stop_server
    rmmod vkms
}

upstream='2:21.1.16-1.3+deb13u4'
for package in xserver-common xserver-xorg-core; do
    test "$(dpkg-query -W -f='${Version}' "$package")" = "$upstream"
done
check_geometry baseline DSI-1 16 118 190 0 '0mm x 0mm'

dpkg -i ./xserver-common_*.deb ./xserver-xorg-core_*.deb
test -z "$(dpkg --audit)"
apt-get check
for package in xserver-common xserver-xorg-core; do
    test "$(dpkg-query -W -f='${Version}' "$package")" = "$upstream+y7001"
    test -z "$(dpkg -V "$package")"
done
echo "PANEL_PACKAGES xserver-common=$upstream+y7001 xserver-xorg-core=$upstream+y7001"
check_geometry candidate DSI-1     16 118 190 0 '118mm x 190mm'
check_geometry candidate Virtual-1 15 118 190 0 '0mm x 0mm'
check_geometry candidate DSI-1     16   0 190 0 '0mm x 0mm'
check_geometry candidate DSI-1     16 118 190 1 '300mm x 200mm'
echo PANEL_GEOMETRY_PASS
