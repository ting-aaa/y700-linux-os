#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin DISPLAY=:1
grep -qw y700.onboard_fixture=1 /proc/cmdline
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
[[ $(uname -m) == aarch64 && $(cat /sys/block/vda/ro) == 1 ]]
cd /opt/onboard-test
work=/run/onboard-presence
install -d -m755 "$work"
install -d -m700 -o y700 -g y700 "$work/user"
export XAUTHORITY=$work/user/Xauthority
pids=()
cleanup() {
    local rc=$?
    if (( rc )); then
        grep -n -A 24 'Fatal Python error' "$work/user/session.log" 2>/dev/null || :
        tail -n 45 "$work/user/"{actor,session}.log "$work/Xorg.log" "$work/Xorg.stderr" 2>/dev/null || :
        journalctl -b -u onboard-actor.service -n 20 --no-pager || :
        dmesg | tail -n 20 || :
    fi
    if (( ${#pids[@]} )); then kill "${pids[@]}" 2>/dev/null || :; fi
    echo "ONBOARD_GUEST_EXIT=$rc"
}
trap cleanup EXIT
trap 'echo "ONBOARD_GUEST_FAILURE line=$LINENO" >&2' ERR
wait_for() {
    local deadline=$((SECONDS + $1)); shift
    until "$@"; do
        if (( SECONDS >= deadline )); then echo "Timed out: $*" >&2; return 1; fi
        sleep .2
    done
}

printf '\n'
if grep -qw y700.onboard_profile=external-off /proc/cmdline; then
    install -d -m700 -o y700 -g y700 "$work/user/home"
    runuser -u y700 -- env "HOME=$work/user/home" "XDG_CONFIG_HOME=$work/user/home/.config" \
        XDG_CURRENT_DESKTOP=XFCE dbus-run-session -- bash -ec '
        gsettings set org.onboard.auto-show keyboard-device-detection-enabled false
        [[ $(dconf read /org/onboard/auto-show/keyboard-device-detection-enabled) == false ]]
    '
    echo 'ONBOARD_PROFILE seeded_detection=false before_upgrade=1'
fi
if [[ -f platform.deb ]]; then dpkg -i ./platform.deb; fi
if [[ -f onboard.deb ]]; then dpkg -i ./onboard.deb; fi
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' y700-platform onboard xserver-xorg-core
sha256sum /usr/share/glib-2.0/schemas/90_y700_onboard.gschema.override
umask 077
{
    printf '\377\377\000\000\000\0011\000\022MIT-MAGIC-COOKIE-1\000\020'
    head -c 16 /dev/urandom
} > "$XAUTHORITY"
chown y700:y700 "$XAUTHORITY"
umask 022
modprobe uhid
modprobe hid-generic
insmod ./vkms.ko enable_writeback=0 fixture_type=16 fixture_width=118 fixture_height=190 fixture_edid=0
mkfifo "$work/touch"
exec 8<> "$work/touch"
./evdev-touch <&8 >"$work/input.log" &
pids+=("$!")
wait_for 15 grep -Eq '^READY input[0-9]+$' "$work/input.log"
udevadm trigger --action=add --subsystem-match=input
udevadm settle --timeout=10
input=$(awk '/^READY / {print $2}' "$work/input.log")
events=(/sys/class/input/"$input"/event*)
[[ ${#events[@]} == 1 ]]
udevadm info -q property -n "/dev/input/${events[0]##*/}" | grep -Fxq ID_INPUT_TOUCHSCREEN=1
connectors=(/sys/class/drm/card*-DSI-1/status)
[[ ${#connectors[@]} == 1 ]]
grep -Fxq connected "${connectors[0]}"
kms=$(basename "$(dirname "${connectors[0]}")")
cat > "$work/xorg.conf" <<XORG
Section "ServerFlags"
    Option "AutoAddGPU" "false"
EndSection
Section "Device"
    Identifier "Fixture display"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/${kms%%-*}"
    Option "AccelMethod" "none"
    Option "ShadowFB" "true"
    Option "SWcursor" "true"
EndSection
Section "Monitor"
    Identifier "Fixture monitor"
    HorizSync 5-200
    VertRefresh 5-200
    Modeline "2560x1600-fixture" 345.38 2560 2752 3016 3472 1600 1603 1609 1658 -HSync +VSync
EndSection
Section "Screen"
    Identifier "Fixture screen"
    Device "Fixture display"
    Monitor "Fixture monitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Virtual 2560 2560
        Modes "2560x1600-fixture"
    EndSubSection
EndSection
XORG
/usr/lib/xorg/Xorg "$DISPLAY" vt1 -novtswitch -config "$work/xorg.conf" -logfile "$work/Xorg.log" \
    -auth "$XAUTHORITY" -nolisten tcp -noreset >"$work/Xorg.stderr" 2>&1 &
pids+=("$!")
wait_for 35 xrandr --query >/dev/null 2>&1
grep -Fq "Using input driver 'libinput' for 'NT36523N Capacitive Touchscreen'" "$work/Xorg.log"
if ! xrandr --query | grep -Eq '^ +2560x1600-fixture '; then
    xrandr --newmode 2560x1600-fixture 345.38 2560 2752 3016 3472 1600 1603 1609 1658 -HSync +VSync
    xrandr --addmode DSI-1 2560x1600-fixture
fi
xrandr --output DSI-1 --mode 2560x1600-fixture --pos 0x0
xinput map-to-output 'NT36523N Capacitive Touchscreen' DSI-1
xrandr --query | grep -Eq 'current 2560 x 1600'

systemd-run --quiet --wait --collect --unit=onboard-actor.service -p User=y700 -p PAMName=login \
    -p StandardInput=null -p TTYPath=/dev/tty1 -p StandardOutput=journal -p StandardError=journal \
    -E XDG_SESSION_TYPE=x11 -E XDG_SESSION_CLASS=user -E XDG_SEAT=seat0 -E XDG_VTNR=1 \
    -E "DISPLAY=$DISPLAY" -E "XAUTHORITY=$XAUTHORITY" /bin/bash /opt/onboard-test/actor.sh &
actor=$!
pids+=("$actor")

hid_event() {
    local kind=$1 name="Y700 Fixture $2" event props
    for event in /sys/class/input/event*; do
        if [[ $(cat "$event/device/name" 2>/dev/null) == "$name" ]]; then
            [[ $(cat "$event/device/id/bustype") == 0005 ]] || return 1
            props=$(udevadm info -q property -n "/dev/input/${event##*/}")
            grep -Fxq "ID_INPUT_${kind^^}=1" <<<"$props" || return 1
            if [[ $kind == mouse ]]; then
                if grep -Fxq ID_INPUT_KEYBOARD=1 <<<"$props"; then return 1; fi
            fi
            xinput list --id-only "$name" >/dev/null 2>&1
            return
        fi
    done
    return 1
}
removed() { ! xinput list --id-only "$1" >/dev/null 2>&1; }
keyboard= mouse=
while kill -0 "$actor" 2>/dev/null; do
    if [[ ! -f $work/user/request ]]; then sleep .12; continue; fi
    read -r request < "$work/user/request"
    case $request in
        tap) printf 'normal tap\n' >&8 ;;
        mouse-on)
            [[ -z $mouse ]]; ./uhid mouse & mouse=$!; pids+=("$mouse")
            wait_for 12 hid_event mouse Mouse
            echo 'ONBOARD_DEVICE mouse=1 keyboard_class=0 bus=bluetooth'
            ;;
        mouse-off)
            kill "$mouse"; wait "$mouse" || :; mouse=
            wait_for 12 removed 'Y700 Fixture Mouse'
            ;;
        keyboard-on)
            [[ -z $keyboard ]]; ./uhid keyboard & keyboard=$!; pids+=("$keyboard")
            wait_for 12 hid_event keyboard Keyboard
            echo 'ONBOARD_DEVICE keyboard=1 bus=bluetooth'
            ;;
        keyboard-off)
            kill "$keyboard"; wait "$keyboard" || :; keyboard=
            wait_for 12 removed 'Y700 Fixture Keyboard'
            ;;
        *) exit 1 ;;
    esac
    rm -- "$work/user/request"
done
wait "$actor"
cat "$work/user/actor.log"
