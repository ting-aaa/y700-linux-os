#!/usr/bin/env bash
set -euo pipefail
cd /opt/qcam-virtual
work=/run/qcam-qa
export DISPLAY=:22 XAUTHORITY=/run/qcam-xauth
export HOME=$work/home XDG_CONFIG_HOME=$work/config XDG_RUNTIME_DIR=$work/runtime
export UV_CACHE_DIR=$work/uv-cache LC_ALL=C.UTF-8 LANG=C.UTF-8
export QT_QPA_PLATFORM=xcb QT_XCB_GL_INTEGRATION=none QT_SCALE_FACTOR=2 QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1
export LIBCAMERA_PIPELINES_MATCH_LIST=virtual LD_LIBRARY_PATH=/opt/qcam-virtual/runtime-root/usr/lib/aarch64-linux-gnu
mkdir -m700 "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
printf '%s\n' 'XDG_PICTURES_DIR="$HOME/Pictures"' > "$XDG_CONFIG_HOME/user-dirs.dirs"
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR
py=(./uv run --offline --no-project --python /usr/bin/python3 python -B ./orient-vm-check.py)
"${py[@]}" --generate
./orientation-probe
/opt/y700-camera/bin/qcam --renderer=qt --verbose --camera /base/soc@0/cci@ac15000/i2c-bus@0/camera@20 > "$work/qcam.log" 2>&1 &
app=$!
trap 'rc=$?; kill "$app" 2>/dev/null || :; if (( rc )); then grep -E "ERROR|Switching|Failed|configuring streams" "$work/qcam.log" | tail -n 10; fi' EXIT
"${py[@]}" "$app" "$(dpkg-deb -f ./qcam.deb Version)"
