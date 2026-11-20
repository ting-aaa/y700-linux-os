#!/usr/bin/env bash
# Run as the active seat user with permission to take one temporary photo per camera.
set -euo pipefail
if [[ ${1:-} != --private-session ]]; then
    grep -zFxq 'lenovo,asphalt' /proc/device-tree/compatible
    test "$(id -u)" != 0 && test -w /dev/udmabuf
    test "$(stat -f -c %T /dev/shm)" = tmpfs
    umask 077
    run=$(mktemp -d /dev/shm/qcam-photo.XXXXXXXX)
    cleanup_run() {
        # The portal can take a moment to unmount after its private D-Bus exits.
        for _ in {1..100}; do
            mountpoint -q "$run/runtime/doc" || break
            sleep .1
        done
        if mountpoint -q "$run/runtime/doc"; then
            fusermount3 -u "$run/runtime/doc" || return 1
        fi
        rm -rf --one-file-system -- "$run"
    }
    trap cleanup_run EXIT
    export HOME=$run/home XDG_CONFIG_HOME=$run/config XDG_RUNTIME_DIR=$run/runtime
    export XDG_CACHE_HOME=$run/cache XDG_DATA_HOME=$run/data XDG_STATE_HOME=$run/state
    mkdir -m 700 "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$HOME/照片"
    printf 'XDG_PICTURES_DIR="$HOME/照片"\n' > "$XDG_CONFIG_HOME/user-dirs.dirs"
    unset DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS AT_SPI_BUS_ADDRESS SESSION_MANAGER
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
    timeout -k 4s 140s dbus-run-session -- bash "$0" --private-session
    exit
fi
[[ $XDG_RUNTIME_DIR == /dev/shm/qcam-photo.????????/runtime ]]
dir=$(cd -- "$(dirname -- "$0")" && pwd)
py=(uv run --offline --no-project --python /usr/bin/python3 python)
cd "$HOME"
export XAUTHORITY=$XDG_RUNTIME_DIR/Xauthority
for n in {190..240}; do
    if [[ ! -e /tmp/.X11-unix/X$n && ! -e /tmp/.X$n-lock ]]; then break; fi
done
test ! -e "/tmp/.X11-unix/X$n" && test ! -e "/tmp/.X$n-lock"
export DISPLAY=:$n QT_SCALE_FACTOR=1 QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1
"${py[@]}" - "$n" "$XAUTHORITY" <<'PY'
import os, struct, sys
with open(sys.argv[2], "xb") as auth:
    auth.write(struct.pack(">H", 65535))
    for field in (b"", sys.argv[1].encode(), b"MIT-MAGIC-COOKIE-1", os.urandom(16)):
        auth.write(struct.pack(">H", len(field)) + field)
PY
Xvfb "$DISPLAY" -auth "$XAUTHORITY" -nolisten tcp -screen 0 1280x900x24 >"$HOME/x.log" 2>&1 &
xserver=$!
camera=
cleanup() {
    if [[ -n $camera ]]; then kill -INT "$camera" 2>/dev/null || true; wait "$camera" || true; fi
    kill "$xserver" 2>/dev/null || true
    wait "$xserver" || true
}
trap cleanup EXIT
for _ in {1..50}; do xdpyinfo >/dev/null 2>&1 && break; sleep .1; done
xdpyinfo >/dev/null
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR XDG_CONFIG_HOME HOME
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
    --method org.freedesktop.DBus.Properties.Set org.a11y.Status IsEnabled '<true>' >/dev/null

shoot() {
    local model=$1 camera_id=$2
    /usr/bin/y700-camera --verbose --camera "/base/soc@0/$camera_id" >"$HOME/camera.log" 2>&1 &
    camera=$!
    "${py[@]}" "$dir/qcam-shutter.py" "$camera" "$model" "$HOME/camera.log" "$HOME/照片"
    kill -INT "$camera"
    wait "$camera"
    camera=
    grep -Fxq 'Exiting' "$HOME/camera.log"
}

shoot HI1339 cci@ac15000/i2c-bus@0/camera@20
shoot S5K4H7 cci@ac15000/i2c-bus@1/camera@10
shoot SC202CS cci@ac16000/i2c-bus@0/camera@36
echo 'PASS three actual shutter actions, private JPEGs decoded and removed'
