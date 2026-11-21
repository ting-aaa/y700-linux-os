#!/usr/bin/env bash
set -euo pipefail
cd /opt/panel-test
work=/run/qcam-qa
export DISPLAY=:22 XAUTHORITY=/run/qcam-xauth HOME=$work/home XDG_CONFIG_HOME=$work/config XDG_RUNTIME_DIR=$work/runtime
export XDG_DATA_HOME=$HOME/data XDG_STATE_HOME=$HOME/state XDG_CACHE_HOME=$HOME/cache UV_CACHE_DIR=$work/uv-cache
export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE LC_ALL=C.UTF-8
export ACCESSIBILITY_ENABLED=1 GNOME_ACCESSIBILITY=1 GTK_MODULES=atk-bridge
export LIBCAMERA_PIPELINES_MATCH_LIST=virtual LD_LIBRARY_PATH=/opt/qcam-virtual/runtime-root/usr/lib/aarch64-linux-gnu
mkdir -m700 "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
py=(./uv run --offline --no-project --python /usr/bin/python3 python -B)
"${py[@]}" ./orient-vm-check.py --generate
./orientation-probe
if [[ -f ./pipewire.deb ]]; then
    helper=$(sed -n 's/^Exec=//p' /etc/xdg/autostart/y700-camera-orientation.desktop)
    [[ $helper == /usr/libexec/y700-camera-orientation ]]
    "$helper" &
    watcher=$!
    for _ in {1..80}; do [[ ! -s $XDG_RUNTIME_DIR/y700-camera-panel.state ]] || break; sleep .1; done
    kill -0 "$watcher"
    [[ $(stat -c '%a:%s' "$XDG_RUNTIME_DIR/y700-camera-panel.state") == 600:8 ]]
fi
pipewire >"$work/pw.log" 2>&1 & pw=$!
wp=''
trap 'rc=$?; if ((rc)); then for f in pw wp browser consent; do if [[ -f $work/$f.log ]]; then tail -n 24 "$work/$f.log"; fi; done; fi; kill "$pw" ${wp:+"$wp"} 2>/dev/null || :' EXIT
for _ in {1..120}; do [[ ! -S $XDG_RUNTIME_DIR/pipewire-0 ]] || break; sleep .1; done
wireplumber --profile=video-only >"$work/wp.log" 2>&1 & wp=$!
for _ in {1..80}; do if pw-dump > "$work/nodes" && grep -q '"node.name": "y700_camera_front"' "$work/nodes"; then break; fi; sleep .2; done
grep '"node.name": "y700_camera_' "$work/nodes"
gdbus call --session --timeout 80 --dest org.freedesktop.portal.Desktop \
    --object-path /org/freedesktop/portal/desktop --method org.freedesktop.DBus.Properties.Get \
    org.freedesktop.portal.Camera version
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.freedesktop.DBus.Properties.Set org.a11y.Status IsEnabled '<true>'
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.freedesktop.DBus.Properties.Set org.a11y.Status ScreenReaderEnabled '<true>'
"${py[@]}" ./consent.py >"$work/consent.log" 2>&1 & tap=$!
"${py[@]}" ./browser.py
wait "$tap"; cat "$work/consent.log"
