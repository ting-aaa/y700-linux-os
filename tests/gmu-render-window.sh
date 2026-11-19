#!/bin/bash
# Continuously render an X11 window and sample submissions from the renderer's own threads.
set -euo pipefail
id=$(cat /var/lib/y700-lab/active)
grep -Fqw "y700.lab_trial=$id" /proc/cmdline
boot=$(cat /proc/sys/kernel/random/boot_id)
out=/var/lib/y700-lab/runs/$id/render-$boot
mkdir -m700 "$out"
export DISPLAY=:0 XAUTHORITY=/run/lightdm/root/:0
test -r "$XAUTHORITY"
api=${Y700_RENDER_API:-gl}
case "$api" in
    gl) sample_pause_cs=5500 ;;
    vulkan) sample_pause_cs=300 ;;
    *) echo "Unknown rendering API: $api" >&2; exit 2 ;;
esac
faults='HFI vote snapshot|GPU_SET.*tim(e|ed) ?out|Timeout waiting for GMU OOB set GPU_SET|GX_BW_PERF_VOTE.*(timed out|returned error)|gpu fault|hangcheck detected|preemption timed out|GMU firmware (fault|error)|Unexpected message id .*response queue|arm-smmu.*(translation fault|Unhandled context fault)|ring .*timeout|GPU.*recovering|\[dpu error\]|flip_done timed out|vblank timeout|vblank wait timed out|hw recovery is not complete for ctl:|cleanup reset failed, ctl='
journalctl -k -b -q --no-pager -o short-monotonic |
    { grep -Ei "$faults" || [[ $? == 1 ]]; } > "$out/preflight-faults"
[[ ! -s $out/preflight-faults ]] || { cat "$out/preflight-faults"; exit 76; }
trace=/sys/kernel/tracing/instances/y700-render
mkdir "$trace"
child=
watcher=
display_settings_saved=false
cleanup() {
    trap - ERR
    set +e
    echo 0 > "$trace/tracing_on"
    if [[ -n $child ]]; then kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi
    if [[ -n $watcher ]]; then kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null; fi
    if $display_settings_saved; then
        timeout 5 xset s "$screen_timeout" "$screen_cycle"
        if $dpms_was_enabled; then timeout 5 xset +dpms; fi
    fi
    cat "$trace/trace" > "$out/last-trace"
    rmdir "$trace"
    journalctl -k -b -o short-monotonic --no-pager > "$out/kernel.log"
    sync -f "$out"
}
trap cleanup EXIT
trap 'exit 76' TERM INT
timeout 5 xset q > "$out/x-settings-before"
read -r screen_timeout screen_cycle < <(awk '/timeout:/ {print $2,$4}' "$out/x-settings-before")
[[ $screen_timeout =~ ^[0-9]+$ && $screen_cycle =~ ^[0-9]+$ ]]
dpms_was_enabled=false
if grep -q 'DPMS is Enabled' "$out/x-settings-before"; then dpms_was_enabled=true; fi
display_settings_saved=true
timeout 5 xset s reset
if $dpms_was_enabled; then
    timeout 5 xset dpms force on
    timeout 5 xset -dpms
fi
timeout 5 xset s off
timeout 5 xset q > "$out/x-settings-load"
if [[ -n ${Y700_VBLANK_PROBE:-} ]]; then
    connector=$(echo /sys/class/drm/card*-DSI-1)
    card=$(basename "$connector")
    drm_node="/dev/dri/${card%-DSI-1}"
fi
journalctl -k -b -n all -f -q -o short-monotonic --no-pager -g "$faults" > "$out/faults" &
watcher=$!
echo 32 > "$trace/buffer_size_kb"
echo 1 > "$trace/events/drm_msm_gpu/msm_gpu_submit/enable"
echo 1 > "$trace/tracing_on"
: > "$out/submits"
if [[ $api == vulkan ]]; then
    export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.json
    tools=${Y700_VULKAN_BINDIR:-/usr/bin}
    test -r "$VK_DRIVER_FILES"
    timeout 20 "$tools/vulkaninfo" --summary > "$out/vulkaninfo" 2>&1
    gpu='(Adreno.*730|FD730)'
    grep -Eiq "deviceName[[:space:]]*=.*$gpu" "$out/vulkaninfo"
    grep -Eiq 'driverID[[:space:]]*=.*MESA_TURNIP' "$out/vulkaninfo"
    [[ $(grep -Ec 'deviceName[[:space:]]*=' "$out/vulkaninfo") == 1 ]]
    stdbuf -oL -eL "$tools/vkcube" --wsi xcb --gpu_number 0 --width 640 --height 480 > "$out/draw.log" 2>&1 &
else
    stdbuf -oL -eL glxgears -geometry 640x480 -info > "$out/draw.log" 2>&1 &
fi
child=$!
duration=${Y700_RENDER_SECONDS:-1800}
[[ $duration =~ ^[1-9][0-9]*$ ]]
read_uptime() {
    local up
    read -r up _ < /proc/uptime
    uptime_cs=$((10#${up%.*} * 100 + 10#${up#*.}))
}
read_uptime
launch=$uptime_cs
start=-1
next_sample=0
sample_end=400
last_growth=$launch
previous_size=0
while :; do
    read_uptime
    elapsed=$((uptime_cs-launch))
    kill -0 "$child" "$watcher"
    [[ ! -s $out/faults ]] || { cat "$out/faults"; exit 76; }
    if (( elapsed >= sample_end && sample_end >= 0 )); then
        echo 0 > "$trace/tracing_on"
        tids=$(ls "/proc/$child/task" | paste -sd, -)
        awk -v threads=",$tids," '/msm_gpu_submit:/ {for(i=1;i<=NF;i++) if($i ~ /^pid=/ && index(threads, "," substr($i,5) ",") && /cmds=[1-9]/) {print; n++; break}; if(n>=3) exit} END {if(!n)exit 1}' "$trace/trace" >> "$out/submits" ||
            { echo "Missing GPU submissions for renderer threads $tids"; exit 76; }
        if [[ $api == vulkan ]]; then
            grep -Eiq "Selected GPU 0:.*$gpu" "$out/draw.log"
        else
            grep -Eq '^GL_RENDERER[[:space:]]*=.*(FD730|Adreno.*730)' "$out/draw.log"
        fi
        if [[ -n ${Y700_VBLANK_PROBE:-} ]]; then
            [[ $(cat "$connector/enabled") == enabled && $(cat "$connector/dpms") == On ]]
            timeout -k 1 5 "$Y700_VBLANK_PROBE" "$drm_node" >> "$out/vblank-samples"
        fi
        if (( start < 0 )); then
            read_uptime
            start=$uptime_cs
            printf 'start_cs=%s\n' "$start" > "$out/render-uptime"
            if [[ $api == vulkan ]]; then
                grep -i 'Selected GPU' "$out/draw.log"
                grep -m1 -E '/libvulkan_freedreno\.so([.0-9]*)?$' "/proc/$child/maps" > "$out/process-driver"
                ls -l "/proc/$child/fd" | grep -E '/dev/dri/renderD[0-9]+' > "$out/process-render-node"
            else
                grep -E '^GL_(RENDERER|VERSION|VENDOR)[[:space:]]*=' "$out/draw.log"
            fi
        fi
        next_sample=$((elapsed+sample_pause_cs)); sample_end=-1
    elif (( sample_end < 0 && elapsed >= next_sample )); then
        echo > "$trace/trace"
        echo 1 > "$trace/tracing_on"
        sample_end=$((elapsed+300))
    fi
    size=$(stat -c %s "$out/draw.log")
    if (( size > previous_size )); then
        last_growth=$uptime_cs
        previous_size=$size
    fi
    if [[ $api == gl ]] && (( elapsed > 1500 )); then
        (( uptime_cs - last_growth <= 1500 )) || { echo 'Frame reporting stopped'; exit 76; }
        grep -Eq '^[[:space:]]*[1-9][0-9]* frames in ' "$out/draw.log"
    fi
    if (( start >= 0 && uptime_cs-start > duration*100 )); then break; fi
    if (( uptime_cs >= ${next_heartbeat:-0} )); then
        systemctl is-active --quiet lightdm
        systemctl is-active --quiet ssh
        read -r up _ < /proc/uptime
        printf '%s ' "$up" >> "$out/progress"
        if [[ $api == vulkan ]]; then
            printf 'submits=%d\n' "$(wc -l < "$out/submits")" | tee -a "$out/progress"
        else
            awk '/ frames in / {n++; f+=$1} END {printf "samples=%d frames=%d\n",n,f}' "$out/draw.log" | tee -a "$out/progress"
        fi
        next_heartbeat=$((uptime_cs+3000))
    fi
    sleep 1
done
printf 'finish_cs=%s\n' "$uptime_cs" >> "$out/render-uptime"
journalctl -k -b -q --no-pager -o short-monotonic |
    { grep -Ei "$faults" || [[ $? == 1 ]]; } > "$out/final-faults"
[[ ! -s $out/final-faults ]] || { cat "$out/final-faults"; exit 76; }
if [[ $api == vulkan ]]; then
    printf 'duration_cs=%d submits=%d\n' "$((uptime_cs-start))" "$(wc -l < "$out/submits")" | tee "$out/summary"
else
    awk -v seconds="$(((uptime_cs-start)/100))" '/ frames in / {frames+=$1; n++} END {printf "duration=%ds samples=%d frames=%d\n",seconds,n,frames; if(n==0||frames==0) exit 1}' "$out/draw.log" | tee "$out/summary"
fi
