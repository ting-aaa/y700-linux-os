#!/usr/bin/env bash
# Run exactly one requested mode on the PRC board as the ordinary tablet user.
set -euo pipefail
[[ $# == 2 && $EUID == 0 ]] || { echo 'Usage: measure-board.sh --self-test|--rear-af|--detached-rear-af EXECUTABLE' >&2; exit 2; }
mode=$1
tool=$(realpath -e -- "$2")
[[ -f $tool && -x $tool ]]
grep -zFxq lenovo,asphalt /proc/device-tree/compatible
[[ $(tr -d '\0' </proc/device-tree/region_country) == PRC ]]
if [[ $mode == --detached-rear-af ]]; then
    # Keep the receipt in this boot's tmpfs even if the USB shell goes away.
    runner=$(realpath -e -- "$0")
    stage=$(dirname -- "$tool")
    [[ $stage =~ ^/run/y700-af-optical\.[[:alnum:]]{8}$ && $runner == "$stage/measure-board.sh" ]]
    [[ $(findmnt -nro FSTYPE -T "$stage") == tmpfs && $(stat -c %u -- "$stage" "$runner" "$tool" | sort -u) == 0 ]]
    [[ -z $(find "$stage" -maxdepth 1 -perm /022 -print -quit) ]]
    receipt=$stage/receipt.log
    (umask 077; set -C; : > "$receipt")
    unit=y700-af-run-${stage##*.}
    systemd-run --quiet --collect --unit="$unit" -p RuntimeMaxSec=90s -p TimeoutStopSec=3s \
        -p "StandardOutput=append:$receipt" -p "StandardError=append:$receipt" \
        /bin/bash "$runner" --rear-af "$tool"
    printf 'AF_DISPATCH unit=%s receipt=%s\n' "$unit" "$receipt"
    exit 0
fi
case $mode in
    --self-test) isolated_devices=yes ;;
    --rear-af) isolated_devices=no ;;
    *) exit 2 ;;
esac
if [[ $mode == --rear-af ]]; then
    options=,$(findmnt -nro OPTIONS -T /),
    if [[ $options == *,ro,* || $options == *,emergency_ro,* ]]; then
        echo 'AF_ERROR reason=root_filesystem_read_only' >&2
        exit 1
    fi
fi
sensor=
node=/proc/device-tree/soc@0/cci@ac15000/i2c-bus@0/camera@20
for dev in /sys/bus/i2c/devices/*-0020; do
    if [[ $dev/of_node -ef $node ]]; then sensor=$dev; fi
done
[[ -n $sensor && $(cat "$sensor/power/runtime_status") == suspended ]]
if [[ $mode == --rear-af ]] && pgrep -x qcam >/dev/null; then
    echo 'The camera app is already open.' >&2
    exit 1
fi
before=$(cat "$sensor/power/runtime_active_time")
unit=y700-optical-$(cat /proc/sys/kernel/random/uuid)
rc=0
inhibit=()
if [[ $mode == --rear-af ]]; then
    inhibit=(systemd-inhibit --what=sleep:idle --mode=block --who=y700-optical --why="Rear camera measurement in progress")
fi
"${inhibit[@]}" systemd-run --unit="$unit" --quiet --collect --wait --pipe --uid=y700 \
    -p "PrivateDevices=$isolated_devices" -p PrivateNetwork=yes -p ProtectSystem=strict \
    -p ProtectHome=yes -p PrivateTmp=yes -p NoNewPrivileges=yes -p LimitCORE=0 \
    -p RuntimeMaxSec=70s -p TimeoutStopSec=3s -p "RuntimeDirectory=$unit" -p RuntimeDirectoryMode=0700 \
    --setenv="HOME=/run/$unit" --setenv="XDG_CONFIG_HOME=/run/$unit" \
    --setenv=LD_LIBRARY_PATH=/opt/y700-camera/lib --setenv=LIBCAMERA_SOFTISP_MODE=cpu \
    --setenv='LIBCAMERA_LOG_LEVELS=*:ERROR' "$tool" "$mode" || rc=$?
for ((i=0; i<40; i++)); do
    [[ $(cat "$sensor/power/runtime_status") != suspended ]] || break
    sleep 0.25
done
[[ $(cat "$sensor/power/runtime_status") == suspended ]]
after=$(cat "$sensor/power/runtime_active_time")
if [[ $mode == --self-test ]]; then [[ $before == "$after" ]]; fi
printf 'AF_CLEANUP mode=%s rear=suspended sensor_active_ms_delta=%s exit=%s\n' "$mode" "$((after - before))" "$rc"
exit "$rc"
