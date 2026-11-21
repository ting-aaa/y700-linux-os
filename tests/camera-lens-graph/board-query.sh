#!/usr/bin/env bash
# Read the linked lens control limits without streaming or writing a control.
set -euo pipefail
export LC_ALL=C
installed=false
if [[ ${1:-} == --installed ]]; then installed=true; shift; fi
[[ $# == 1 ]] || { echo 'Usage: board-query.sh [--installed] LENS_GRAPH_BINARY' >&2; exit 2; }
check=$(realpath -e -- "$1")
dt=/sys/firmware/devicetree/base
bus=$dt/soc@0/cci@ac15000/i2c-bus@0
rail_base=$dt/soc@0/cci@ac16000/i2c-bus@0/regulator@29/regulators
if $installed; then
    grep -Fqw y700.release=dev12.11 /proc/cmdline
    grep -Fxq IMAGE_VERSION=dev12.11 /etc/os-release
    [[ $(sha256sum /sys/kernel/notes | cut -d' ' -f1) == 35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6 ]]
else
    grep -qw 'y700.focus_probe=gt9768' /proc/cmdline
fi
cmp -s <(printf 'PRC\0') "$dt/region_country"
cmp -s <(printf 'lenovo,tb320fc-gt9768\0') "$bus/lens@c/compatible"
cmp -s "$bus/lens@c/phandle" "$bus/camera@20/lens-focus"
adapters=()
for dev in /sys/bus/i2c/devices/i2c-*; do
    if [[ "$dev/of_node" -ef "$bus" ]]; then adapters+=("$dev"); fi
done
[[ ${#adapters[@]} == 1 ]]
nr=${adapters[0]##*/i2c-}
sensor=/sys/bus/i2c/devices/$nr-0020
lens=/sys/bus/i2c/devices/$nr-000c
[[ "$sensor/of_node" -ef "$bus/camera@20" && "$lens/of_node" -ef "$bus/lens@c" ]]
[[ $(basename "$(readlink -e "$lens/driver")") == asphalt-gt9768 ]]

idle() {
    [[ $(cat "$sensor/power/runtime_status") == suspended ]] || return 1
    # On the combined DT a regulator state read can wake the second CCI bus.
    if $installed; then return 0; fi
    local rail dev matches
    for rail in ldo1 ldo4 ldo5; do
        matches=0
        for dev in /sys/class/regulator/regulator.*; do
            if [[ "$dev/of_node" -ef "$rail_base/$rail" ]]; then
                [[ $(cat "$dev/state") == disabled && $(cat "$dev/num_users") == 0 ]] || return 1
                matches=$((matches + 1))
            fi
        done
        [[ $matches == 1 ]] || return 1
    done
}
for ((i=0; i<12; i++)); do idle && break; sleep 1; done
idle
before=$(cat "$sensor/power/runtime_active_time")
media=()
for dev in /dev/media*; do
    if line=$("$check" "$dev" "hi1339 $nr-0020" 2>/dev/null); then
        media+=("$dev")
        topology=$line
    fi
done
[[ ${#media[@]} == 1 && $topology == *"lens=\"gt9768 $nr-000c\""* ]]
interface=${topology##*interface=}
[[ $interface =~ ^[0-9]+:[0-9]+$ ]]
name=$(sed -n 's/^DEVNAME=//p' "/sys/dev/char/$interface/uevent")
[[ $name =~ ^v4l-subdev[0-9]+$ ]]
"$check" "${media[0]}" "hi1339 $nr-0020" --check-limits "/dev/$name"
idle
[[ $(cat "$sensor/power/runtime_active_time") == "$before" ]]
if $installed; then
    echo 'LENS_QUERY_PASS sensor_active_time_unchanged=1 installed=dev12.11'
else
    echo 'LENS_QUERY_PASS sensor_active_time_unchanged=1 ldo1_ldo4_ldo5=disabled users=0'
fi
