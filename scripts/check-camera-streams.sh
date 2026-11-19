#!/usr/bin/env bash
# Capture buffers are discarded. Run as the desktop user for a seat-access test.
set -euo pipefail
mode=${1:-all}
if (( $# > 1 )) || [[ $mode != raw && $mode != preview && $mode != all ]]; then
    echo 'Usage: check-camera-streams.sh [raw|preview|all]' >&2
    exit 2
fi
export LC_ALL=C LIBCAMERA_SOFTISP_MODE=cpu
export LD_LIBRARY_PATH=/opt/y700-camera/lib
cam=/opt/y700-camera/bin/cam
test -x "$cam"
grep -zFxq 'lenovo,asphalt' /proc/device-tree/compatible
if [[ $(id -u) == 0 ]]; then
    echo 'Access: root (hardware pipeline only)'
else
    echo 'Access: unprivileged user'
fi
report=$(mktemp)
trap 'rm -f -- "$report"' EXIT

capture() {
    local sensor=$1 id=$2 stream=$3 count=$4 format=$5
    if ! timeout -k 2s 18s "$cam" --camera "$id" --stream "$stream" --strict-formats --capture="$count" >"$report" 2>&1; then
        cat "$report" >&2
        return 1
    fi
    if ! grep -Fq -- "$format" "$report"; then
        echo "Unexpected capture format for $sensor ($stream)." >&2
        cat "$report" >&2
        return 1
    fi
    awk -v count="$count" -v sensor="$sensor" -v format="$format" '
        /cam0-stream0 seq:/ {
            seq=""
            bytes=""
            for (i=1; i<=NF; i++) {
                if ($i=="seq:") seq=$(i+1)
                if ($i=="bytesused:") bytes=$(i+1)
            }
            if (seq !~ /^[0-9]+$/ || bytes !~ /^[0-9]+$/ || bytes+0<=0 || (frames>0 && seq+0<=last)) bad=1
            frames++
            last=seq+0
        }
        END {
            if (frames!=count || bad) {
                print sensor, "invalid sequence, byte count or frame count", frames > "/dev/stderr"
                exit 1
            }
            print sensor, format, frames " frames", bytes " bytes in last buffer"
        }' "$report"
}

main=/base/soc@0/cci@ac15000/i2c-bus@0/camera@20
front=/base/soc@0/cci@ac15000/i2c-bus@1/camera@10
macro=/base/soc@0/cci@ac16000/i2c-bus@0/camera@36
if [[ $mode != preview ]]; then
    for pass in 1 2; do
        echo "RAW pass $pass"
        capture HI1339 "$main" role=raw 12 '4208x3120-SGBRG10_CSI2P/RAW'
        capture S5K4H7 "$front" role=raw 12 '3264x2448-SGRBG10_CSI2P/RAW'
        capture SC202CS "$macro" role=raw 12 '1600x1200-SBGGR10_CSI2P/RAW'
    done
fi
if [[ $mode != raw ]]; then
    preview=role=viewfinder,width=640,height=480,pixelformat=ABGR8888
    capture HI1339 "$main" "$preview" 6 '640x480-ABGR8888/sRGB'
    capture S5K4H7 "$front" "$preview" 6 '640x480-ABGR8888/sRGB'
    capture SC202CS "$macro" "$preview" 6 '640x480-ABGR8888/sRGB'
fi
