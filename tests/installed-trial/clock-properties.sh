#!/bin/bash
# Reconstruct the device-tree properties used by the on-board confirmation check.
set -euo pipefail
[[ $# == 2 && ! -e $2 ]] || exit 2
mkdir "$2"
dtc -q -s -I dtb -O dts "$1" | awk '
    $NF=="{" {path[depth+1] = depth ? path[depth] "/" $1 : ""; depth++; next}
    $1=="};" {depth--; next}
    $1 ~ /^assigned-(clocks|clock-parents|clock-rates)$/ ||
    $1 ~ /-supply$/ ||
    (path[depth]=="/soc@0/cci@ac15000/i2c-bus@0/lens@c" && $1 ~ /^(compatible|phandle|reg)$/) ||
    (path[depth]=="/soc@0/cci@ac15000/i2c-bus@0/camera@20" && $1=="lens-focus") ||
    (path[depth]=="/soc@0/rsc@17a00000/regulators-1/bob" && $1=="phandle") ||
    (path[depth]=="/soc@0/clock-controller@ade0000" && $1=="phandle") ||
    (path[depth]=="/soc@0/spmi@c400000/pmic@0/rtc@6100" && $1=="status") ||
    (path[depth]=="/soc@0/cci@ac16000/i2c-bus@0/regulator@29/regulators/ldo5" &&
      $1 ~ /^(phandle|regulator-name|regulator-min-microvolt|regulator-max-microvolt)$/) {
        print path[depth], $1
    }
' | while read -r node prop; do
    mkdir -p "$2$node"
    fdtget -t bx "$1" "$node" "$prop" | awk '{for (i=1;i<=NF;i++) printf "%02s", $i}' | tr ' ' 0 |
        xxd -r -p >"$2$node/$prop"
done
