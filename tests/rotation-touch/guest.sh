#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/ssc-test
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PYTHONPATH=/opt/ssc-test:/opt/ssc-test/ssc_server:/opt/ssc-test/python
export PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
work=/run/rotation-touch
mkdir -p "$work"
export UV_CACHE_DIR=$work/root-uv
pids=()
finish() {
    local rc=$?
    if (( rc )); then
        tail -30 "$work/"{actor,proxy,ssc,Xorg}.log "$work/Xorg.stderr" 2>/dev/null || :
        journalctl -b -u rotation-actor.service -u systemd-logind.service -n 20 --no-pager || :
    fi
    if (( ${#pids[@]} )); then kill "${pids[@]}" 2>/dev/null || :; fi
    echo "ROTATION_GUEST_EXIT=$rc"
}
trap finish EXIT
trap 'echo "Rotation fixture failure at line $LINENO" >&2' ERR
trap 'exit 143' TERM

wait_for() {
    local limit=$((SECONDS+$1)); shift
    until "$@"; do
        if (( SECONDS >= limit )); then echo "Timed out: $*" >&2; return 1; fi
        sleep 0.25
    done
}
grep -qw y700.rotation_touch_fixture=1 /proc/cmdline
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
test "$(uname -m)" = aarch64
test "$(cat /sys/block/vda/ro)" = 1
test ! -e /dev/fastrpc-sdsp
printf '\n'
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' y700-platform iio-sensor-proxy libssc2 xserver-xorg-core
test "$(dpkg-query -W -f='${Version}' iio-sensor-proxy)" = '3.9-1~bpo13+1.y7001'
test "$(dpkg-query -W -f='${Version}' libssc2)" = '0.4.4-2.1~bpo13+1.y7001'
[ -e /usr/lib/aarch64-linux-gnu/libqrtr.so.1 ] || install -m644 lib/libqrtr.so.1 /usr/lib/aarch64-linux-gnu/libqrtr.so.1
chown y700 ssc_server/data
./uv run --offline --no-project --python /usr/bin/python3 python check.py pose normal
./uv run --offline --no-project --python /usr/bin/python3 python ./ssc-server >"$work/ssc.log" 2>&1 &
pids+=("$!")
wait_for 15 grep -q 'Waiting for MSGs' "$work/ssc.log"
insmod ./y700_ssc_qemu.ko
udevadm settle --timeout=10
udevadm info --query=property --name=/dev/fastrpc-sdsp | grep -E '^IIO_SENSOR_PROXY_TYPE=.*ssc-accel'
# The product unit expects a real SLPI systemd service. Run the same installed
# proxy binary and authorization policy against the guest's synthetic QRTR sensor.
G_MESSAGES_DEBUG=all /usr/libexec/iio-sensor-proxy >"$work/proxy.log" 2>&1 &
pids+=("$!")
has_accel() {
    busctl --system --auto-start=no --timeout=1s get-property net.hadess.SensorProxy \
        /net/hadess/SensorProxy net.hadess.SensorProxy HasAccelerometer 2>/dev/null | grep -Fxq 'b true'
}
wait_for 30 has_accel

insmod ./vkms.ko enable_writeback=0 fixture_type=16 fixture_width=118 fixture_height=190 fixture_edid=0
mkfifo -m660 "$work/touch"
chown y700 "$work/touch"
exec 8<> "$work/touch"
./evdev-touch <&8 >"$work/input.log" &
pids+=("$!")
wait_for 10 grep -Eq '^READY input[0-9]+$' "$work/input.log"
udevadm trigger --subsystem-match=drm
udevadm trigger --action=add --subsystem-match=input
udevadm settle --timeout=10
input=$(awk '/^READY / { print $2 }' "$work/input.log")
ev=(/sys/class/input/"$input"/event*)
test "${#ev[@]}" = 1
udevadm info -q property -n "/dev/input/${ev[0]##*/}" | grep -Fxq 'ID_INPUT_TOUCHSCREEN=1'
./uv run --offline --no-project --python /usr/bin/python3 python fixture.py axes "/dev/input/${ev[0]##*/}"
connectors=(/sys/class/drm/card*-DSI-1/status)
test "${#connectors[@]}" = 1
grep -Fxq connected "${connectors[0]}"
connector=${connectors[0]%/status}
kms=${connector##*/}
kms=/dev/dri/${kms%%-*}
test -c "$kms"
cat > "$work/xorg.conf" <<XORG
Section "ServerFlags"
    Option "AutoAddGPU" "false"
EndSection
Section "Device"
    Identifier "Fixture display"
    Driver "modesetting"
    Option "kmsdev" "$kms"
    Option "AccelMethod" "none"
    Option "ShadowFB" "true"
    Option "SWcursor" "true"
EndSection
Section "Monitor"
    Identifier "Fixture monitor"
    HorizSync 5-200
    VertRefresh 5-200
    Modeline "1600x2560-fixture" 349.32 1600 1728 1896 2192 2560 2563 2573 2656 -HSync +VSync
EndSection
Section "Screen"
    Identifier "Fixture screen"
    Device "Fixture display"
    Monitor "Fixture monitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Virtual 2560 2560
        Modes "1600x2560-fixture"
    EndSubSection
EndSection
XORG
export DISPLAY=:1 XAUTHORITY=$work/Xauthority XDG_SESSION_TYPE=x11
./uv run --offline --no-project --python /usr/bin/python3 python fixture.py xauthority "$XAUTHORITY" 1
chown y700:y700 "$XAUTHORITY"
/usr/lib/xorg/Xorg "$DISPLAY" vt1 -novtswitch -config "$work/xorg.conf" -logfile "$work/Xorg.log" \
    -auth "$XAUTHORITY" -nolisten tcp -noreset >"$work/Xorg.stderr" 2>&1 &
pids+=("$!")
wait_for 30 xrandr --query >/dev/null 2>&1
test "$(cat /sys/class/tty/tty0/active)" = tty1
grep -F "Using input driver 'libinput' for 'NT36523N Capacitive Touchscreen'" "$work/Xorg.log"
if ! timeout -k 2 15 xrandr --query | grep -Eq '^ +1600x2560-fixture '; then
    xrandr --newmode 1600x2560-fixture 349.32 1600 1728 1896 2192 2560 2563 2573 2656 -HSync +VSync
    xrandr --addmode DSI-1 1600x2560-fixture
fi
timeout -k 2 15 xrandr --output DSI-1 --mode 1600x2560-fixture --pos 0x0
# Initial right orientation makes each subsequent pose require a transition.
timeout -k 2 15 xrandr --output DSI-1 --rotate right
echo 'ROTATION_DSI_READY initial=right'
install -o y700 -m600 /dev/null "$work/actor.log"
status=0
# Xorg holds tty1. Register the PAM session on that VT without acquiring it
# a second time as a controlling terminal for the desktop client's stdin.
systemd-run --quiet --wait --collect --unit=rotation-actor.service -p User=y700 -p PAMName=login \
    -p StandardInput=null -p TTYPath=/dev/tty1 -p StandardOutput=journal -p StandardError=journal \
    -E XDG_SESSION_TYPE=x11 -E XDG_SESSION_CLASS=user -E XDG_SEAT=seat0 -E XDG_VTNR=1 \
    -E "DISPLAY=$DISPLAY" -E "XAUTHORITY=$XAUTHORITY" /bin/bash /opt/ssc-test/actor.sh &
actor=$!
tail --pid="$actor" -s 0.25 -n +1 -f "$work/actor.log"
wait "$actor" || status=$?
test "$status" = 0
grep -Fxq Y700_SSC_ROTATION_TOUCH_PASS "$work/actor.log"
