#!/bin/bash
set -euo pipefail
umask 077
[[ $(id -u) == 1000 && -w /dev/$1 && ! -e /dev/dri && ! -e /dev/snd && ! -e /dev/input ]]
[[ $(find /dev -maxdepth 1 -name 'video*' | wc -l) == 1 && ! -S /run/dbus/system_bus_socket ]]
export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/qa-system-bus"
cat >"$XDG_RUNTIME_DIR/system.conf" <<'BUS'
<busconfig><type>system</type><listen>unix:tmpdir=/tmp</listen><auth>EXTERNAL</auth>
<policy context="default"><allow user="*"/><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy></busconfig>
BUS
dbus-daemon --config-file="$XDG_RUNTIME_DIR/system.conf" --address="$DBUS_SYSTEM_BUS_ADDRESS" --fork
export XAUTHORITY=$XDG_RUNTIME_DIR/Xauthority
{ printf '\377\377\000\000\000\00273\000\022MIT-MAGIC-COOKIE-1\000\020'; head -c 16 /dev/urandom; } >"$XAUTHORITY"
Xvfb "$DISPLAY" -screen 0 2560x1600x24 -auth "$XAUTHORITY" -nolisten tcp >"$XDG_RUNTIME_DIR/Xvfb.log" 2>&1 &
xserver=$!
trap 'kill "$xserver" 2>/dev/null || :' EXIT
for _ in {1..60}; do xdpyinfo >/dev/null 2>&1 && break; kill -0 "$xserver"; sleep .1; done
xdpyinfo | awk '/dimensions:/ {ok=($2=="2560x1600")} END {exit !ok}'
export GST_DEBUG_NO_COLOR=1 GST_DEBUG='GST_ELEMENT_FACTORY:4,decodebin:6,h264parse:5,h265parse:5,v4l2:5,v4l2videodec:7,v4l2bufferpool:4'
export GST_DEBUG_FILE="$XDG_RUNTIME_DIR/media-%p.log"
probe_args=(--opener thunar)
gst_activation_env=()
if [[ -d /qa/plugin ]]; then
    export GST_REGISTRY_1_0="$XDG_RUNTIME_DIR/player-registry.bin"
    gst_activation_env=(GST_REGISTRY_1_0 GST_PLUGIN_PATH_1_0)
else
    [[ -z ${GST_PLUGIN_PATH_1_0:-} && -z ${GST_REGISTRY_1_0:-} ]]
    probe_args+=(--installed-iris)
fi
export UV_CACHE_DIR="$XDG_RUNTIME_DIR/uv" UV_PYTHON_DOWNLOADS=never
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_CONFIG_DIRS GDK_SCALE GDK_BACKEND "${gst_activation_env[@]}" GST_DEBUG GST_DEBUG_FILE GST_DEBUG_NO_COLOR DBUS_SYSTEM_BUS_ADDRESS
xfsettingsd --no-daemon >"$XDG_RUNTIME_DIR/xfsettingsd.log" 2>&1 &
timeout 15 gdbus wait --session org.xfce.SettingsDaemon
xfwm4 --compositor=off >"$XDG_RUNTIME_DIR/xfwm4.log" 2>&1 &
for _ in {1..80}; do xprop -root _NET_SUPPORTING_WM_CHECK | grep -q 'window id' && break; sleep .1; done
xprop -root _NET_SUPPORTING_WM_CHECK | grep -q 'window id'
thunar --daemon >"$XDG_RUNTIME_DIR/thunar.log" 2>&1 &
timeout 18 gdbus wait --session org.xfce.Thunar
cd /qa/clips
receipt=$XDG_RUNTIME_DIR/player-open.log
if ! uv run --offline --no-project --python /usr/bin/python3 python -B /qa/check-x11.py "${probe_args[@]}" | tee "$receipt"; then
    xwininfo -root -tree | grep -Ei 'Thunar|Parole|warning|error' | head -15 || :
    xprop -root _NET_ACTIVE_WINDOW _NET_SUPPORTING_WM_CHECK
    tail -n 5 "$XDG_RUNTIME_DIR/xfwm4.log" "$XDG_RUNTIME_DIR/thunar.log"
    grep -Eih 'Got buffer for frame number 0|Confirmed Iris VP9 startup keyframe' "$XDG_RUNTIME_DIR"/media-*.log | head -8 || :
    exit 1
fi
hardware_result=0
for item in h264.mp4:v4l2h264dec hevc.mp4:v4l2h265dec vp9.webm:v4l2vp9dec; do
    file=${item%:*}
    decoder=${item#*:}
    pid=$(awk -v file="file=$file" '$1=="PLAYER_OPEN" && $2==file {for (i=3;i<=NF;i++) if ($i ~ /^pid=[0-9]+$/) print substr($i,5)}' "$receipt")
    [[ $pid =~ ^[0-9]+$ ]]
    log="$XDG_RUNTIME_DIR/media-$pid.log"
    frames=$(grep -Ec "<${decoder}[0-9]+> Got buffer for frame number [0-9]+" "$log" || :)
    if [[ ! $frames =~ ^[0-9]+$ || $frames -lt 3 ]]; then
        echo "IRIS_PAROLE_NO_DECODE file=$file pid=$pid frames=$frames"
        grep -Ei 'creating element.*(v4l2|avdec_|vp9dec|h264parse|h265parse|imagesink)|not negotiated|Failed to probe|Got buffer for frame' "$log" |
            sed -E 's/0x[0-9a-f]{8,}/<ptr>/g' | head -16 || :
        hardware_result=1
        continue
    fi
    echo "IRIS_PAROLE_BUFFER file=$file pid=$pid decoder=$decoder buffers=$frames"
    if [[ $file == vp9.webm ]]; then grep -Fq 'Confirmed Iris VP9 startup keyframe' "$log"; fi
done
if [[ $hardware_result != 0 ]]; then
    grep -Eih 'Probing devices|Probing /dev/video|Failed to open /dev/video|register.*v4l2(h264|h265|vp9)dec' "$XDG_RUNTIME_DIR"/media-*.log |
        sed -E 's/0x[0-9a-f]{8,}/<ptr>/g' | head -16 || :
    exit 1
fi
echo 'IRIS_PAROLE_VP9 first_keyframe=confirmed'
