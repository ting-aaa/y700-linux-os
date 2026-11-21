#!/bin/bash
# Read-only check on the running TB320FC_PRC. Run as root with bash.
set -eu -o pipefail
export LC_ALL=C
fail() { printf 'PANEL_FAIL %s\n' "$*" >&2; exit 1; }

# Match the listening X socket to its owning server, including LightDM's
# -displayfd startup where the display number can be absent from the argv.
display_server() {
    local p links socket matches=()
    local -a sockets
    mapfile -t sockets < <(awk '$4=="00010000" && $5=="0001" &&
        ($8=="/tmp/.X11-unix/X0" || $8=="@/tmp/.X11-unix/X0") {print $7}' /proc/net/unix)
    while read -r p; do
        links=$(find "/proc/$p/fd" -maxdepth 1 -type l -printf '%l\n' 2>/dev/null) || continue
        for socket in "${sockets[@]}"; do
            if grep -Fxq "socket:[$socket]" <<< "$links"; then matches+=("$p"); break; fi
        done
    done < <(pgrep -x Xorg || :)
    (( ${#matches[@]} == 1 )) || return 1
    printf '%s\n' "${matches[0]}"
}

mapped_file() {
    local p=$1 target=$2 expected=$3 descriptor major minor ino dev digest
    # Hash an open inode in the server's filesystem view and compare every
    # mapping for the driver's path, including any stale deleted mapping.
    exec {descriptor}<"/proc/$p/root$target" || return 1
    read -r major minor ino < <(stat -Lc '%Hd %Ld %i' "/dev/fd/$descriptor") || return 1
    printf -v dev '%02x:%02x' "$major" "$minor"
    digest=$(sha256sum <&"$descriptor") || return 1
    exec {descriptor}<&-
    [[ ${digest%% *} == "$expected" ]] || return 1
    awk -v path="$target" -v dev="$dev" -v ino="$ino" '
        $6 == path {
            if (NF != 6 || $4 != dev || ("i"$5) != ("i"ino)) bad=1
            if ($2 ~ /x/) executable=1
        }
        END {exit !(executable && !bad)}
    ' "/proc/$p/maps" || return 1
    printf 'PANEL_DRIVER pid=%s device=%s inode=%s sha256=%s\n' "$p" "$dev" "$ino" "$expected"
}

panel_mode() {
    awk '
        /^[^[:space:]]/ {
            active=($1=="DSI-1" && $2=="connected")
            if (active) {
                outputs++
                rotation="normal"
                for (i=3;i<=NF;i++) {
                    if ($i=="118mm" && $(i+1)=="x" && $(i+2)=="190mm") mm=1
                    if ($i ~ /^[0-9]+x[0-9]+[+][+-]?[0-9]+[+][+-]?[0-9]+$/) geometry=$i
                    if ($i ~ /^\(/) capabilities=1
                    if (!capabilities && $i ~ /^(normal|left|right|inverted)$/) rotation=$i
                }
            }
            next
        }
        active && $1 ~ /^[0-9]+x[0-9]+$/ {
            for (i=2;i<=NF;i++) if ($i ~ /^[0-9.]+\*[+]?$/) {
                modes++; mode=$1; hz=$i; sub(/\*.*/, "", hz)
            }
        }
        END {
            if (outputs != 1 || modes != 1 || geometry=="" || !mm) exit 1
            printf "mode=%s hz=%s geometry=%s rotation=%s panel_mm=118x190\n",mode,hz,geometry,rotation
        }
    '
}

greeter_keyboard() {
    local p scale found=0 display
    while read -r p; do
        [[ -r /proc/$p/environ ]] || continue
        display=$(tr '\0' '\n' <"/proc/$p/environ" | sed -n 's/^DISPLAY=//p') || continue
        [[ $display == :0 || $display == :0.0 ]] || continue
        scale=$(tr '\0' '\n' <"/proc/$p/environ" | sed -n 's/^GDK_SCALE=//p') || continue
        [[ -z $scale || $scale =~ ^[0-9]+$ ]] || scale=non-numeric
        printf 'PANEL_GREETER_ONBOARD pid=%s GDK_SCALE=%s\n' "$p" "${scale:-unset}"
        found=1
    done < <(pgrep -u lightdm -f '(^|[[:space:]])/usr/bin/onboard([[:space:]]|$)' || :)
    if (( !found )); then echo 'PANEL_GREETER_ONBOARD observed=absent'; fi
}

main() {
    [[ $# == 0 && $EUID == 0 ]] || fail 'run as root without arguments'
    grep -azFxq lenovo,asphalt /proc/device-tree/compatible &&
        [[ $(tr -d '\0' </proc/device-tree/region_country) == PRC ]] || fail 'unexpected board'
    export DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0
    local target=/usr/lib/xorg/modules/drivers/modesetting_drv.so
    local expected=8db0cd0e45540948fd847b601e85f1c71647461a992869f0f653d48121f206e4
    local version='2:21.1.16-1.3+deb13u4+y7001' package p sys edid i listing measurement touch
    local panels=()
    p=$(display_server) || fail 'cannot identify unique Xorg listening on :0'
    for package in xserver-xorg-core xserver-common; do
        [[ $(dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$package") == "ii  $version" ]] ||
            fail "version or installation status of $package"
    done
    printf 'PANEL_PACKAGES xserver-xorg-core=%s xserver-common=%s\n' "$version" "$version"
    mapped_file "$p" "$target" "$expected" || fail 'mapped driver identity'
    for sys in /sys/class/drm/card*-DSI-1; do
        if [[ -f $sys/status && $(cat "$sys/status") == connected ]]; then panels+=("$sys"); fi
    done
    (( ${#panels[@]} == 1 )) || fail 'expected one connected DSI-1'
    sys=${panels[0]}
    edid=$(wc -c <"$sys/edid") || fail 'EDID read'
    printf 'PANEL_DRM connector=%s edid_bytes=%d\n' "${sys##*/}" "$edid"
    (( edid == 0 )) || fail 'expected empty EDID'
    for i in 1 2 3; do
        listing=$(timeout 8 xrandr --current) || fail "RandR query $i"
        if ! measurement=$(panel_mode <<< "$listing"); then
            awk '$1=="DSI-1" {print}' <<< "$listing" >&2
            fail "RandR geometry or current mode in query $i"
        fi
        printf 'PANEL_RANDR query=%s %s\n' "$i" "$measurement"
    done
    [[ $(display_server) == "$p" ]] || fail 'X server changed during probes'
    touch=$(timeout 3 xinput list --id-only 'NT36523N Capacitive Touchscreen' 2>/dev/null) || touch=
    if [[ $touch =~ ^[0-9]+$ ]]; then echo "PANEL_TOUCH xinput_id=$touch"; else echo 'PANEL_TOUCH observed=unavailable'; fi
    greeter_keyboard
    echo PANEL_BOARD_PASS
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
