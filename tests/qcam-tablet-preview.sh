#!/usr/bin/env bash
# Exercise real viewfinder callbacks without displaying or storing the scene.
set -euo pipefail
export LC_ALL=C
grep -zFxq 'lenovo,asphalt' /proc/device-tree/compatible
test "$(id -u)" != 0
test -w /dev/udmabuf
test -x /usr/bin/y700-camera
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT
export XDG_RUNTIME_DIR="$temp"

preview() {
    local name=$1 camera=$2
    local log="$temp/qcam.log"
    if ! timeout --preserve-status -s INT -k 3s 7s /usr/bin/y700-camera \
          -platform offscreen --verbose --camera "$camera" \
          --stream role=viewfinder,width=640,height=480,pixelformat=ABGR8888 >"$log" 2>&1; then
        tail -n 12 "$log" >&2
        return 1
    fi
    grep -Fq '640x480-ABGR8888' "$log"
    grep -Fxq 'Exiting' "$log"
    awk -v name="$name" '
        /^seq: / {
            if ($2 !~ /^[0-9]+$/ || ($2+0 <= last && n) || $3 != "bytesused:" ||
                $4 != "{" || $5 != 640*480*4 || $6 != "}") bad=1
            last=$2+0
            n++
        }
        END {
            if (bad || n<12) {
                print name, "invalid qcam viewfinder sequence or buffer count", n > "/dev/stderr"
                exit 1
            }
            print name, n, "Qt viewfinder frames, 640x480 ABGR8888, clean close"
        }' "$log"
}

preview HI1339 /base/soc@0/cci@ac15000/i2c-bus@0/camera@20
preview S5K4H7 /base/soc@0/cci@ac15000/i2c-bus@1/camera@10
preview SC202CS /base/soc@0/cci@ac16000/i2c-bus@0/camera@36
