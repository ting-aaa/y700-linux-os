#!/bin/bash
# Reconstruct the device-tree properties used by the on-board confirmation check.
set -euo pipefail
[[ $# == 2 && ! -e $2 ]] || exit 2
mkdir "$2"
dtc -q -s -I dtb -O dts "$1" | awk '
    $NF=="{" {path[depth+1] = depth ? path[depth] "/" $1 : ""; depth++; next}
    $1=="};" {depth--; next}
    $1 ~ /^assigned-(clocks|clock-parents|clock-rates)$/ ||
    (path[depth]=="/soc@0/clock-controller@ade0000" && $1=="phandle") {
        print path[depth], $1
    }
' | while read -r node prop; do
    mkdir -p "$2$node"
    fdtget -t bx "$1" "$node" "$prop" | awk '{for (i=1;i<=NF;i++) printf "%02s", $i}' | tr ' ' 0 |
        xxd -r -p >"$2$node/$prop"
done
