#!/usr/bin/env bash
set -euo pipefail
cd /opt/qcam-virtual
work=/run/qcam-qa
export HOME=$work/home XDG_CONFIG_HOME=$work/config XDG_RUNTIME_DIR=$work/runtime
export UV_CACHE_DIR=$work/uv-cache LC_ALL=C.UTF-8 LANG=C.UTF-8
export QT_QPA_PLATFORM=xcb QT_XCB_GL_INTEGRATION=none QT_SCALE_FACTOR=2 QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1
export LIBCAMERA_PIPELINES_MATCH_LIST=virtual
export LD_LIBRARY_PATH=/opt/qcam-virtual/runtime-root/usr/lib/aarch64-linux-gnu
mkdir -m700 "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
printf '%s\n' 'XDG_PICTURES_DIR="$HOME/Pictures"' > "$XDG_CONFIG_HOME/user-dirs.dirs"
Xvfb -displayfd 3 -screen 0 1600x2560x24 -nolisten tcp 3>"$work/display" >"$work/x.log" 2>&1 &
display=$!
app=
cleanup() {
    rc=$?
    for pid in "$app" "$display"; do
        if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || :; fi
    done
    if (( rc )); then
        grep -E 'Switching to camera|configuring streams|Failed|ERROR' "$work/qcam.log" || :
        tail -n 12 "$work/"{x,qcam}.log 2>/dev/null || :
    fi
}
trap cleanup EXIT
for _ in {1..60}; do [[ ! -s $work/display ]] || break; sleep 0.1; done
export DISPLAY=":$(cat "$work/display")"
xdpyinfo >/dev/null
dbus-update-activation-environment DISPLAY XDG_RUNTIME_DIR
py=(./uv run --offline --no-project --python /usr/bin/python3 python -B ./virtual-shutter.py)
"${py[@]}" --generate "$work/macro-source.jpg"
app_locale=C.UTF-8
if grep -qw y700.qcam_virtual_chinese=1 /proc/cmdline; then app_locale=zh_CN.UTF-8; fi
version=$(dpkg-deb -f ./qcam.deb Version)
camera=()
if [[ $version == *.y7003 ]] || grep -qw y700.qcam_virtual_preflight=1 /proc/cmdline; then
    camera=(--camera /base/soc@0/cci@ac15000/i2c-bus@0/camera@20)
fi
LC_ALL=$app_locale /opt/y700-camera/bin/qcam --renderer=qt "${camera[@]}" --verbose >"$work/qcam.log" 2>&1 &
app=$!
for _ in {1..100}; do
    if grep -Fq '/opt/qcam-virtual/runtime-root/usr/lib/aarch64-linux-gnu/libcamera.so.0.7.2' "/proc/$app/maps"; then break; fi
    kill -0 "$app"
    sleep 0.2
done
grep -Fq '/opt/qcam-virtual/runtime-root/usr/lib/aarch64-linux-gnu/libcamera.so.0.7.2' "/proc/$app/maps"
if grep -qw y700.qcam_virtual_preflight=1 /proc/cmdline; then
    for _ in {1..300}; do
        if grep -q '^seq: ' "$work/qcam.log"; then break; fi
        kill -0 "$app"
        sleep 0.2
    done
    grep -E '800x600-NV12' "$work/qcam.log"
    grep -m 1 '^seq: ' "$work/qcam.log"
    echo QCAM_VIRTUAL_PREFLIGHT_PASS
    exit
fi
"${py[@]}" "$app" "$version" "$app_locale"
