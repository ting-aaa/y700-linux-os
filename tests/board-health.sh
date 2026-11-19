#!/usr/bin/env bash
# Read the Y700's kernel health interfaces without changing board settings.
set -euo pipefail
export LC_ALL=C
shopt -s nullglob

samples=${1:-3}
interval=${2:-2}
if (( $# > 2 )) || [[ ! $samples =~ ^[1-5]$ || ! $interval =~ ^[1-5]$ ]]; then
    echo 'Usage: bash tests/board-health.sh [samples 1..5] [seconds between samples 1..5]' >&2
    exit 2
fi
sys=/sys/class

read_label() {
    local text
    { IFS= read -r text < "$1"; } 2>/dev/null || return 1
    [[ $text =~ ^[A-Za-z0-9_.+-]+$ ]] || return 1
    printf '%s\n' "$text"
}

aliases() {
    local dir path name owner parent family target
    for dir in "$sys"/hwmon/hwmon*; do
        name=$(read_label "$dir/name") || continue
        path=$(readlink -e -- "$dir/device") || continue
        owner=${path##*/}
        parent=${path%/*}
        case ${parent##*/}:$owner in
            thermal:thermal_zone*) family=thermal ;;
            power_supply:*) family=power_supply ;;
            *) continue ;;
        esac
        target=$sys/$family/$owner
        [[ $target -ef $path ]] || continue
        printf 'ALIAS\t%s\t%s\t%s\n' "$dir" "$name" "$target"
    done
}

snapshot() {
    local pass uptime dir name role online
    for (( pass=1; pass<=samples; pass++ )); do
        read -r uptime _ < /proc/uptime
        for dir in "$sys"/thermal/thermal_zone*; do
            name=$(read_label "$dir/type") || continue
            case $name in
                qcom-battmgr-bat)
                    if [[ -e $sys/power_supply/qcom-battmgr-bat/temp ]]; then
                        if (( pass == 1 )); then
                            printf 'ALIAS\t%s/temp\t%s\t%s/power_supply/qcom-battmgr-bat/temp\n' "$dir" "$name" "$sys"
                        fi
                        continue
                    fi
                    role=battery-temperature ;;
                pm8350-thermal|pm8350c-thermal|pmr735a-thermal) role=pmic-alarm ;;
                *) role=thermal ;;
            esac
            record "$dir/temp" "$name" "$role" mC
        done

        for dir in "$sys"/hwmon/hwmon*; do
            name=$(read_label "$dir/name") || continue
            # On this board the other hwmon channels mirror thermal or power_supply.
            [[ $name == ath11k_hwmon ]] || continue
            record "$dir/temp1_input" "$name" wifi-die mC
        done

        for dir in "$sys"/power_supply/qcom-battmgr-* "$sys"/power_supply/ucsi-source-psy-*; do
            name=${dir##*/}
            [[ $name =~ ^[A-Za-z0-9_.-]+$ ]] || continue
            if [[ $name == ucsi-source-psy-* ]]; then
                record "$dir/online" "$name" contract code
                record "$dir/voltage_now" "$name" contract uV
                record "$dir/current_now" "$name" contract uA
                record "$dir/voltage_max" "$name" contract uV
                record "$dir/current_max" "$name" contract uA
                continue
            fi
            if [[ $name == qcom-battmgr-bat ]]; then
                record "$dir/present" "$name" state bool
                record "$dir/status" "$name" state text
                record "$dir/health" "$name" state text
                record "$dir/capacity" "$name" fuel-gauge percent
                record "$dir/temp" "$name" battery-temperature deciC
                record "$dir/voltage_now" "$name" pmic-telemetry uV
                record "$dir/voltage_ocv" "$name" fuel-gauge-estimate uV
                record "$dir/current_now" "$name" pmic-telemetry uA
                record "$dir/power_now" "$name" pmic-reported-power uW
                record "$dir/charge_counter" "$name" fuel-gauge uAh
                record "$dir/charge_full" "$name" fuel-gauge-estimate uAh
                record "$dir/charge_full_design" "$name" design uAh
                continue
            fi
            # Use the same online read for output and for the input telemetry's status.
            record "$dir/online" "$name" state bool online
            case $online in
                0) role=input-inactive ;;
                1) role=input-telemetry ;;
                *) role=input-state-unknown ;;
            esac
            record "$dir/voltage_now" "$name" "$role" uV
            record "$dir/current_now" "$name" "$role" uA
            record "$dir/voltage_max" "$name" limit uV
            record "$dir/current_max" "$name" limit uA
            record "$dir/input_current_limit" "$name" limit uA
        done

        dir=$sys/backlight/ktz8866-backlight
        name=ktz8866-backlight
        record "$dir/brightness" "$name" requested step
        record "$dir/actual_brightness" "$name" driver-state step
        record "$dir/max_brightness" "$name" limit step
        record "$dir/bl_power" "$name" driver-state code

        if (( pass < samples )); then sleep "$interval"; fi
    done
}

record() {
    local path=$1 name=$2 role=$3 unit=$4 value=-
    if [[ ! -e $path ]]; then
        if (( $# == 5 )); then printf -v "$5" '%s' "$value"; fi
        return 0
    fi
    if ! { IFS= read -r value < "$path"; } 2>/dev/null; then
        value=-
    elif [[ ! $value =~ ^[A-Za-z0-9+_.\ -]+$ ]]; then
        value=invalid
    fi
    if (( $# == 5 )); then printf -v "$5" '%s' "$value"; fi
    printf 'DATA\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pass" "$uptime" "$path" "$name" "$role" "$unit" "$value"
}

{
    aliases
    snapshot
} | awk -F '\t' '
BEGIN {
    OFS = "\t"
    print "DATA_COLUMNS", "sample", "uptime_s", "sysfs", "name", "kind", "unit", "raw", "quality"
    print "SUMMARY_COLUMNS", "sysfs", "name", "unit", "valid", "seen", "variation", "first", "last", "min", "max"
}
$1 == "ALIAS" {print; next}
$1 == "DATA" {
    path = $4; kind = $6; unit = $7; raw = $8
    numeric = (raw ~ /^-?[0-9]+$/)
    value = raw + 0
    quality = "ok"
    if (raw == "-") quality = "read-error"
    else if (raw == "invalid" || (unit != "text" && !numeric)) quality = "invalid"
    else if (numeric && (value == -2147483648 || value == 2147483647 || value == 4294967295 ||
             (unit == "mC" && value == -274000))) quality = "sentinel"
    else if ((unit == "mC" && (value < -40000 || value > 150000)) ||
             (unit == "deciC" && (value < -400 || value > 1500)) ||
             (unit == "percent" && (value < 0 || value > 100)) ||
             (unit == "bool" && value != 0 && value != 1) ||
             (unit == "step" && value < 0)) quality = "out-of-range"
    else if (kind == "pmic-alarm" && value == 37000) quality = "alarm-default"
    else if (kind == "input-inactive") quality = "inactive"
    else if (kind == "input-state-unknown") quality = "online-unknown"
    else if (kind == "pmic-reported-power" && ($2 in battery_current) &&
             battery_current[$2] == 0 && value != 0) quality = "zero-current-mismatch"

    if ($5 == "qcom-battmgr-bat" && path ~ /\/current_now$/ && quality == "ok")
        battery_current[$2] = value

    print $0, quality
    if (!(path in seen)) { ordered[++count] = path; names[path] = $5; units[path] = unit }
    seen[path]++
    if (quality != "ok") next
    if (++valid[path] == 1) {
        first[path] = raw
        if (numeric) { low[path] = value; high[path] = value }
    }
    if (raw != first[path]) changed[path] = 1
    if (numeric && value < low[path]) low[path] = value
    if (numeric && value > high[path]) high[path] = value
    last[path] = raw
}
END {
    for (i = 1; i <= count; i++) {
        path = ordered[i]
        variation = (valid[path] == 0 ? "no-valid" : valid[path] == 1 ? "one" : changed[path] ? "changed" : "steady")
        print "SUMMARY", path, names[path], units[path], valid[path]+0, seen[path], variation,
              (path in first ? first[path] : "-"), (path in last ? last[path] : "-"),
              (path in low ? low[path] : "-"), (path in high ? high[path] : "-")
    }
    if (count == 0) exit 3
}'
