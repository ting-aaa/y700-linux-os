#!/bin/bash
# Read the exact sensor driver's successful chip-ID messages for this boot.
# All hardware-facing paths below are sysfs metadata. Never open a bus or camera.
set -euo pipefail
export LC_ALL=C
[[ $# == 0 ]] || { echo 'Usage: camera-sensor-board-id.sh' >&2; exit 2; }
reject() { echo "CAMERA_ID_INCOMPLETE $*" >&2; exit 1; }
dt=/sys/firmware/devicetree/base
cci=$dt/soc@0/cci@ac15000
i2c=/sys/bus/i2c
[[ $(uname -r) == 7.3.4-asphalt-prc && $(tr -d '\0' < "$dt/region_country") == PRC ]] &&
    tr '\0' '\n' < "$dt/compatible" | grep -Fxq lenovo,asphalt || reject 'unexpected board or kernel'
boot=$(tr -d '-' </proc/sys/kernel/random/boot_id)
[[ $boot =~ ^[0-9a-f]{32}$ ]] || reject 'invalid current boot identity'
messages=$(journalctl --quiet --no-pager --dmesg --boot="$boot" --output=cat \
    --grep='^asphalt-sensors [0-9]+-(0020|0010): (hi1339|s5k4h7) chip ') ||
    reject 'current boot kernel sensor messages unavailable'

check_sensor() {
    local master=$1 addr=$2 name=$3 compatible=$4 reg=$5 id=$6 size=$7
    local node=$cci/i2c-bus@$master sensor=$cci/i2c-bus@$master/camera@$addr
    local adapter adapter_id client parent observed line count pm
    local -a matches=()
    for adapter in "$i2c"/devices/i2c-*; do
        [[ "$adapter/of_node" -ef "$node" ]] && matches+=("$adapter")
    done
    [[ ${#matches[@]} == 1 ]] || reject "CCI0 master $master unavailable or ambiguous"
    adapter=${matches[0]}
    adapter_id=${adapter##*i2c-}
    [[ $adapter_id =~ ^[0-9]+$ && $(<"$adapter/name") == Qualcomm-CCI ]] ||
        reject "unexpected adapter for master $master"
    parent=$(dirname "$(realpath -e "$adapter")")
    [[ "$parent/of_node" -ef "$cci" && "$parent/driver" -ef /sys/bus/platform/drivers/i2c-qcom-cci ]] ||
        reject "wrong CCI controller for master $master"
    client=$i2c/devices/$adapter_id-00$addr
    [[ "$client/of_node" -ef "$sensor" && "$client/driver" -ef "$i2c/drivers/asphalt-sensors" &&
       $(tr -d '\0' < "$sensor/compatible") == "$compatible" ]] ||
        reject "expected registered $name on master $master"
    observed=$(od -An -tx1 -v "$node/reg" | tr -d ' \n')
    [[ $observed == "0000000$master" ]] || reject "wrong master reg for $name"
    observed=$(od -An -tx1 -v "$sensor/reg" | tr -d ' \n')
    [[ $observed == "000000$addr" ]] || reject "wrong client reg for $name"
    line="asphalt-sensors ${client##*/}: $name chip $id, $size RAW10"
    count=$(grep -Fxc -- "$line" <<<"$messages") || reject "no exact probe result for $name"
    pm=$(<"$client/power/runtime_status")
    printf 'CAMERA_ID master=%s client=0x%s sensor=%s reg=%s chip=%s matches=%s pm=%s source=boot_probe\n' \
        "$master" "$addr" "$name" "$reg" "$id" "$count" "$pm"
}
check_sensor 0 20 hi1339 hynix,hi1339 0x0716 0x1339 4208x3120
check_sensor 1 10 s5k4h7 samsung,s5k4h7 0x0000 0x487b 3264x2448
[[ $(tr -d '-' </proc/sys/kernel/random/boot_id) == "$boot" ]] || reject 'boot changed'
echo 'CAMERA_ID_PASS cci0_masters=2 hardware_id_reads_at_probe=2 new_transfers=0'
