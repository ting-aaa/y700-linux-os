#!/bin/bash
# Run only on the independent ARM64 QEMU desktop. Its lower root is read-only.
set -euo pipefail
if [[ ${1:-} == --guest ]]; then
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    grep -qw y700.topology_fixture=1 /proc/cmdline
    grep -zFxq linux,dummy-virt /proc/device-tree/compatible
    cd /opt/y700-topology
    tar -xf old-watcher
    dpkg -i quick.deb
    test ! -s /etc/machine-id
    dbus-uuidgen >/etc/machine-id
    bash ./xorg-guest.sh
    dpkg --purge y700-quick-settings
    [[ ! -e /usr/bin/y700-quick-settings && ! -e /etc/xdg/autostart/y700-quick-settings.desktop ]]
    echo QUICK_PACKAGE_rollback=pass
    exit
fi
if [[ ${1:-} == --user ]]; then
    cd /opt/y700-topology
    export PATH=/usr/bin:/bin LC_ALL=C.UTF-8 LANGUAGE=en XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_ID=c42
    export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg
    /usr/bin/xrandr --output DUMMY0 --mode portrait --primary --pos 0x0 --fb 1600x2560
    export HOME=$XDG_RUNTIME_DIR/home XDG_CONFIG_HOME=$XDG_RUNTIME_DIR/home/.config
    export GDK_SCALE=2 GDK_DPI_SCALE=1 GDK_BACKEND=x11 NO_AT_BRIDGE=1 GTK_USE_PORTAL=0 GIO_USE_VFS=local
    mkdir -p "$XDG_CONFIG_HOME/xfce4/xfconf/xfce-perchannel-xml"
    cp xfce4-panel.xml "$XDG_CONFIG_HOME/xfce4/xfconf/xfce-perchannel-xml/"
    dbus-run-session -- bash -ec '
        dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR GDK_SCALE
        xfwm4 --sm-client-disable --vblank=off --compositor=off >"$XDG_RUNTIME_DIR/wm.log" 2>&1 &
        xfce4-panel --disable-wm-check >"$XDG_RUNTIME_DIR/panel.log" 2>&1 &
        export DBUS_SYSTEM_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address)
        export PATH="/opt/y700-topology/fixture-bin:$PATH"
        printf "20\n" >"$XDG_RUNTIME_DIR/qa-volume"
        printf "0\n" >"$XDG_RUNTIME_DIR/qa-mute"
        ./uv run --offline --no-project --python /usr/bin/python3 python -B guest.py
    '
    echo TOPOLOGY_PASS
    exit
fi
[[ $# == 6 ]] || { echo 'Usage: run.sh dev12.12-root.ext4 kernel.efi arm64-busybox dummy-driver.deb arm64-uv quick-settings.deb' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
common=$here/../display-touch-topology
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
mkdir -p "$work"/{runner,touch-gestures,payload}
sed -e 's/timeout -k 4 150 /timeout -k 4 300 /' -e 's/-smp 2 -m 640 /-smp 3 -m 1500 /' \
    -e 's/format=qcow2/format=raw/' "$common/run-qemu.sh" >"$work/runner/run-qemu.sh"
cp "$common/guest.sh" "$work/payload/xorg-guest.sh"
cp "$here/../wifi-chooser/xfce4-panel.xml" "$here/guest.py" "$here/run.sh" "$work/payload/"
install -m755 "$5" "$work/payload/uv"
install -Dm755 "$here/fixture-wpctl" "$work/payload/fixture-bin/wpctl"
cp "$6" "$work/payload/quick.deb"
printf '#!/bin/bash\ncd /opt/y700-topology && tar -xf old-watcher ./run.sh && exec bash ./run.sh --guest\n' >"$work/runner/guest.sh"
printf '#!/bin/bash\nexec bash ./run.sh --user\n' >"$work/runner/cases.sh"
printf '#include "%s"\n' "$here/../brightness/slider-touch-input.c" >"$work/touch-gestures/evdev-touch.c"
tar -C "$work/payload" --mtime=@0 -cf "$work/payload.tar" .
bash "$work/runner/run-qemu.sh" "$1" "$2" "$3" "$4" "$work/payload.tar"
