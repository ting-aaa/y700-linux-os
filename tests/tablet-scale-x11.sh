#!/usr/bin/env bash
# Exercise the installed launcher with real Gtk, Xfce XSettings and X11 events.
set -euo pipefail
if [[ ${1:-} != --session ]]; then
    geometry=${1:-1600x2560}
    [[ $geometry == 1600x2560 || $geometry == 2560x1600 ]] || exit 2
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    mkdir -m 700 "$work/home" "$work/config" "$work/run"
    export HOME=$work/home XDG_CONFIG_HOME=$work/config XDG_RUNTIME_DIR=$work/run
    export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE LC_ALL=C
    unset DISPLAY WAYLAND_DISPLAY GDK_SCALE GDK_DPI_SCALE NO_AT_BRIDGE AT_SPI_BUS_ADDRESS
    dbus-run-session -- bash "$0" --session "$geometry"
    exit
fi

Xvfb -displayfd 3 -screen 0 "${2}x24" -nolisten tcp 3>"$XDG_RUNTIME_DIR/display" &
xserver=$!
trap 'kill "$xserver" 2>/dev/null || true' EXIT
for _ in {1..100}; do
    [[ ! -s "$XDG_RUNTIME_DIR/display" ]] || break
    sleep 0.1
done
export DISPLAY=":$(cat "$XDG_RUNTIME_DIR/display")"
xdpyinfo >/dev/null
xfsettingsd --no-daemon --replace &
settings=$!
trap 'kill "$settings" "$xserver" 2>/dev/null || true' EXIT

scale() { xfconf-query -c xsettings -p /Gdk/WindowScalingFactor; }
wait_for_scale() {
    for _ in {1..100}; do
        [[ $(scale 2>/dev/null) != "$1" ]] || return 0
        sleep 0.1
    done
    echo "Expected Xfce scale $1" >&2
    return 1
}

xfconf-query -c xsettings -p /Gdk/WindowScalingFactor -n -t int -s 1
thunar "$HOME" &
file_manager=$(timeout 20 xdotool search --sync --onlyvisible --class '^thunar$')
launcher=/usr/share/applications/y700-tablet-scale.desktop
gio launch "$launcher"
window=$(timeout 20 xdotool search --sync --onlyvisible --name '^Tablet display scale$')
size() { xwininfo -id "$1" | awk '/Width:/ {w=$2} /Height:/ {print w, $2}'; }
read -r standard_width standard_height <<< "$(size "$window")"
read -r file_manager_width _ <<< "$(size "$file_manager")"

xdotool mousemove --window "$window" "$((standard_width * 3 / 4))" "$((standard_height * 2 / 3))" click 1
wait_for_scale 2
for _ in {1..100}; do
    read -r large_width large_height <<< "$(size "$window")"
    (( large_width > standard_width )) && break
    sleep 0.1
done
(( large_width > standard_width ))
for _ in {1..100}; do
    read -r large_file_manager_width _ <<< "$(size "$file_manager")"
    (( large_file_manager_width > file_manager_width )) && break
    sleep 0.1
done
(( large_file_manager_width > file_manager_width ))

xdotool mousemove --window "$window" "$((large_width / 4))" "$((large_height * 2 / 3))" click 1
wait_for_scale 1
for _ in {1..100}; do
    read -r restored_width _ <<< "$(size "$window")"
    read -r restored_file_manager_width _ <<< "$(size "$file_manager")"
    (( restored_width == standard_width && restored_file_manager_width == file_manager_width )) && break
    sleep 0.1
done
(( restored_width == standard_width && restored_file_manager_width == file_manager_width ))
printf 'PASS: %s, desktop launcher, Xfce scale 1 → 2 → 1, Gtk window widths %s → %s → %s px and Thunar %s → %s → %s px.\n' \
    "$2" "$standard_width" "$large_width" "$restored_width" \
    "$file_manager_width" "$large_file_manager_width" "$restored_file_manager_width"

# Read the running GTK toggles through AT-SPI, independently of Xfconf.
a11y_bus=$(gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress | cut -d"'" -f2)
accessible_call() {
    local peer=$1 path=$2 method=$3
    shift 3
    gdbus call --address "$a11y_bus" --timeout 2 --dest "$peer" --object-path "$path" --method "$method" "$@"
}
accessible_children() {
    accessible_call "$1" "$2" org.a11y.atspi.Accessible.GetChildren |
        sed -nE "s/\('([^']+)', (objectpath )?'([^']+)'\)/\n\1 \3\n/g; P; D" | grep '^:'
}
accessible_name() {
    accessible_call "$1" "$2" org.freedesktop.DBus.Properties.Get org.a11y.atspi.Accessible Name | cut -d"'" -f2
}
find_toggles() {
    local path=$1 name child
    name=$(accessible_name "$scale_peer" "$path")
    case "$name" in
        '100% Standard') standard_toggle=$path ;;
        '200% Larger controls') large_toggle=$path ;;
    esac
    while read -r _ child; do find_toggles "$child"; done < <(accessible_children "$scale_peer" "$path")
}
while read -r scale_peer app_root; do
    if [[ $(accessible_name "$scale_peer" "$app_root") == y700-tablet-scale ]]; then
        find_toggles "$app_root"
        break
    fi
done < <(accessible_children org.a11y.atspi.Registry /org/a11y/atspi/accessible/root)

checked() {
    local flags
    flags=$(accessible_call "$scale_peer" "$1" org.a11y.atspi.Accessible.GetState |
        sed -nE 's/.*\[uint32 ([0-9]+),.*/\1/p')
    [[ $flags =~ ^[0-9]+$ ]] || return 1
    # ATSPI_STATE_CHECKED is state bit 4.
    printf '%s\n' "$(( (flags >> 4) & 1 ))"
}
[[ $(checked "$standard_toggle") == 1 && $(checked "$large_toggle") == 0 ]]

xfconf-query -c xsettings -p /Gdk/WindowScalingFactor -s 2
gio launch "$launcher"
for _ in {1..30}; do
    selection="$(checked "$standard_toggle") $(checked "$large_toggle")"
    [[ $selection != '0 1' ]] || break
    sleep 0.1
done
if [[ $selection != '0 1' ]]; then
    printf 'Expected 200%% checked after relaunch, got AT-SPI check states %s.\n' "$selection" >&2
    exit 1
fi
[[ $(xdotool search --onlyvisible --name '^Tablet display scale$') == "$window" ]]
[[ $(scale) == 2 ]]
printf 'PASS: %s, relaunch reused the same window and AT-SPI reported 100%% off and 200%% on after the external Xfconf change.\n' "$2"
