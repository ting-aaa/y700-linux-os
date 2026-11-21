#!/usr/bin/env bash
# Query the installed libcamera interface as a regular user, without starting a stream.
set -euo pipefail
[[ $(id -u) != 0 ]]
grep -zFxq lenovo,asphalt /proc/device-tree/compatible
export LC_ALL=C LD_LIBRARY_PATH=/opt/y700-camera/lib LIBCAMERA_SOFTISP_MODE=cpu
ids=(
    /base/soc@0/cci@ac15000/i2c-bus@0/camera@20
    /base/soc@0/cci@ac15000/i2c-bus@1/camera@10
    /base/soc@0/cci@ac16000/i2c-bus@0/camera@36
)
roles=(rear front macro)
pm=()
elapsed=()
for id in "${ids[@]}"; do
    node=/proc/device-tree/${id#/base/}
    sensors=()
    for dev in /sys/bus/i2c/devices/*-????; do
        if [[ $dev/of_node -ef $node ]]; then sensors+=("$dev"); fi
    done
    [[ ${#sensors[@]} == 1 ]]
    pm+=("${sensors[0]}/power")
done
for power in "${pm[@]}"; do
    [[ $(cat "$power/runtime_status") == suspended ]]
    elapsed+=("$(cat "$power/runtime_active_time")")
done
for i in "${!ids[@]}"; do
    controls=$(timeout 12 /opt/y700-camera/bin/cam --camera "${ids[i]}" --list-controls)
    grep -q '^Control: ' <<<"$controls"
    if [[ $i == 0 ]]; then
        for value in AfModeManual AfModeAuto AfTriggerStart AfTriggerCancel AfStateIdle AfStateScanning AfStateFocused AfStateFailed; do
            grep -Eq "^  - $value \(" <<<"$controls"
        done
        echo "CAMERA_CONTROLS lens=${roles[i]} autofocus=single-shot cancel=1"
    else
        if grep -Eq 'libcamera::(AfMode|AfTrigger|AfState):' <<<"$controls"; then exit 1; fi
        echo "CAMERA_CONTROLS lens=${roles[i]} autofocus=fixed"
    fi
done
for i in "${!pm[@]}"; do
    [[ $(cat "${pm[i]}/runtime_status") == suspended ]]
    [[ $(cat "${pm[i]}/runtime_active_time") == "${elapsed[i]}" ]]
done
echo 'CAMERA_CONTROLS_PASS streams=0 sensors_suspended=3 active_ms_delta=0'
