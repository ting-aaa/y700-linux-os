#!/usr/bin/env bash
# Exercise the installed rotation launcher with X11, GTK and per-user dconf.
# Pass tests/tablet-rotation-sensor.py to also test SensorProxy polling with uv.
set -euo pipefail
if [[ ${1:-} != --session ]]; then
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    mkdir -m 700 "$work/home" "$work/config" "$work/run"
    export HOME=$work/home XDG_CONFIG_HOME=$work/config XDG_RUNTIME_DIR=$work/run
    export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE GSETTINGS_BACKEND=dconf LC_ALL=C
    unset DISPLAY WAYLAND_DISPLAY GDK_SCALE GDK_DPI_SCALE NO_AT_BRIDGE AT_SPI_BUS_ADDRESS GSETTINGS_SCHEMA_DIR
    dbus-run-session -- bash "$0" --session 1 false true
    dbus-run-session -- bash "$0" --session 2 true false "${1:-}"
    exit
fi

export GDK_SCALE=$2
export DBUS_SYSTEM_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS
Xvfb -displayfd 3 -screen 0 1600x2560x24 -nolisten tcp 3>"$XDG_RUNTIME_DIR/display" &
xserver=$!
app_pid=
sensor_pid=
cleanup() {
    if [[ -n $sensor_pid ]]; then kill "$sensor_pid" 2>/dev/null || true; fi
    if [[ -n $app_pid ]]; then kill "$app_pid" 2>/dev/null || true; fi
    kill "$xserver" 2>/dev/null || true
    wait "$xserver" 2>/dev/null || true
}
trap cleanup EXIT
for _ in {1..100}; do
    [[ ! -s "$XDG_RUNTIME_DIR/display" ]] || break
    sleep 0.1
done
export DISPLAY=":$(cat "$XDG_RUNTIME_DIR/display")"

setting() { gsettings get org.y700.tablet auto-rotate; }
[[ $(setting) == "$3" ]]
gio launch /usr/share/applications/y700-tablet-rotation.desktop
window=$(timeout 20 xdotool search --sync --onlyvisible --name '^Tablet rotation$')
app_pid=$(xdotool getwindowpid "$window")

a11y_bus=$(gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress | cut -d"'" -f2)
accessible_call() {
    local peer=$1 path=$2 method=$3
    shift 3
    gdbus call --address "$a11y_bus" --timeout 2 --dest "$peer" --object-path "$path" --method "$method" "$@"
}
children() {
    accessible_call "$1" "$2" org.a11y.atspi.Accessible.GetChildren |
        sed -nE "s/\('([^']+)', (objectpath )?'([^']+)'\)/\n\1 \3\n/g; P; D" | grep '^:'
}
name() {
    accessible_call "$1" "$2" org.freedesktop.DBus.Properties.Get org.a11y.atspi.Accessible Name | cut -d"'" -f2
}
locked='Current orientation is locked.'
waiting='Automatic rotation enabled. Waiting for an orientation sensor.'
find_widgets() {
    local path=$1 child
    case "$(name "$peer" "$path")" in
        'Rotate automatically') toggle=$path ;;
        "$locked"|"$waiting") status=$path ;;
    esac
    while read -r _ child; do find_widgets "$child"; done < <(children "$peer" "$path")
}
toggle= status=
for _ in {1..50}; do
    while read -r peer root; do
        if [[ $(name "$peer" "$root") == y700-tablet-rotation ]]; then
            find_widgets "$root"
            break
        fi
    done < <(children org.a11y.atspi.Registry /org/a11y/atspi/accessible/root)
    [[ -z $toggle || -z $status ]] || break
    sleep 0.1
done
test -n "$toggle" && test -n "$status"

wait_for_state() {
    local value=$1 expected_status=$locked expected_check=0 flags
    if [[ $value == true ]]; then expected_status=${2:-$waiting}; expected_check=1; fi
    for _ in {1..50}; do
        flags=$(accessible_call "$peer" "$toggle" org.a11y.atspi.Accessible.GetState |
            sed -nE 's/.*\[uint32 ([0-9]+),.*/\1/p')
        # ATSPI_STATE_CHECKED is bit 4.
        if [[ $flags =~ ^[0-9]+$ && $(setting) == "$value" && $(name "$peer" "$status") == "$expected_status" ]] &&
            (( ((flags >> 4) & 1) == expected_check )); then
            return 0
        fi
        sleep 0.1
    done
    printf 'Expected %s and the checkbox and label to match\n' "$value" >&2
    return 1
}

wait_for_state "$3"
extents=$(accessible_call "$peer" "$toggle" org.a11y.atspi.Component.GetExtents 0 |
    sed -nE 's/^\(\((-?[0-9]+), (-?[0-9]+), ([0-9]+), ([0-9]+)\),\)$/\1 \2 \3 \4/p')
read -r x y width height <<<"$extents"
window_width=$(xwininfo -id "$window" | awk '/Width:/ {print $2}')
if (( height < 72 || window_width < 420 * GDK_SCALE )); then
    printf 'Unexpected checkbox bounds at %sx GTK scale: %s\n' "$GDK_SCALE" "$extents" >&2
    exit 1
fi
# GTK3 exposes logical coordinates through AT-SPI, while X11 input uses pixels.
tap() { xdotool mousemove "$(((x + width / 2) * GDK_SCALE))" "$(((y + height / 2) * GDK_SCALE))" click 1; }
tap
wait_for_state "$4"
gsettings set org.y700.tablet auto-rotate "$3"
wait_for_state "$3"
tap
wait_for_state "$4"
printf 'PASS: %sx GTK, %s → %s via pointer tap, with dconf, external updates and no-sensor status verified.\n' "$2" "$3" "$4"

if [[ -n ${5:-} ]]; then
    mock=$XDG_RUNTIME_DIR/sensor
    mkdir "$mock"
    uv run --offline --no-project --python /usr/bin/python3 python "$5" "$mock" &
    sensor_pid=$!
    wait_file() {
        local attempt attempts=${2:-50}
        for ((attempt=0; attempt<attempts; attempt++)); do
            if [[ -e $1 ]]; then return 0; fi
            kill -0 "$sensor_pid" || return 1
            sleep 0.1
        done
        printf 'Timed out waiting for %s\n' "$1" >&2
        return 1
    }
    wait_file "$mock/peer" 200
    mock_call() {
        local method=$1
        shift
        gdbus call --session --timeout 2 --dest "$(cat "$mock/peer")" --object-path /net/hadess/SensorProxy \
            --method "org.y700.Test.Sensor.$method" "$@" >/dev/null
    }
    sleep 3
    [[ ! -s $mock/calls ]]
    gsettings set org.y700.tablet auto-rotate true
    wait_for_state true
    mock_call SetAvailable true
    available='Automatic rotation enabled.'
    wait_for_state true "$available"
    mock_call SetAvailable false
    wait_for_state true
    mock_call SetAvailable true
    wait_for_state true "$available"

    mock_call Hold
    wait_file "$mock/held"
    mock_call DropOwner
    wait_for_state true
    mock_call SendHeldReply
    sleep 0.3
    [[ $(name "$peer" "$status") == "$waiting" ]]
    if grep -qxE 'ClaimAccelerometer|ReleaseAccelerometer' "$mock/calls"; then
        printf 'The settings window called a sensor claim method\n' >&2
        exit 1
    fi
    printf 'PASS: silent availability changes, no reads while locked, owner loss, late reply and no sensor claims.\n'
fi
