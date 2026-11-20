#!/usr/bin/env bash
set -euo pipefail
cd "$HOME"
[[ $(id -un) == y700 && $(findmnt -nro FSTYPE /sys) == tmpfs ]]
[[ ! -e /run/dbus/system_bus_socket && ! -e /sys/class/power_supply ]]
cat > bus.conf <<'XML'
<busconfig><type>system</type><listen>unix:path=/run/up-test/bus</listen>
<policy context="default"><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy>
</busconfig>
XML
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/up-test/bus
dbus-daemon --config-file=bus.conf --fork --print-pid > dbus.pid
daemon=
cleanup() {
    if [[ -n $daemon ]]; then kill "$daemon" 2>/dev/null || :; wait "$daemon" || :; fi
    kill "$(cat dbus.pid)" || :
}
trap cleanup EXIT
mkdir /sys/{bus,class,devices}
mkdir -p /sys/class/power_supply /sys/devices/platform/qa-battmgr/power_supply
device() {
    local name=$1 type=$2 item path=/sys/devices/platform/qa-battmgr/power_supply/$1
    shift 2
    mkdir "$path"
    ln -s /sys/class/power_supply "$path/subsystem"
    ln -s "$path" /sys/class/power_supply/"$name"
    printf 'POWER_SUPPLY_NAME=%s\nPOWER_SUPPLY_TYPE=%s\n' "$name" "$type" > "$path/uevent"
    printf '%s\n' "$type" > "$path/type"
    for item in "$@"; do printf '%s\n' "${item#*=}" > "$path/${item%%=*}"; done
}
device qcom-battmgr-bat Battery present=1 status=Full capacity=100 voltage_now=4417000 current_now=0 \
    power_now=48000000 temp=150 charge_counter=5078000 charge_full=5078000 charge_full_design=6550000 technology=Li-ion
device qcom-battmgr-usb USB online=1 'usb_type=Unknown [SDP] DCP' voltage_now=5074000 current_now=147000
device qcom-battmgr-wls Wireless online=0
for port in 01 02; do
    online=0
    [[ $port != 01 ]] || online=1
    device "ucsi-source-psy-pmic_glink.ucsi.$port" USB "online=$online" 'usb_type=[C] PD'
done
bus=(dbus-send --system --print-reply=literal --reply-timeout=2500 --dest=org.freedesktop.UPower)
mkdir data
export UPOWER_STATE_DIR=$PWD/data UPOWER_HISTORY_DIR=$PWD/data
/usr/libexec/upowerd --debug > daemon.log 2>&1 &
daemon=$!
for ((try=0; try<100; try++)); do
    if "${bus[@]}" /org/freedesktop/UPower org.freedesktop.UPower.EnumerateDevices > devices 2>/dev/null; then break; fi
    if ! kill -0 "$daemon" 2>/dev/null; then cat daemon.log >&2; exit 1; fi
    sleep .1
done
cat devices
bat=$(upower -e | grep '/battery_')
[[ -n $bat && $bat != *$'\n'* ]] || { cat daemon.log >&2; exit 1; }
ac=$(upower -e | grep '/line_power_qcom.*usb')
[[ -n $ac ]]
read_property() {
    "${bus[@]}" "$1" org.freedesktop.DBus.Properties.Get "string:$2" "string:$3" |
        awk '$1=="variant" && NF==3 {print $2, $3}'
}
prop() { read_property "$1" org.freedesktop.UPower.Device "$2"; }
echo "actual=$(upower --version | tail -1) arch=$(dpkg --print-architecture) uid=$(id -u)"
for path in "$bat" "$ac" /org/freedesktop/UPower/devices/DisplayDevice; do
    echo "$path"
    for property in Type State Percentage Energy EnergyFull EnergyRate TimeToEmpty TimeToFull Online; do
        printf '%s=%s\n' "$property" "$(prop "$path" "$property")"
    done
done
[[ $(prop "$bat" State) == 'uint32 4' && $(prop "$bat" Percentage) == 'double 100' && $(prop "$bat" EnergyRate) == 'double 0' ]]
[[ $(prop "$ac" Online) == 'boolean true' ]]
echo FULL_CHARGE_CONFLICT_PASS
if [[ -f /run/tray.sh ]]; then
    install -d -m700 "$HOME/xdg"
    XDG_RUNTIME_DIR="$HOME/xdg" dbus-run-session -- bash /run/tray.sh
    exit
fi

# Refresh asks this running debug daemon to reread the mock attributes.
refresh() { "${bus[@]}" "$1" org.freedesktop.UPower.Device.Refresh; }
usb_bat() { read_property /org/freedesktop/UPower org.freedesktop.UPower OnBattery; }
dp=/org/freedesktop/UPower/devices/DisplayDevice
port=$(upower -e | grep '/line_power_ucsi_.*01$')
base=/sys/class/power_supply
for scenario in discharging charging; do
    case $scenario in
        discharging) status=Discharging; level=50; current=-1000000; online=0; state=2; onb=true ;;
        charging) status=Charging; level=60; current=1000000; online=1; state=1; onb=false ;;
    esac
    printf '%s\n' "$status" > "$base/qcom-battmgr-bat/status"
    printf '%s\n' "$level" > "$base/qcom-battmgr-bat/capacity"
    printf '%s\n' "$((5078000 * level / 100))" > "$base/qcom-battmgr-bat/charge_counter"
    printf '%s\n' "$current" > "$base/qcom-battmgr-bat/current_now"
    printf '%s\n' "$online" | tee "$base/qcom-battmgr-usb/online" > "$base/ucsi-source-psy-pmic_glink.ucsi.01/online"
    refresh "$port"; refresh "$ac"
    for ((try=0; try<25; try++)); do
        refresh "$bat"
        [[ $(prop "$dp" State) != "uint32 $state" || $(prop "$dp" EnergyRate) != 'double 4.417' ]] || break
        sleep .5
    done
    echo "scenario=$scenario display-state=$(prop "$dp" State) percent=$(prop "$dp" Percentage) rate=$(prop "$dp" EnergyRate) on-battery=$(usb_bat) seconds-to-empty=$(prop "$dp" TimeToEmpty) seconds-to-full=$(prop "$dp" TimeToFull)"
    [[ $(prop "$dp" State) == "uint32 $state" && $(prop "$dp" Percentage) == "double $level" ]]
    [[ $(prop "$dp" EnergyRate) == 'double 4.417' && $(usb_bat) == "boolean $onb" ]]
done
echo SYNTHETIC_CHARGING_DISCHARGING_PASS
