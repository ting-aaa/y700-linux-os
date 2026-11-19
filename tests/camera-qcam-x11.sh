#!/usr/bin/env bash
# Test the optional qcam desktop entry in a camera-free Debian X11 session.
set -euo pipefail
if [[ ${1:-} != --session ]]; then
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    scenarios=(standard)
    if [[ ${1:-} == --scale ]]; then
        scenarios=(standard tablet landscape custom-dpi dpi-resource qt-override external other-desktop unknown-dpi)
    elif (( $# )); then
        echo 'Usage: camera-qcam-x11.sh [--scale]' >&2
        exit 2
    fi
    for scenario in "${scenarios[@]}"; do
        export HOME=$work/$scenario/home XDG_CONFIG_HOME=$work/$scenario/config XDG_RUNTIME_DIR=$work/$scenario/run
        mkdir -p -m 700 "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
        export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE XDG_CONFIG_DIRS=/etc/xdg LC_ALL=C
        unset DISPLAY WAYLAND_DISPLAY GDK_SCALE GDK_DPI_SCALE QT_SCALE_FACTOR QT_SCREEN_SCALE_FACTORS QT_FONT_DPI
        unset QT_USE_PHYSICAL_DPI QT_ENABLE_HIGHDPI_SCALING QT_SCALE_FACTOR_ROUNDING_POLICY QT_DPI_ADJUSTMENT_POLICY
        unset QT_DEVICE_PIXEL_RATIO QT_AUTO_SCREEN_SCALE_FACTOR QT_QPA_PLATFORMTHEME
        dbus-run-session -- bash "$0" --session "$scenario" "${1:-}" | tee "$work/$scenario.log"
    done
    if [[ ${1:-} == --scale ]]; then
        geometry() { sed -n 's/^QCAM_SIZE=//p' "$work/$1.log"; }
        standard=$(geometry standard)
        [[ $standard =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]
        tablet="$(( ${standard%x*} * 2 ))x$(( ${standard#*x} * 2 ))"
        for scenario in tablet landscape custom-dpi dpi-resource; do [[ $(geometry "$scenario") == "$tablet" ]]; done
        for scenario in qt-override external other-desktop unknown-dpi; do [[ $(geometry "$scenario") == "$standard" ]]; done
        echo "PASS: qcam chooser $standard at 1x, $tablet at 2x, explicit settings and non-tablet contexts respected."
    fi
    exit
fi

scenario=$2
test_scale=$3

camera_list=$(LD_LIBRARY_PATH=/opt/y700-camera/lib /opt/y700-camera/bin/cam --list)
if [[ $camera_list != 'Available cameras:' ]]; then
    echo 'Run this fixture in a disposable environment with no cameras.' >&2
    exit 1
fi

mode=1600x2560
[[ $scenario != landscape ]] || mode=2560x1600
Xvfb -displayfd 3 -screen 0 "${mode}x24" -nolisten tcp 3>"$XDG_RUNTIME_DIR/display" &
xserver=$!
settings=
cleanup() {
    if [[ -n $settings ]]; then kill "$settings" 2>/dev/null || true; fi
    kill "$xserver" 2>/dev/null || true
}
trap cleanup EXIT
for _ in {1..100}; do
    [[ ! -s "$XDG_RUNTIME_DIR/display" ]] || break
    sleep 0.1
done
export DISPLAY=":$(cat "$XDG_RUNTIME_DIR/display")"

if [[ $test_scale == --scale ]]; then
    expect_scale=2 expect_dpi=96 expect_qt=
    case $scenario in
        standard) expect_scale=1 ;;
        tablet|landscape) expect_qt=2 ;;
        custom-dpi|dpi-resource) expect_dpi=192 ;;
        qt-override) export QT_SCALE_FACTOR=1; expect_qt=1 ;;
        other-desktop) export XDG_CURRENT_DESKTOP=GNOME ;;
    esac
    # Xvfb has a single output named "screen". Use its real resolution and
    # model the panel and optional external monitor only in the RandR report.
    mkdir "$XDG_RUNTIME_DIR/bin"
    cat > "$XDG_RUNTIME_DIR/bin/xrandr" <<'XRANDR'
#!/bin/sh
set -eu
/usr/bin/xrandr "$@" | sed 's/^screen connected/DSI-1 connected/'
if [ "$QCAM_FIXTURE_SCENARIO" = external ]; then
    echo 'DP-1 connected 1920x1080+2560+0 (normal left inverted right x axis y axis)'
fi
XRANDR
    chmod 755 "$XDG_RUNTIME_DIR/bin/xrandr"
    export PATH=$XDG_RUNTIME_DIR/bin:$PATH QCAM_FIXTURE_SCENARIO=$scenario
    xfconf-query -c xsettings -p /Gdk/WindowScalingFactor -n -t int -s "$expect_scale"
    if [[ $expect_dpi == 192 ]]; then xfconf-query -c xsettings -p /Xft/DPI -n -t int -s 192; fi
    xfsettingsd --no-daemon --replace &
    settings=$!
    timeout 20 gdbus wait --session org.xfce.SettingsDaemon
    for _ in {1..60}; do
        xft_dpi=$(xrdb -query | awk '$1 == "Xft.dpi:" { print $2 }')
        [[ $xft_dpi != "$expect_dpi" ]] || break
        sleep .1
    done
    [[ $xft_dpi == "$expect_dpi" && $(xfconf-query -c xsettings -p /Gdk/WindowScalingFactor) == "$expect_scale" ]]
    if [[ $scenario == unknown-dpi ]]; then xrdb -remove; fi
    if [[ $scenario == dpi-resource ]]; then printf 'Xft.dpi: 96\n' | xrdb -merge; fi
    printf 'QCAM_PROFILE=%s scale=%s dpi=%s\n' "$scenario" "$expect_scale" "$(xrdb -query | awk '$1 == "Xft.dpi:" { print $2 }')"
fi

log=$XDG_RUNTIME_DIR/qcam.log
gio launch /usr/share/applications/org.y700.Camera.desktop >"$log" 2>&1
if ! dialog=$(timeout 20 xdotool search --sync --onlyvisible --class '^qcam$'); then
    cat "$log" >&2
    exit 1
fi
pid=$(xdotool getwindowpid "$dialog")
tr '\0' '\n' < "/proc/$pid/environ" | awk '
    $0 == "LIBCAMERA_SOFTISP_MODE=cpu" { cpu = 1 }
    $0 == "QT_XCB_GL_INTEGRATION=none" { xcb_without_gl = 1 }
    END { exit !(cpu && xcb_without_gl) }
'
tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fx -- '--renderer=qt' >/dev/null
grep -Fq '/opt/y700-camera/lib/libcamera.so.0.7.2' "/proc/$pid/maps"
grep -Fq '/qt6/plugins/platforms/libqxcb.so' "/proc/$pid/maps"
if grep -Fq '/qt6/plugins/xcbglintegrations/' "/proc/$pid/maps"; then
    echo 'qcam loaded a Qt Xcb GL integration.' >&2
    exit 1
fi
if [[ $test_scale == --scale ]]; then
    qt=$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^QT_SCALE_FACTOR=//p')
    [[ $qt == "$expect_qt" ]]
    geometry=$(xdotool getwindowgeometry --shell "$dialog" | awk -F= '$1=="WIDTH"{w=$2} $1=="HEIGHT"{h=$2} END{print w "x" h}')
    printf 'QCAM_QT_FACTOR=%s\nQCAM_SIZE=%s\n' "$qt" "$geometry"
fi

# Escape activates the Qt camera chooser's Cancel response.
xdotool windowfocus --sync "$dialog" key Escape
for _ in {1..100}; do
    if ! xdotool getwindowname "$dialog" >/dev/null 2>&1 && grep -Fq 'No camera detected' "$log"; then
        echo 'PASS: the desktop entry loaded the private runtime and Qt Xcb without GL integration, and the chooser responded to Cancel.'
        exit 0
    fi
    sleep 0.1
done
cat "$log" >&2
exit 1
