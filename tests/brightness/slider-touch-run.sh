#!/bin/bash
# Run on a Linux PC. Requires the inputs to tests/display-touch-topology/run-qemu.sh
# plus native uv and the two platform debs; all system changes are in guest RAM.
set -euo pipefail
if [[ ${1:-} == --guest ]]; then
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    grep -qw y700.topology_fixture=1 /proc/cmdline
    grep -zFxq linux,dummy-virt /proc/device-tree/compatible
    test "$(cat /sys/block/vda/ro)" = 1
    cd /opt/y700-topology
    # The parent fixture transports an opaque fifth input at this path.
    tar -xf old-watcher
    [[ ! -s /etc/machine-id ]]
    dbus-uuidgen > /etc/machine-id
    dpkg -i gpu.deb
    dpkg -i slider.deb
    if [[ -f update.deb ]]; then dpkg -i update.deb; fi
    [[ $(dpkg-query -W -f='${Version}' y700-platform) == "$(cat expected-version)" ]]
    sha256sum -c installed.sha256
    install -d -m700 -o y700 -g y700 /run/slider-case
    install -d -o y700 -g y700 /run/slider-case/sys{,/class,/class/backlight}
    mount --bind /run/slider-case/sys/class/backlight /sys/class/backlight
    install -d /run/udev/rules.d
    printf '%s\n' 'SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NT36523N Capacitive Touchscreen", GROUP="y700", MODE="0640"' > /run/udev/rules.d/99-slider-touch.rules
    exec bash ./xorg-guest.sh
fi
if [[ ${1:-} == --user ]]; then
    [[ "$(id -u)" == 1000 ]]
    export PATH=/usr/bin:/bin LC_ALL=C.UTF-8 LANG=C.UTF-8 LANGUAGE=en
    export XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_ID=c42 GDK_SCALE=2 GDK_BACKEND=x11 NO_AT_BRIDGE=0
    export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg
    /usr/bin/xrandr --output DUMMY0 --mode portrait --primary --pos 0x0 --fb 1600x2560
    dbus-run-session -- bash -ec '
        dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR GDK_SCALE NO_AT_BRIDGE
        xfwm4 --compositor=off >"$XDG_RUNTIME_DIR/wm.log" 2>&1 &
        for i in {1..130}; do xprop -root _NET_SUPPORTING_WM_CHECK | grep -q "window id" && break; sleep .4; done
        if ! xprop -root _NET_SUPPORTING_WM_CHECK | grep -q "window id"; then
            cat "$XDG_RUNTIME_DIR/wm.log" >&2
            xprop -root _NET_SUPPORTING_WM_CHECK >&2
            exit 1
        fi
        export DBUS_SYSTEM_BUS_ADDRESS
        DBUS_SYSTEM_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address)
        exec ./uv run --offline --no-project --python /usr/bin/python3 python -B ./slider-touch-ui.py'
    # Expected terminal marker for the shared QEMU runner.
    echo TOPOLOGY_PASS
    exit
fi
if [[ $# != 7 && $# != 8 ]]; then
    echo 'Usage: slider-touch-run.sh DEV12.11.ext4 KERNEL ARM64_BUSYBOX DUMMY.deb ARM64_UV GPU1.deb GPU1.1.deb [GPU1.2.deb]' >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
common=$here/../display-touch-topology
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-slider-touch.XXXXXXXX")
trap 'rm -r -- "$work"' EXIT
root=$(realpath -e "$1")
sha256sum -c - <<HASH
33ce23e8edac1d9c445c6b360a6355a189a151804352b032efe51320287d17a3  $root
b103d0fcd65a08cadb592fbdc69c8c483a7727ef212c15e464208f5c30a1a625  $2
2b6dd72510cc0a63744127cd68149ec28f4241a6acca587263ddcc8e3357e97e  $6
aa39b033a89c8e295df4ba29a4a4fed26c91e6d4b9928fcf2e5d9cabde74d535  $7
HASH
qemu-img create -q -f qcow2 -F raw -b "$root" "$work/disk.qcow2"
mkdir -p "$work"/{runner,touch-gestures,payload/ambient-backlight}
cp "$common/run-qemu.sh" "$work/runner/"
cp "$common/guest.sh" "$work/payload/xorg-guest.sh"
cp "$0" "$work/payload/slider-touch-run.sh"
cp "$here/"{slider-touch-ui.py,probe.py} "$work/payload/"
cp "$here/../ambient-backlight/check.py" "$work/payload/ambient-backlight/"
cp "$here/../rotation-session.py" "$work/payload/"
install -m755 "$5" "$work/payload/uv"
install -m644 "$6" "$work/payload/gpu.deb"
install -m644 "$7" "$work/payload/slider.deb"
version='0.1.0~dev12.8+gpu1.1'
executable=e5df07598109b52c82824ec36f0b42ee3959edd752426821a195665f2e57534c
if [[ $# == 8 ]]; then
    version='0.1.0~dev12.8+gpu1.2'
    printf '%s  %s\n' 479c59b518f42e035f9101feb5947ba972df32b1a5646f62b459bc13b5357518 "$8" | sha256sum -c -
    executable=c75de4f42fbca74868fa3bce398f0d1bb8b86ce4703e6fe0d8e63a2c421b9799
    install -m644 "$8" "$work/payload/update.deb"
fi
printf '%s\n' "$version" > "$work/payload/expected-version"
printf '%s  %s\n' "$executable" /usr/libexec/y700-tablet-brightness > "$work/payload/installed.sha256"
printf '#!/bin/bash\ncd /opt/y700-topology && tar -xf old-watcher ./slider-touch-run.sh && exec bash ./slider-touch-run.sh --guest\n' >"$work/runner/guest.sh"
printf '#!/bin/bash\nexec bash ./slider-touch-run.sh --user\n' >"$work/runner/cases.sh"
# Use the ordinary topology runner's single ARM64 input-device compilation.
printf '#include "%s"\n' "$here/slider-touch-input.c" >"$work/touch-gestures/evdev-touch.c"
tar -C "$work/payload" --mtime=@0 -cf "$work/payload.tar" .
bash "$work/runner/run-qemu.sh" "$work/disk.qcow2" "$2" "$3" "$4" "$work/payload.tar"
