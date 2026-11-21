#!/bin/bash
# Windowed Chromium on a private nested display, with a read-only greeter guard.
set -euo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
trap 'echo "WINDOW_FAILED line=$LINENO" >&2' ERR

if [[ ${1:-} == --client ]]; then
    s=$2 mode=$3 policy=$4 frames=$5
    [[ $EUID == 0 && -S $s/private/host.sock ]]
    umount /tmp/.X11-unix/X0
    mount -t tmpfs -o mode=000,nodev,nosuid tmpfs "$s/private"
    for protected in /home /run/user /run/lightdm /run/dbus /dev/input; do
        [[ ! -d $protected ]] || mount -t tmpfs -o mode=755,nodev,nosuid tmpfs "$protected"
    done
    install -d -m700 -o 47318 -g 47318 /home/window /home/window/runtime
    [[ ! -S /tmp/.X11-unix/X0 && ! -S "$s/private/host.sock" && ! -e /run/lightdm/root/:0 ]]
    render=$(getent group render | cut -d: -f3)
    cd /home/window
    exec setpriv --reuid=47318 --regid=47318 --groups="$render" env -i PATH="$PATH" LC_ALL=C.UTF-8 \
        HOME=/home/window XDG_CONFIG_HOME=/home/window/.config XDG_RUNTIME_DIR=/home/window/runtime \
        DISPLAY=:77 XAUTHORITY="$s/client.auth" GSETTINGS_BACKEND=keyfile \
        "$s/uv" run --offline --no-project --python /usr/bin/python3 python -B "$s/browser.py" "$s/state" "$s" "$mode" "$policy" "$frames"
fi

if [[ ${1:-} == --worker ]]; then
    s=$2 mode=$3 xephyr=$4 lib=$5 hostauth=$6 policy=$7 frames=$8
    [[ $EUID == 0 && $$ == 1 ]]
    ip link set lo up
    [[ $(ip -o link show up | wc -l) == 1 ]]
    mkdir -m700 "$s/private"
    mount -t tmpfs -o mode=0711,nodev,nosuid tmpfs "$s/private"
    install -o 47317 -g 47317 -m400 "$hostauth" "$s/private/host.auth"
    touch "$s/private/host.sock"
    mount --bind /tmp/.X11-unix/X0 "$s/private/host.sock"
    mount -t tmpfs -o mode=1777,nodev,nosuid tmpfs /tmp
    install -d -m1777 /tmp/.X11-unix
    touch /tmp/.X11-unix/X0
    mount --bind "$s/private/host.sock" /tmp/.X11-unix/X0
    install -d -m755 "$s/state"
    install -d -m700 -o 47318 -g 47318 "$s/state/client"
    # A wildcard family permits the same cookie on the filesystem socket inside the client namespace.
    { printf '\377\377\000\000\000\00277\000\022MIT-MAGIC-COOKIE-1\000\020'; head -c16 /dev/urandom; } > "$s/private/nested.auth"
    install -m400 -o 47318 -g 47318 "$s/private/nested.auth" "$s/client.auth"
    chown 47317:47317 "$s/private/nested.auth"
    chmod 400 "$s/private/nested.auth"
    # Avoid using the owner's account, and give the ephemeral UID a name for Chromium's libraries.
    cp /etc/passwd "$s/passwd"
    printf 'window:x:47318:47318:Chromium fixture:/home/window:/usr/sbin/nologin\n' >> "$s/passwd"
    chmod 644 "$s/passwd"
    mount --bind "$s/passwd" /etc/passwd
    export DISPLAY=:0 XAUTHORITY="$s/private/host.auth" GDK_BACKEND=x11 GDK_SCALE=1 NO_AT_BRIDGE=1
    HOME="$s" UV_CACHE_DIR="$s/observer-cache" "$s/uv" run --offline --no-project --python /usr/bin/python3 \
        python -B "$s/window.py" "$s/state" &
    presenter=$!
    for _ in {1..100}; do [[ ! -s $s/state/parent ]] || break; kill -0 "$presenter"; sleep .1; done
    parent=$(cat "$s/state/parent")
    [[ $parent =~ ^[0-9]+$ ]]
    setpriv --reuid=47317 --regid=47317 --clear-groups env -i PATH="$PATH" LC_ALL=C HOME=/tmp \
        LD_LIBRARY_PATH="$lib" DISPLAY=:0 XAUTHORITY="$s/private/host.auth" "$xephyr" :77 \
        -parent "$parent" -no-host-grab -noreset -nolisten tcp -auth "$s/private/nested.auth" >"$s/xephyr.log" 2>&1 &
    nested=$!
    for _ in {1..100}; do
        if DISPLAY=:77 XAUTHORITY="$s/private/nested.auth" xdpyinfo >/dev/null 2>&1; then break; fi
        kill -0 "$nested" || { tail -10 "$s/xephyr.log"; exit 1; }
        sleep .1
    done
    DISPLAY=:77 XAUTHORITY="$s/private/nested.auth" xdpyinfo | grep 'dimensions:' | grep -q '640x480'
    touch "$s/state/nested-ready"
    for _ in {1..100}; do [[ ! -f $s/state/pixmap-ready ]] || break; kill -0 "$presenter"; sleep .1; done
    [[ -f $s/state/pixmap-ready ]]
    unshare --mount --propagation private /bin/bash "$s/run.sh" --client "$s" "$mode" "$policy" "$frames" &
    client=$!
    seccomp=0 bypass=0 disabled=0 flags_ok=0 retired=0
    while kill -0 "$client" 2>/dev/null; do
        kill -0 "$presenter" "$nested"
        for proc in /proc/[0-9]*; do
            [[ $(readlink "$proc/exe" || :) == /usr/lib/chromium/chromium ]] || continue
            args=$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null) || continue
            case " $args" in *' --no-sandbox '*|*' --disable-gpu-sandbox '*|*' --disable-seccomp-filter-sandbox '*) bypass=1;; esac
            case " $args" in *' --disable-gpu '*) disabled=1;; esac
            if [[ " $args" != *' --type='* && " $args" == *' --ozone-platform=x11 '* ]]; then
                if [[ $policy == hardware && " $args" == *' --use-gl=angle '* && " $args" == *' --use-angle=vulkan '* ]]; then flags_ok=1; fi
                if [[ $policy == software && " $args" == *' --disable-gpu '* && " $args" != *' --use-angle=vulkan '* ]]; then flags_ok=1; fi
            fi
            if [[ " $args" == *' --type=renderer '* ]] && awk '$1=="Seccomp:" && $2==2 {s=1}
                $1=="NoNewPrivs:" && $2==1 {n=1} END{exit !(s&&n)}' "$proc/status" 2>/dev/null; then seccomp=1; fi
            if [[ " $args" == *' --type=gpu-process '* && $retired == 0 ]]; then
                for info in "$proc"/fdinfo/*; do
                    if awk '$1=="drm-driver:" && $2=="msm" {m=1}
                        ($1=="drm-engine-gpu:" || $1=="drm-cycles-gpu:") && $2+0>0 {r=1}
                        END{exit !(m&&r)}' "$info" 2>/dev/null; then retired=1; break; fi
                done
            fi
        done
        sleep .12
    done
    wait "$client"
    touch "$s/state/done"
    wait "$presenter"
    printf 'WINDOW_PROCESSES flags_from_launcher=%d disable_gpu=%d seccomp=%d bypass=%d msm_retired=%d\n' \
        "$flags_ok" "$disabled" "$seccomp" "$bypass" "$retired"
    [[ $flags_ok == 1 && $seccomp == 1 && $bypass == 0 && -f $s/state/presented ]]
    if [[ $policy == software ]]; then [[ $disabled == 1 && $retired == 0 ]]
    elif [[ $mode == physical ]]; then [[ $disabled == 0 && $retired == 1 ]]
    else [[ $disabled == 0 && $retired == 0 ]]
    fi
    echo "WINDOW_PASS mode=$mode policy=$policy frames=$frames"
    exit
fi

[[ $EUID == 0 && $# -le 1 ]]
policy=${Y700_WINDOW_POLICY:-hardware}
frames=${Y700_WINDOW_FRAMES:-60}
[[ $policy == hardware || $policy == software ]]
[[ $frames =~ ^[1-9][0-9]{1,3}$ ]] && (( frames >= 60 && frames <= 1800 && frames % 2 == 0 )) || exit 2
mode=physical
if [[ ${1:-} == --vm-control ]]; then
    grep -azFxq linux,dummy-virt /proc/device-tree/compatible
    mode=vm
else
    [[ $# == 0 ]]
    grep -azFxq lenovo,asphalt /proc/device-tree/compatible
fi
grep -Fxq IMAGE_VERSION=dev12.11 /etc/os-release
exec 9>/run/lock/y700-chromium-window.lock
flock -n 9 || { echo 'Another window fixture owns the greeter' >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
stage=$(mktemp -d /run/y700-window.XXXXXXXX)
worker=
woke=
cleanup() {
    if [[ -n $worker ]]; then kill "$worker" 2>/dev/null || :; wait "$worker" 2>/dev/null || :; fi
    if [[ -n $woke ]] && guard; then
        now=$(last_input) || now=0
        if (( now >= last_event - 250 && now <= last_event + 250 )); then
            DISPLAY=:0 XAUTHORITY="$auth" xset dpms force "${woke,,}" &&
                echo "WINDOW_DPMS restored=$woke" || :
        else
            echo WINDOW_DPMS greeter_input_changed=1
        fi
    fi
    rm -r -- "$stage"
}
trap cleanup EXIT
install -m644 "$here"/{run.sh,window.py,browser.py,software-control.js} "$stage/"
base=$here
[[ -f $base/chromium-gpu.py ]] || base=$here/..
install -m644 "$base"/chromium-gpu.{py,html} "$stage/"
install -m755 "${UV_BIN:-$(command -v uv)}" "$stage/uv"
chmod 711 "$stage"
auth=/run/lightdm/root/:0
if [[ $mode == vm ]]; then auth=${VM_XAUTHORITY:?}; fi
[[ -f $auth && ! -L $auth ]]
for uid in 47317 47318; do
    if getent passwd "$uid" >/dev/null || pgrep -u "$uid" >/dev/null; then echo "Fixture UID already in use" >&2; exit 1; fi
done
guard() {
    local session type
    [[ $(loginctl show-seat seat0 -p ActiveSession --value) == "$sid" &&
       $(loginctl show-session "$sid" -p Class --value) == greeter &&
       $(loginctl show-session "$sid" -p Type --value) == x11 ]] || return 1
    for session in $(loginctl show-seat seat0 -p Sessions --value); do
        if [[ $session != "$sid" ]]; then
            type=$(loginctl show-session "$session" -p Type --value)
            [[ $type != x11 && $type != wayland ]] || return 1
        fi
    done
}
dpms() { DISPLAY=:0 XAUTHORITY="$auth" xset q | awk '/Monitor is/ {print $3}'; }
last_input() {
    DISPLAY=:0 XAUTHORITY="$auth" HOME="$stage" UV_CACHE_DIR="$stage/observer-cache" "$stage/uv" run \
        --offline --no-project --python /usr/bin/python3 python -B "$stage/window.py" --last-input
}
panel_lit() {
    [[ $(dpms) == On ]] || return 1
    DISPLAY=:0 XAUTHORITY="$auth" xrandr --current | awk '/ connected/ {outputs++; if($1=="DSI-1" && /[0-9]+x[0-9]+\+0\+0/) panel=1}
        END {exit !(panel && outputs==1)}' || return 1
    local panels=(/sys/class/backlight/*)
    [[ ${#panels[@]} == 1 && $(cat "${panels[0]}/bl_power") == 0 &&
       $(cat "${panels[0]}/actual_brightness") -gt 0 ]]
}
if [[ $mode == physical ]]; then
    sid=$(loginctl show-seat seat0 -p ActiveSession --value)
    guard
    DISPLAY=:0 XAUTHORITY="$auth" xrandr --current | awk '/ connected/ {outputs++; if($1=="DSI-1" && /[0-9]+x[0-9]+\+0\+0/) panel=1}
        END {exit !(panel && outputs==1)}'
    old=$(dpms)
    case $old in
        On) ;;
        Off|Suspend|Standby)
            guard
            last_event=$(last_input)
            DISPLAY=:0 XAUTHORITY="$auth" xset dpms force on
            woke=$old
            last_event=$(last_input)
            echo "WINDOW_DPMS previous=$old request=on"
            ;;
        *) echo 'Cannot read Xorg DPMS state' >&2; exit 1;;
    esac
    for _ in {1..25}; do if panel_lit; then break; fi; sleep .2; done
    panel_lit
fi
xephyr=$(realpath -e "${XEPHYR_BIN:-/run/y700-x11-deps/usr/bin/Xephyr}")
lib=${XEPHYR_LIB:-/run/y700-x11-deps/usr/lib/aarch64-linux-gnu}
unshare --net --pid --ipc --fork --kill-child --mount-proc --propagation private \
    /bin/bash "$stage/run.sh" --worker "$stage" "$mode" "$xephyr" "$lib" "$auth" "$policy" "$frames" &
worker=$!
deadline=$((SECONDS + 180))
until ! kill -0 "$worker" 2>/dev/null; do
    if [[ $mode == physical ]]; then guard || { echo WINDOW_ABORT_SEAT_CHANGE >&2; exit 1; }; fi
    if [[ -f $stage/state/presented && ! -e $stage/state/display-checked ]]; then
        if [[ $mode == physical ]]; then
            panel_lit
            echo 'WINDOW_PANEL connector=DSI-1 dpms=On bl_power=0 brightness_positive=1 seat=greeter'
        fi
        touch "$stage/state/display-checked"
    fi
    (( SECONDS < deadline )) || { echo WINDOW_ABORT_DEADLINE >&2; exit 1; }
    sleep .3
done
wait "$worker"
worker=
