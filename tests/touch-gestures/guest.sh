#!/usr/bin/env bash
# Run as root in the disposable ARM64 QEMU guest. Chromium and Xfwm run as y700.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
grep -qw y700.touch_gesture_fixture=1 /proc/cmdline
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
test "$(uname -m)" = aarch64
test "$(dpkg-query -W -f='${Version}' y700-platform)" = '0.1.0~dev8'

fixture=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d /run/y700-touch-gestures.XXXXXXXX)
chmod 755 "$work"
user_dir=$work/user
install -d -m 700 -o y700 -g y700 "$user_dir"
export DISPLAY=:1 XAUTHORITY=$user_dir/Xauthority
export XDG_RUNTIME_DIR=$user_dir UV_CACHE_DIR=$work/uv
unset WAYLAND_DISPLAY
export LC_ALL=C HTTPS_PROXY= HTTP_PROXY= ALL_PROXY= https_proxy= http_proxy= all_proxy=

chrome= browser_pid= xorg= wm= input= web=
cleanup() {
    local rc=$?
    if (( rc != 0 )); then
        for log in Xorg chrome wm udev; do
            if [[ -f $work/$log.log ]]; then tail -40 "$work/$log.log"; fi
        done
        if [[ -f $work/Xorg.log ]]; then grep -E 'fixture|clock range' "$work/Xorg.log" || :; fi
    fi
    for pid in "$browser_pid" "$chrome" "$wm" "$xorg" "$web" "$input"; do
        if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || :; fi
    done
}
trap cleanup EXIT
trap 'echo "Gesture guest failed at line $LINENO" >&2' ERR

wait_for() {
    local limit=$((SECONDS+$1))
    shift
    until "$@"; do
        if (( SECONDS >= limit )); then echo "Timed out: $*" >&2; return 1; fi
        sleep 0.25
    done
}

cat > "$work/xorg.conf" <<'XORG'
Section "ServerFlags"
    Option "AutoAddGPU" "false"
EndSection
Section "Device"
    Identifier "Dummy"
    Driver "dummy"
    DacSpeed 400
    VideoRam 65536
EndSection
Section "Monitor"
    Identifier "Fixture monitor"
    HorizSync 5-200
    VertRefresh 5-200
    Modeline "1600x2560-fixture" 349.32 1600 1728 1896 2192 2560 2563 2573 2656 -HSync +VSync
    Modeline "2560x1600-fixture" 345.38 2560 2752 3016 3472 1600 1603 1609 1658 -HSync +VSync
EndSection
Section "Screen"
    Identifier "Fixture screen"
    Device "Dummy"
    Monitor "Fixture monitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Virtual 2560 2560
        Modes "1600x2560-fixture" "2560x1600-fixture"
    EndSubSection
EndSection
XORG

dpkg-deb -x "$fixture/dummy.deb" /
ip link set lo up
mkdir -p /dev/shm /run/dbus
mount -t tmpfs -o mode=1777 tmpfs /dev/shm
dbus-daemon --system --fork
runuser -u y700 -- unshare --user --map-root-user true
echo "Verified Chromium user namespace prerequisite as y700. $(chromium --version)"
mkdir -p /run/udev
/usr/lib/systemd/systemd-udevd --daemon >"$work/udev.log" 2>&1
mkfifo "$work/input.fifo"
exec 8<> "$work/input.fifo"
"$fixture/evdev-touch" <&8 > "$work/input.log" &
input=$!
wait_for 10 grep -Eq '^READY input[0-9]+$' "$work/input.log"
kernel_device=$(awk '/^READY / { print $2 }' "$work/input.log")
udevadm trigger --action=add --subsystem-match=input
udevadm settle --timeout=10
devices=(/sys/class/input/"$kernel_device"/event*)
event=${devices[0]##*/}
udevadm info -q property -n "/dev/input/$event" | grep -Fx 'ID_INPUT_TOUCHSCREEN=1'

"$fixture/uv" run --offline --no-project --python /usr/bin/python3 python -B "$fixture/fixture.py" \
    xauthority "$XAUTHORITY" "${DISPLAY#:}"
chown y700:y700 "$XAUTHORITY"
Xorg "$DISPLAY" -config "$work/xorg.conf" -logfile "$work/Xorg.log" -auth "$XAUTHORITY" -nolisten tcp -noreset >"$work/Xorg.stderr" 2>&1 &
xorg=$!
wait_for 30 xrandr --query >/dev/null 2>&1
device='NT36523N Capacitive Touchscreen'
wait_for 20 xinput list --id-only "$device"
test "$(xinput list --id-only "$device" | wc -l)" = 1
xinput list-props "$device" | grep -F 'libinput Calibration Matrix'
xinput list --long "$device" | grep -i -E 'touch|direct'
grep -F "Using input driver 'libinput' for '$device'" "$work/Xorg.log"

runuser -u y700 -- dbus-run-session -- xfwm4 --compositor=off > "$work/wm.log" 2>&1 &
wm=$!
has_wm() { xprop -root _NET_SUPPORTING_WM_CHECK | grep -q 'window id'; }
wait_for 20 has_wm
"$fixture/uv" run --offline --no-project --python /usr/bin/python3 python -B "$fixture/fixture.py" serve &
web=$!
wait_for 15 curl -fsS http://127.0.0.1:8937/record >/dev/null 2>&1

verify() {
    local phase=$1
    curl -fsS http://127.0.0.1:8937/record > "$work/record"
    "$fixture/uv" run --offline --no-project --python /usr/bin/python3 python -B "$fixture/fixture.py" \
        "$phase" "$width" "$height" < "$work/record" > "$work/assert.log" 2>&1
}

assert_renderer_sandbox() {
    local renderer browser renderer_ns browser_ns
    browser=$(pgrep -u y700 -xo chromium)
    renderer=$(pgrep -u y700 -f '^/usr/lib/chromium/chromium .*--type=renderer' | head -n 1)
    [[ -n $renderer && -n $browser ]] || return 1
    grep -Eq '^Seccomp:[[:blank:]]+2$' "/proc/$renderer/status" || return 1
    grep -Eq '^NoNewPrivs:[[:blank:]]+1$' "/proc/$renderer/status" || return 1
    renderer_ns=$(readlink "/proc/$renderer/ns/pid") || return 1
    browser_ns=$(readlink "/proc/$browser/ns/pid") || return 1
    [[ $renderer_ns != "$browser_ns" ]] || return 1
    browser_pid=$browser
    echo 'Chromium renderer sandbox: seccomp=2 no_new_privs=1 PID namespace isolated'
}

for orientation in portrait landscape; do
    if [[ $orientation == portrait ]]; then
        width=1600 height=2560 matrix=(1 0 0 0 1 0 0 0 1)
    else
        width=2560 height=1600 matrix=(0 -1 1 1 0 0 0 0 1)
    fi
    xrandr --output DUMMY0 --mode "${width}x${height}-fixture" --pos 0x0
    xinput set-prop "$device" 'Coordinate Transformation Matrix' "${matrix[@]}"
    xinput list-props "$device" | grep -F 'Coordinate Transformation Matrix'
    runuser -u y700 -- dbus-run-session -- chromium --user-data-dir="$user_dir/$orientation" --kiosk --no-first-run \
        --start-fullscreen --window-position=0,0 --window-size="$width,$height" \
        --no-default-browser-check --disable-background-networking --disable-gpu --ozone-platform=x11 \
        http://127.0.0.1:8937/ > "$work/chrome.log" 2>&1 &
    chrome=$!
    if ! wait_for 45 verify ready; then cat "$work/record" "$work/assert.log"; exit 1; fi
    printf 'VIEWPORT %s %s\n' "$orientation" "$(cat "$work/record")"
    wait_for 15 assert_renderer_sandbox
    for gesture in scroll pinch; do
        printf '%s %s\n' "$orientation" "$gesture" >&8
        if ! wait_for 20 verify "$gesture"; then cat "$work/record" "$work/assert.log"; exit 1; fi
        # Keep the final state after the last evdev frame and compositor animation.
        sleep 1.5
        verify "$gesture"
        printf 'GESTURE %s %s %s\n' "$orientation" "$gesture" "$(cat "$work/record")"
    done
    kill "$browser_pid"
    wait "$chrome" 2>/dev/null || :
    chrome= browser_pid=
    wait_for 15 bash -c '! pgrep -u y700 -x chromium >/dev/null || [[ $(ps -u y700 -o state=,comm= | awk '\''$2=="chromium" && $1!="Z" {n++} END {print n+0}'\'') == 0 ]]'
done
echo Y700_CHROMIUM_TOUCH_GESTURES_PASS
