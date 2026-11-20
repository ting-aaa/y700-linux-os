#!/bin/bash
# Read the ordinary desktop user's UPower view alongside the board's PMIC values.
set -euo pipefail
export LC_ALL=C
[[ $(id -u) != 0 ]]
grep -zFxq lenovo,asphalt /proc/device-tree/compatible
service=org.freedesktop.UPower
root=/org/freedesktop/UPower
device=$service.Device
base=/sys/class/power_supply
battery=qcom-battmgr-bat
usb=qcom-battmgr-usb
property() {
    busctl --system get-property "$service" "$1" "$2" "$3" | cut -d' ' -f2-
}
list=$(upower --enumerate)
batt_path= usb_path=
while read -r path; do
    [[ $path == "$root/devices/"* ]] || continue
    case $(property "$path" "$device" NativePath) in
        "\"$battery\"") batt_path=$path ;;
        "\"$usb\"") usb_path=$path ;;
    esac
done <<<"$list"
[[ -n $batt_path && -n $usb_path ]]
display=$(busctl --system call "$service" "$root" "$service" GetDisplayDevice | cut -d'"' -f2)
[[ $(property "$display" "$device" Type) == 2 ]]
before=$(cat "$base/$battery/status" "$base/$battery/capacity" "$base/$usb/online")
mapfile -t values <<<"$before"
raw=${values[0]}
capacity=${values[1]}
online=${values[2]}
case $raw in Charging) state=1 ;; Discharging) state=2 ;; Empty) state=3 ;; Full) state=4 ;; *) echo "No comparable battery state ($raw)"; exit 77 ;; esac
for path in "$batt_path" "$display"; do
    [[ $(property "$path" "$device" State) == "$state" ]]
    reported=$(property "$path" "$device" Percentage)
    [[ $reported =~ ^[0-9]+([.][0-9]+)?$ && $capacity =~ ^[0-9]+$ ]]
    awk -v reported="$reported" -v kernel="$capacity" 'BEGIN {exit !(kernel<=100 && reported+0==kernel+0)}'
done
cable=$(property "$usb_path" "$device" Online)
[[ "$online:$cable" == 1:true || "$online:$cable" == 0:false ]]
rate=$(property "$display" "$device" EnergyRate)
current=$(cat "$base/$battery/current_now")
reported_power=$(cat "$base/$battery/power_now")
after=$(cat "$base/$battery/status" "$base/$battery/capacity" "$base/$usb/online")
[[ $before == "$after" ]] || { echo 'Battery changed during the comparison; retry the sample.' >&2; exit 75; }
printf 'POWER_BOARD battery=%s percentage=%s usb_online=%s display_rate_w=%s current_ua=%s raw_power_uw=%s on_battery=%s\n' \
    "$raw" "$capacity" "$cable" "$rate" "$current" "$reported_power" "$(property "$root" "$service" OnBattery)"
if [[ $raw == Full && $current == 0 ]]; then
    [[ $rate == 0 && $(property "$display" "$device" TimeToEmpty) == 0 && $(property "$display" "$device" TimeToFull) == 0 ]]
    echo 'POWER_BOARD full_zero_current=zero_display_rate unknown_time_estimates=0'
fi
