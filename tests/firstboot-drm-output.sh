#!/bin/bash
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
select_output="$repo/src/firstboot-drm/select-output"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
sys=$work/sys
dev=$work/dev
mkdir -p "$sys" "$dev"
output() {
    local card=$1 port=$2 status=$3 id=$4 driver=$5
    mkdir -p "$sys/$card-$port" "$sys/$card/device" "$work/drivers/$driver"
    ln -sf "$work/drivers/$driver" "$sys/$card/device/driver"
    ln -sf /dev/null "$dev/$card"
    echo "$status" >"$sys/$card-$port/status"
    echo "$id" >"$sys/$card-$port/connector_id"
}
select_test() { bash "$select_output" "$sys" "$dev" "$work/compatible"; }
printf 'lenovo,asphalt\0qcom,sm8475\0' >"$work/compatible"
output card0 HDMI-A-1 connected 15 other
output card1 DP-1 disconnected 33 msm_dpu
output card1 Writeback-1 unknown 34 msm_dpu
output card1 DSI-1 connected 42 msm_dpu
test "$(select_test)" = '1 42'
echo unknown >"$sys/card1-DSI-1/status"
test "$(select_test)" = '1 42'
echo disconnected >"$sys/card1-DSI-1/status"
if select_test; then exit 1; fi
printf 'linux,dummy-virt\0' >"$work/compatible"
output card2 Unknown-1 unknown 31 simple-framebuffer
test "$(select_test)" = '2 31'
echo 'PASS: connected DSI on card1, no physical external or writeback fallback, and virtual simpledrm.'
