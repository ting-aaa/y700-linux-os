#!/usr/bin/env bash
# Run exactly one requested mode on the PRC board as the ordinary tablet user.
set -euo pipefail
[[ $# == 2 && $EUID == 0 ]] || { echo 'Usage: measure-board.sh --self-test|--check-rear-config|--rear-af|--detached-rear-af EXECUTABLE' >&2; exit 2; }
mode=$1
tool=$(realpath -e -- "$2")
[[ -f $tool && -x $tool ]]
grep -zFxq lenovo,asphalt /proc/device-tree/compatible
[[ $(tr -d '\0' </proc/device-tree/region_country) == PRC ]]
diagnostic=${Y700_AF_DIAGNOSTICS:-0}
case $diagnostic in 0|1) ;; *) exit 2 ;; esac
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
        --setenv="Y700_AF_DIAGNOSTICS=$diagnostic" \
        -p "StandardOutput=append:$receipt" -p "StandardError=append:$receipt" \
        /bin/bash "$runner" --rear-af "$tool"
    printf 'AF_DISPATCH unit=%s receipt=%s\n' "$unit" "$receipt"
    exit 0
fi
case $mode in
    --self-test) isolated_devices=yes ;;
    --rear-af|--check-rear-config) isolated_devices=no ;;
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
if [[ $isolated_devices == no ]] && pgrep -x qcam >/dev/null; then
    echo 'The camera app is already open.' >&2
    exit 1
fi
before=$(cat "$sensor/power/runtime_active_time")
library=/opt/y700-camera/lib
levels='*:ERROR'
bind=()
diag_sha=6521ee7a227580b1108e1643f9c5889be6a9f6fdfedd73833cfab0a42ed971ce
if [[ ${Y700_AF_RAM_V2:-0} == 1 ]]; then
    [[ $diagnostic == 1 ]] && grep -qw y700.ram_af_acm=1 /proc/cmdline && grep -qw y700.media=ram /proc/cmdline || exit 1
    diag_sha=ab1cd0e90330a2b3905d8103b5be42fa098c4f15e494e8284c13f4decfcc5d23
    if [[ $isolated_devices == no ]]; then
        alias=${Y700_AF_PRIVATE_NODE:?missing private allocator}
        [[ $alias =~ ^/dev/y700-af-dma\.[[:alnum:]]{8}/udmabuf$ && ! -L $alias && -c $alias &&
           $(stat -c %u:%a "${alias%/*}") == 0:700 &&
           $(stat -c %u:%a:%t:%T "$alias") == "$(id -u y700):600:$(stat -c %t:%T /dev/udmabuf)" ]]
        bind=(-p "BindPaths=$alias:/dev/udmabuf")
    fi
fi
if [[ $diagnostic == 1 ]]; then
    stage=$(dirname -- "$tool")
    [[ $stage =~ ^/run/y700-af-optical\.[[:alnum:]]{8}$ && $(findmnt -nro FSTYPE -T "$stage") == tmpfs ]]
    [[ -f $stage/libcamera.so.0.7 && ! -L $stage/libcamera.so.0.7 ]]
    (cd "$stage" && printf '%s  %s\n' \
        "$diag_sha" libcamera.so.0.7 \
        90dfdbf117fd844ead381f9ffc4f365f35e185a204e0768d70c2c5394fff1773 "$library/libcamera.so.0.7.2" \
        7de9f8cf7eca33dc7cf4d14da83ed60d1240530f73f45c57484dc263f6ca5b8c "$library/libcamera-base.so.0.7.2" | sha256sum --quiet -c -)
    library=$stage:$library
    levels='*:FATAL,V4L2:ERROR,Y700Af:DEBUG'
fi
unit=y700-optical-$(cat /proc/sys/kernel/random/uuid)
rc=0
inhibit=()
if [[ $mode == --rear-af ]]; then
    inhibit=(systemd-inhibit --what=sleep:idle --mode=block --who=y700-optical --why="Rear camera measurement in progress")
fi
"${inhibit[@]}" systemd-run --unit="$unit" --quiet --collect --wait --pipe --uid=y700 "${bind[@]}" \
    -p "PrivateDevices=$isolated_devices" -p PrivateNetwork=yes -p ProtectSystem=strict \
    -p ProtectHome=yes -p PrivateTmp=yes -p NoNewPrivileges=yes -p LimitCORE=0 \
    -p RuntimeMaxSec=70s -p TimeoutStopSec=3s -p "RuntimeDirectory=$unit" -p RuntimeDirectoryMode=0700 \
    --setenv="HOME=/run/$unit" --setenv="XDG_CONFIG_HOME=/run/$unit" \
    --setenv="LD_LIBRARY_PATH=$library" --setenv=LIBCAMERA_SOFTISP_MODE=cpu \
    --setenv="LIBCAMERA_LOG_LEVELS=$levels" "$tool" "$mode" || rc=$?
for ((i=0; i<40; i++)); do
    [[ $(cat "$sensor/power/runtime_status") != suspended ]] || break
    sleep 0.25
done
[[ $(cat "$sensor/power/runtime_status") == suspended ]]
after=$(cat "$sensor/power/runtime_active_time")
if [[ $mode != --rear-af ]]; then [[ $before == "$after" ]]; fi
printf 'AF_CLEANUP mode=%s rear=suspended sensor_active_ms_delta=%s exit=%s\n' "$mode" "$((after - before))" "$rc"
exit "$rc"
