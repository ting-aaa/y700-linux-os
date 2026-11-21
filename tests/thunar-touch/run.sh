#!/bin/bash
set -euo pipefail
if [[ ${1:-} == --guest ]]; then
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    cd /opt/y700-topology
    tar -xf old-watcher
    if [[ -f update.deb ]]; then
        [[ $(dpkg-deb -f update.deb Package) == thunar ]]
        [[ $(dpkg-deb -f update.deb Architecture) == arm64 ]]
        dpkg -i update.deb
        sha256sum update.deb
    fi
    dpkg-query -W -f='THUNAR_PACKAGE ${binary:Package} ${Version}\n' thunar
    sha256sum /usr/bin/thunar
    test ! -s /etc/machine-id
    dbus-uuidgen >/etc/machine-id
    exec bash xorg-guest.sh
fi
if [[ ${1:-} == --user ]]; then
    cd /opt/y700-topology
    export PATH=/usr/bin:/bin LC_ALL=C.UTF-8 LANG=C.UTF-8 LANGUAGE=en
    export HOME="$XDG_RUNTIME_DIR/home" XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=xfce
    export GIO_USE_VFS=local GTK_USE_PORTAL=0
    if [[ ! -f update.deb ]]; then export Y700_THUNAR_STOCK=1; fi
    export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg GDK_SCALE=2 GDK_BACKEND=x11 NO_AT_BRIDGE=0
    mkdir -p "$HOME"
    xrandr --output DUMMY0 --mode portrait --primary --pos 0x0 --fb 1600x2560
    dbus-run-session -- bash -ec '
        dbus-update-activation-environment DISPLAY XAUTHORITY HOME XDG_RUNTIME_DIR GDK_SCALE NO_AT_BRIDGE XDG_CONFIG_DIRS
        xfwm4 --sm-client-disable --vblank=off --compositor=off >"$XDG_RUNTIME_DIR/wm.log" 2>&1 &
        for _ in {1..100}; do xprop -root _NET_SUPPORTING_WM_CHECK | grep -q "window id" && break; sleep .15; done
        onboard --startup-delay=2.0 >"$XDG_RUNTIME_DIR/onboard.log" 2>&1 &
        keyboard_pid=$!
        ./uv run --offline --no-project --python /usr/bin/python3 python -B exercise.py
        if [[ -f update.deb ]]; then
            kill "$keyboard_pid"
            wait "$keyboard_pid" || :
            for scale in 1 2; do
                GDK_SCALE=$scale ./uv run --offline --no-project --python /usr/bin/python3 python -B mouse.py
            done
        fi'
    echo TOPOLOGY_PASS
    exit
fi
[[ $# == 5 ]] || { echo 'Usage: run.sh ROOT.ext4 KERNEL ARM64_BUSYBOX ARM64_DUMMY.deb ARM64_UV' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
common=$here/../display-touch-topology
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-thunar-qa.XXXXXXXX")
trap 'rm -r -- "$work"' EXIT
mkdir -p "$work"/{runner,touch-gestures,payload}
sed -e 's/timeout -k 4 150 /timeout -k 4 300 /' -e 's/-smp 2 -m 640 /-smp 3 -m 1500 /' \
    -e 's/format=qcow2/format=raw/' "$common/run-qemu.sh" >"$work/runner/run-qemu.sh"
cp "$common/guest.sh" "$work/payload/xorg-guest.sh"
cp "$here/"{run.sh,exercise.py,mouse.py} "$work/payload/"
cp "$here/../file-trial-positive/desktop-actions/keyboard.py" "$work/payload/"
if [[ -n ${Y700_THUNAR_DEB:-} ]]; then cp "$Y700_THUNAR_DEB" "$work/payload/update.deb"; fi
install -m755 "$5" "$work/payload/uv"
cp "$here/../touch-gestures/evdev-touch.c" "$work/touch-gestures/"
printf '#!/bin/bash\ncd /opt/y700-topology && tar -xf old-watcher ./run.sh && exec bash ./run.sh --guest\n' >"$work/runner/guest.sh"
printf '#!/bin/bash\nexec bash ./run.sh --user\n' >"$work/runner/cases.sh"
tar -C "$work/payload" --mtime=@0 -cf "$work/payload.tar" .
bash "$work/runner/run-qemu.sh" "$1" "$2" "$3" "$4" "$work/payload.tar"
