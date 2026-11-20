#!/bin/bash
# Sample the CCI0 source and branch with only the controller runtime-powered.
set -euo pipefail
export LC_ALL=C
dt=/sys/firmware/devicetree/base
controller=/sys/bus/platform/devices/ac15000.cci
node=$dt/soc@0/cci@ac15000
clk=/sys/kernel/debug/clk
control=$controller/power/control
unit=y700-cci0-clock-restore

grep -zFxq lenovo,asphalt "$dt/compatible"
grep -zFxq PRC "$dt/region_country"
[[ "$controller/of_node" -ef "$node" && "$controller/driver" -ef /sys/bus/platform/drivers/i2c-qcom-cci ]]
sensors=()
for device in /sys/bus/i2c/devices/*-0020; do
    if [[ "$device/of_node" -ef "$node/i2c-bus@0/camera@20" ]]; then sensors+=("$device"); fi
done
[[ ${#sensors[@]} == 1 ]]
sensor=${sensors[0]}
[[ "$sensor/driver" -ef /sys/bus/i2c/drivers/asphalt-sensors ]]
[[ $(<"$control") == auto && $(<"$sensor/power/control") == auto ]]

snapshot() {
    local phase=$1 expected=$2 name rate enable prepare branch_rate=0
    [[ $(<"$controller/power/runtime_status") == "$expected" ]]
    [[ $(<"$sensor/power/runtime_status") == suspended ]]
    [[ $(<"$clk/cam_cc_mclk0_clk/clk_enable_count") == 0 ]]
    for name in cam_cc_cci_0_clk cam_cc_cci_0_clk_src; do
        rate=$(<"$clk/$name/clk_rate")
        enable=$(<"$clk/$name/clk_enable_count")
        prepare=$(<"$clk/$name/clk_prepare_count")
        printf '%s clock=%s rate_hz=%s enabled=%s prepared=%s\n' "$phase" "$name" "$rate" "$enable" "$prepare"
        if [[ $expected == active ]]; then
            (( rate > 0 && enable > 0 && prepare > 0 ))
            if [[ $name == cam_cc_cci_0_clk ]]; then branch_rate=$rate; else (( rate == branch_rate )); fi
        else
            (( enable == 0 && prepare == 0 ))
        fi
    done
    printf '%s controller=%s hi1339=suspended mclk0_enabled=0\n' "$phase" "$expected"
}

snapshot before suspended
# The separate transient timer also releases the PM hold if SSH or this shell is lost.
systemd-run --quiet --collect --expand-environment=no --unit="$unit" --on-active=30s \
    --timer-property=AccuracySec=1s /bin/sh -ec 'echo auto > "$1"' sh "$control"
release() {
    echo auto > "$control" && systemctl stop "$unit.timer"
}
trap release EXIT
trap 'exit 1' HUP INT TERM
echo on > "$control"
snapshot during active
release
trap - EXIT HUP INT TERM
for _ in {1..40}; do
    [[ $(<"$controller/power/runtime_status") == suspended ]] && break
    sleep .25
done
[[ $(<"$control") == auto ]]
snapshot after suspended
