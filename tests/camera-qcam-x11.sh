#!/usr/bin/env bash
# Test the optional qcam desktop entry in a camera-free Debian X11 session.
set -euo pipefail
if [[ ${1:-} != --session ]]; then
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    mkdir -m 700 "$work/home" "$work/config" "$work/run"
    export HOME=$work/home XDG_CONFIG_HOME=$work/config XDG_RUNTIME_DIR=$work/run
    export XDG_SESSION_TYPE=x11 LC_ALL=C
    unset DISPLAY WAYLAND_DISPLAY
    dbus-run-session -- bash "$0" --session
    exit
fi

camera_list=$(LD_LIBRARY_PATH=/opt/y700-camera/lib /opt/y700-camera/bin/cam --list)
if [[ $camera_list != 'Available cameras:' ]]; then
    echo 'Run this fixture in a disposable environment with no cameras.' >&2
    exit 1
fi

Xvfb -displayfd 3 -screen 0 1280x800x24 -nolisten tcp 3>"$XDG_RUNTIME_DIR/display" &
xserver=$!
trap 'kill "$xserver" 2>/dev/null || true' EXIT
for _ in {1..100}; do
    [[ ! -s "$XDG_RUNTIME_DIR/display" ]] || break
    sleep 0.1
done
export DISPLAY=":$(cat "$XDG_RUNTIME_DIR/display")"

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
