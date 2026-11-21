#!/bin/bash
# Run in a private mount and network namespace, with a tmpfs staging directory.
set -euo pipefail
trap 'echo "IRIS_CHECK_FAILED line=$LINENO" >&2' ERR
export LC_ALL=C
stage=$(realpath -e "$1")
mode=$2
codec=${mode%%-*}
last_completed_sleep() {
    awk -v entry="PM: suspend entry ($1)" '
        /^PM: suspend entry/ {valid=(!opened && $0==entry); opened=1; done=0; next}
        /^PM: suspend exit/ {done=(opened && valid && $0=="PM: suspend exit"); opened=0}
        END {exit !(done && !opened)}
    '
}
[[ $stage == /run/y700-iris.* && $(findmnt -nro FSTYPE -T "$stage") == tmpfs ]]
[[ $(readlink /proc/self/ns/mnt) != "$(readlink /proc/1/ns/mnt)" ]]
[[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]]
grep -zFxq lenovo,asphalt /sys/firmware/devicetree/base/compatible
notes=$(sha256sum /sys/kernel/notes | cut -d' ' -f1)
installed_plugin=
sleep_mode=
case $mode in
    h264-after-wake) sleep_mode=s2idle ;;
    h264-after-deep) sleep_mode=deep ;;
esac
if [[ -n $sleep_mode ]]; then
    [[ $notes == 35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6 ]]
    grep -Fxq IMAGE_VERSION=dev12.11 /etc/os-release
    grep -Fwq y700.release=dev12.11 /proc/cmdline
    [[ $(findmnt -nro UUID -M /) == c0e447e4-82db-59ee-91d6-0e1ec9d5f45e ]]
    success=$(cat /sys/power/suspend_stats/success)
    [[ $success =~ ^[1-9][0-9]*$ ]]
    journalctl -k -b -q -o cat --no-pager --grep='^PM: suspend (entry|exit)' |
        last_completed_sleep "$sleep_mode"
    installed_plugin=/usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so
    printf '%s  %s\n' a64bdb5bf9e4454f371638cf17c2564c3cbe3a3bc379ba5151de3c689f4a69f0 "$installed_plugin" | sha256sum --strict --status -c -
    printf 'IRIS_WAKE_PRECHECK release=dev12.11 sleep_success=%s kernel_notes=%s sleep_mode=%s\n' "$success" "$notes" "$sleep_mode"
    mode=h264-playbin
else
    [[ $notes == 2e6b047aba528bfdea5549b9aae9af362a9af055bb630a650bcdd7c654ec9066 ]]
fi
case $codec in
    h264) factory=v4l2h264dec; caps='video/x-h264,stream-format=byte-stream,alignment=au' ;;
    hevc) factory=v4l2h265dec; caps='video/x-h265,stream-format=byte-stream,alignment=au' ;;
    vp9) factory=v4l2vp9dec; caps='video/x-vp9,alignment=frame,profile=(string)0' ;;
    *) exit 2 ;;
esac
mapfile -t nodes < <(grep -lFx qcom-iris-decoder /sys/class/video4linux/video*/name)
[[ ${#nodes[@]} == 1 ]]
dev=$(basename "$(dirname "${nodes[0]}")")
[[ $dev =~ ^video[0-9]+$ ]]
chip=/sys/bus/platform/devices/aa00000.video-codec
[[ $(readlink -f "/sys/class/video4linux/$dev/device") == "$(realpath "$chip")" ]]
[[ $(cat "$chip/power/runtime_status") == suspended ]]
if [[ -n $installed_plugin ]]; then
    # Abort if another application still has the decoder open, even while idle.
    for fd in /proc/[0-9]*/fd/*; do
        if [[ $fd -ef /dev/$dev ]]; then echo IRIS_DECODER_IN_USE; exit 1; fi
    done
fi
runuser -u y700 -- test -r "/dev/$dev"
runuser -u y700 -- test -w "/dev/$dev"
cursor=$(journalctl -k -b -n 0 --show-cursor --no-pager | sed -n 's/^-- cursor: //p')
[[ -n $cursor ]]
boot=$(cat /proc/sys/kernel/random/boot_id)
baseline() {
    systemctl show -p InvocationID --value bluetooth.service lightdm.service ssh.service
    cat /sys/class/backlight/*/brightness
    loginctl show-seat seat0 -p ActiveSession
}
seat=$(baseline)
stage_result() {
    local rc=$?
    trap - EXIT
    for _ in {1..12}; do
        [[ $(cat "$chip/power/runtime_status") != suspended ]] || break
        sleep 0.5
    done
    local pm
    pm=$(cat "$chip/power/runtime_status")
    if [[ $pm != suspended || $boot != "$(cat /proc/sys/kernel/random/boot_id)" || $seat != "$(baseline)" ]]; then
        echo "IRIS_RESTORE_FAIL pm=$pm"
        exit 1
    fi
    local recent
    recent=$(journalctl -k -b --after-cursor="$cursor" -o cat --no-pager -q)
    if [[ -n $installed_plugin ]]; then
        printf 'IRIS_WAKE_PM failed_suspend=%s failed_resume=%s\n' \
            "$(grep -Fc 'qcom-iris aa00000.video-codec: failed to suspend' <<< "$recent" || :)" \
            "$(grep -Fc 'qcom-iris aa00000.video-codec: failed to resume' <<< "$recent" || :)"
    fi
    if grep -Ei '(iris|vpu|video-codec|iommu|arm-smmu).*(fatal|retained|fault|watchdog|timeout|timed out|failed.*ownership)|Unhandled context fault' <<< "$recent"; then
        echo IRIS_KERNEL_FAILURE
        exit 1
    fi
    printf 'IRIS_RESTORED pm=%s seat_services_backlight_and_boot=same collapse_retries=%s\n' "$pm" "$(grep -c 'skip power collapse' <<< "$recent" || :)"
    exit "$rc"
}
trap stage_result EXIT
cd "$stage"
read -r width height <"$codec/geometry"
[[ "$width $height" == '384 256' || "$width $height" == '1920 1080' ]]
mkdir view
mount -t tmpfs -o mode=755 tmpfs view
for name in null zero random urandom "$dev"; do
    touch "view/$name"
    mount --bind "/dev/$name" "view/$name"
done
mount --move view /dev
install -d -m700 -o y700 -g "$(id -gn y700)" results
gst=(runuser -u y700 -- env -i HOME="$stage/results" PATH=/usr/bin:/bin LC_ALL=C GST_REGISTRY="$stage/results/registry.bin")
if [[ -n $installed_plugin ]]; then gst+=(GST_PLUGIN_PATH_1_0="${installed_plugin%/*}"); fi
if [[ -d plugin ]]; then gst+=(GST_PLUGIN_PATH_1_0="$stage/plugin"); fi
if [[ -d parser ]]; then gst+=(LD_LIBRARY_PATH="$stage/parser"); fi
timeout -k 2 18 "${gst[@]}" ./gst-inspect-1.0 "$factory" >results/factory
grep -F 'GstV4l2VideoDec' results/factory >/dev/null
grep -F "/dev/$dev" results/factory >/dev/null
if [[ -n $installed_plugin ]]; then grep -F "$installed_plugin" results/factory >/dev/null; fi
if [[ -f plugin/libgstvideo4linux2.so ]]; then
    grep -F "$stage/plugin/libgstvideo4linux2.so" results/factory >/dev/null
    printf 'IRIS_PRIVATE_V4L2 sha256=%s\n' "$(sha256sum plugin/libgstvideo4linux2.so | cut -d' ' -f1)"
fi
printf 'IRIS_FACTORY codec=%s factory=%s ordinary=1 video_devices=%s\n' "$codec" "$factory" "$(find /dev -maxdepth 1 -name 'video*' | wc -l)"
input=(multifilesrc location="$codec/%03d.au" start-index=0 stop-index=23 "caps=$caps,width=$width,height=$height,framerate=12/1")
if [[ $codec == vp9 ]]; then input=(filesrc location=vp9/clip.webm '!' matroskademux); fi
decode=("${input[@]}" '!' "$factory" capture-io-mode=mmap output-io-mode=mmap '!' video/x-raw,format=NV12)
if [[ $mode == *-mp4 || $mode == vp9-auto ]]; then
    container=mp4
    if [[ $codec == vp9 ]]; then container=webm; fi
    decode=(uridecodebin uri="file://$stage/$codec/clip.$container" "decodebin0::${factory}0::capture-io-mode=mmap" '!' video/x-raw,format=NV12)
fi
pipeline=("${decode[@]}" '!' videoconvert '!' video/x-raw,format=I420 '!' filesink location=results/actual.i420 sync=false)
if [[ $mode == *-playbin ]]; then
    container=mp4
    if [[ $codec == vp9 ]]; then container=webm; fi
    pipeline=(playbin uri="file://$stage/$codec/clip.$container" audio-sink=fakesink 'video-sink=videoconvert ! video/x-raw,format=I420 ! filesink location=results/actual.i420 sync=false')
fi
timeout -k 3 30 "${gst[@]}" GST_DEBUG_NO_COLOR=1 GST_DEBUG='v4l2videodec:7,v4l2bufferpool:6,v4l2allocator:7,videodecoder:6' ./gst-launch-1.0 -m -v \
    "${pipeline[@]}" \
    >results/pipeline 2>&1 || {
        grep -EA2 '(^ERROR:| WARN | ERROR |no suitable plugins|Missing decoder)' results/pipeline | \
            sed -E 's/0x[0-9a-f]{8,}/<ptr>/g' | tail -32 || :
        exit 1
    }
grep -q 'Got EOS' results/pipeline
if grep -Fq 'Confirmed Iris VP9 startup keyframe' results/pipeline; then echo IRIS_VP9_KEYFRAME_CONFIRMED; fi
if [[ $mode == *-mp4 || $mode == vp9-auto || $mode == *-playbin ]]; then
    grep -E "<${factory}[0-9]+> Got buffer for frame number" results/pipeline >/dev/null || { echo IRIS_AUTO_SOFTWARE_OR_OTHER_DECODER; exit 1; }
    grep -F 'format=(string)NV12' results/pipeline >/dev/null
    echo "IRIS_AUTOPLUG mode=$mode selected=$factory staged_parser=$(test -d parser && echo yes || echo no)"
fi
frame_bytes=$((width * height * 3 / 2))
bytes=$(stat -c %s results/actual.i420)
(( bytes > 0 && bytes % frame_bytes == 0 && bytes <= 48 * frame_bytes )) || { echo "IRIS_OUTPUT_BYTES $bytes"; exit 1; }
for ((i=0; i<bytes/frame_bytes; i++)); do
    dd if=results/actual.i420 bs="$frame_bytes" skip="$i" count=1 status=none | sha256sum | cut -d' ' -f1
done >results/frame.sha256
if ! cmp -s "$codec/reference.sha256" results/frame.sha256; then
    # Limit diagnostics to the synthetic stream's first two logical frames.
    sed -nE 's/^.*(Passing buffer with system frame number [01]|Got buffer for frame number [01])$/IRIS_GST \1/p' results/pipeline
    grep -Ei 'Dequeued capture buffer|dequeue.*flags|drop frame' results/pipeline | head -18 | sed -E 's/^.* (LOG|DEBUG|WARN|ERROR|INFO) +/IRIS_TRACE /;s/0x[0-9a-f]{8,}/<ptr>/g' || :
    grep -oE '[0-9]+ initial frames were not dequeued[^:]*' results/pipeline | head -1 || :
    awk 'NR==FNR {idx[$1]=FNR; next} {print "IRIS_DIFFERENCE output=" FNR " expected=" ($1 in idx ? idx[$1] : "unmatched")}' \
        "$codec/reference.sha256" results/frame.sha256
    exit 1
fi
frames=$((bytes / frame_bytes))
echo "IRIS_DECODE_PASS codec=$codec frames=$frames geometry=${width}x$height linear=NV12 output=I420 matching_software_frames=$frames eos=1${sleep_mode:+ sleep_mode=$sleep_mode}"
