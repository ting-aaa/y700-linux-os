#!/bin/bash
# Run the release IME under a private, ordinary Xfce session with kernel touch.
set -euo pipefail
if [[ ${1:-} == --guest ]]; then
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    grep -qw y700.topology_fixture=1 /proc/cmdline
    grep -zFxq linux,dummy-virt /proc/device-tree/compatible
    test "$(cat /sys/block/vda/ro)" = 1
    cd /opt/y700-topology
    tar -xf old-watcher
    [[ ! -s /etc/machine-id ]]
    dbus-uuidgen > /etc/machine-id
    ip link set lo up
    install -d -m1777 /tmp/.ICE-unix
    for deb in xdotool.deb libxdo3.deb; do dpkg-deb -x "$deb" /; done
    if [[ -f ibus.deb ]]; then
        [[ $(dpkg-query -W -f='${Version}' ibus) == 1.5.32-2 ]]
        [[ ! -e /etc/xdg/autostart/ibus.desktop && ! -L /etc/xdg/autostart/ibus.desktop ]]
        other_packages() {
            dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\t${Version}\n' |
                awk -F '\t' '$1 == "installed" && $2 != "ibus" {print}' | LC_ALL=C sort
        }
        other_packages > /run/other-before
        [[ $(wc -l </run/other-before) == 1239 ]]
        dpkg -i ./ibus.deb
        test -z "$(dpkg --audit)"
        apt-get check
        other_packages > /run/other-after
        cmp /run/other-before /run/other-after
        [[ $(dpkg-query -W -f='${Version}' ibus) == "$(dpkg-deb -f ./ibus.deb Version)" ]]
        echo CHINESE_INPUT_UPDATE other_installed_packages_unchanged=1239
    fi
    dpkg-query -W ibus ibus-gtk3 ibus-libpinyin onboard y700-input-pinyin
    install -d -m700 -o y700 -g y700 /run/chinese-input
    install -d /run/udev/rules.d
    printf '%s\n' 'SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NT36523N Capacitive Touchscreen", GROUP="y700", MODE="0640"' >/run/udev/rules.d/99-input-fixture.rules
    bash ./xorg-guest.sh
    if [[ -f ibus.deb ]]; then
        dpkg -i ./rollback.deb
        [[ $(dpkg-query -W -f='${Version}' ibus) == 1.5.32-2 ]]
        printf '%s  %s\n' e24502cba3f86af85fd183a1761eea75236414232c7211f0af75825aa519041d /usr/libexec/ibus-ui-gtk3 | sha256sum -c -
        other_packages > /run/restored
        cmp /run/other-before /run/restored
        test -z "$(dpkg --audit)"
        apt-get check
        echo CHINESE_INPUT_ROLLBACK restored=1 other_installed_packages_unchanged=1239
    fi
    exit
fi
if [[ ${1:-} == --user ]]; then
    [[ $(id -u) == 1000 ]]
    export PATH=/usr/bin:/bin CHINESE_INPUT_BUNDLE=/opt/y700-topology/app CHINESE_INPUT_TEST_DIR=/run/chinese-input
    export CHINESE_INPUT_TYPE_B=1 CHINESE_INPUT_POSITION=$(cat position) CHINESE_INPUT_START_TIMEOUT=140
    export CHINESE_INPUT_CANDIDATE=$(cat selector)
    [[ ! -f ibus.deb ]] || export CHINESE_INPUT_EXPECT_FIRST=1
    export HOME=$CHINESE_INPUT_TEST_DIR/home XDG_RUNTIME_DIR=$CHINESE_INPUT_TEST_DIR/user
    export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg
    export XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=xfce LANG=C.UTF-8 LC_ALL=C.UTF-8
    export GDK_BACKEND=x11 GTK_USE_PORTAL=0 UV_OFFLINE=1 NO_AT_BRIDGE=0
    unset DBUS_SESSION_BUS_ADDRESS SESSION_MANAGER XMODIFIERS GTK_IM_MODULE GDK_SCALE
    mkdir -m700 "$HOME" "$XDG_RUNTIME_DIR"
    xrandr --newmode ime-landscape 268.50 2560 2608 2640 2720 1600 1603 1609 1646 +HSync -VSync
    xrandr --addmode DUMMY0 ime-landscape
    xrandr --output DUMMY0 --mode ime-landscape --primary --pos 0x0 --fb 2560x1600
    xid=$(xinput list --id-only 'NT36523N Capacitive Touchscreen')
    xinput list --long "$xid" | grep -F 'Touch mode: direct'
    nodes=()
    for node in /sys/class/input/event*/device/name; do
        [[ $(cat "$node") == 'NT36523N Capacitive Touchscreen' ]] || continue
        event=${node%/device/name}
        nodes+=("/dev/input/${event##*/}")
    done
    [[ ${#nodes[@]} == 1 && -r ${nodes[0]} ]]
    cat "${nodes[0]}" >"$XDG_RUNTIME_DIR/touches" & reader=$!
    trap 'kill "$reader" 2>/dev/null || :; wait "$reader" 2>/dev/null || :' EXIT
    cd "$HOME"
    rc=0
    dbus-run-session -- bash -ec '
        dbus-update-activation-environment DISPLAY XAUTHORITY HOME XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP
        /etc/X11/Xsession "$CHINESE_INPUT_BUNDLE/desktop.sh"' || rc=$?
    cat "$CHINESE_INPUT_TEST_DIR/result.log" || :
    if (( rc )); then tail -n 60 "$HOME/.xsession-errors" "$CHINESE_INPUT_TEST_DIR/xfce.log" || :; exit "$rc"; fi
    "$CHINESE_INPUT_BUNDLE/uv" run --offline --no-project --python /usr/bin/python3 python - "$XDG_RUNTIME_DIR/touches" <<'PY'
from pathlib import Path
import struct
import sys
tracking = [v for _, _, typ, code, v in struct.iter_unpack("@llHHi", Path(sys.argv[1]).read_bytes())
            if (typ, code) == (3, 0x39)]
completed = Path("/run/topology/input.log").read_text().splitlines().count("DONE")
assert completed >= 19 and len(tracking) == 2 * completed
assert len(set(tracking[::2])) == len(tracking)//2 and min(tracking[::2]) >= 0 and set(tracking[1::2]) == {-1}
print(f"CHINESE_INPUT_TYPE_B evdev_begin={len(tracking)//2} evdev_end={len(tracking)//2}")
PY
    echo TOPOLOGY_PASS
    exit
fi
if [[ ( $# != 7 && $# != 8 ) || ! $7 =~ ^(upper|lower)$ ]]; then
    echo 'Usage: run-touch.sh DEV1212_ROOT KERNEL_EFI ARM64_BUSYBOX DUMMY.deb ARM64_UV X11_DEB_DIR upper|lower [FIXED_IBUS_ARM64.deb]' >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
common=$here/../display-touch-topology
root=$(realpath -e "$1")
printf '%s  %s\n' 5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3 "$root" \
    0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60 "$2" | sha256sum -c -
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-chinese-touch.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
qemu-img create -q -f qcow2 -F raw -b "$root" "$work/disk.qcow2"
mkdir -p "$work"/{runner,touch-gestures,payload/app}
sed -e 's/timeout -k 4 150 /timeout -k 4 420 /' -e 's/-smp 2 -m 640 /-smp 3 -m 1536 /' \
    "$common/run-qemu.sh" >"$work/runner/run-qemu.sh"
cp "$common/guest.sh" "$work/payload/xorg-guest.sh"
cp "$0" "$work/payload/run-touch.sh"
cp "$here/"{probe.py,desktop.sh,gtk-target.py} "$work/payload/app/"
chmod +x "$work/payload/app/desktop.sh"
printf '%s\n' "$7" >"$work/payload/position"
selector=${CHINESE_INPUT_CANDIDATE:-number}
[[ $selector == number || $selector == word ]]
printf '%s\n' "$selector" >"$work/payload/selector"
install -m755 "$5" "$work/payload/app/uv"
if [[ $# == 8 ]]; then
    [[ $(dpkg-deb -f "$8" Package) == ibus && $(dpkg-deb -f "$8" Architecture) == arm64 ]]
    sha256sum "$8"
    install -m644 "$8" "$work/payload/ibus.deb"
    stock=$(dirname "$8")/ibus_1.5.32-2_arm64.deb
    printf '%s  %s\n' 5c0ce52da04c5f74baba3d7d4491e6e5eb9b674a81dadcf0fd9b58b254664ab6 "$stock" | sha256sum -c -
    install -m644 "$stock" "$work/payload/rollback.deb"
fi
for name in xdotool libxdo3; do cp "$6"/"$name"_*.deb "$work/payload/$name.deb"; done
printf '#!/bin/bash\ncd /opt/y700-topology && tar -xf old-watcher ./run-touch.sh && exec bash ./run-touch.sh --guest\n' >"$work/runner/guest.sh"
printf '#!/bin/bash\nexec bash ./run-touch.sh --user\n' >"$work/runner/cases.sh"
printf '#include "%s"\n' "$here/../touch-gestures/evdev-touch.c" >"$work/touch-gestures/evdev-touch.c"
tar -C "$work/payload" --mtime=@0 -cf "$work/test.tar" .
bash "$work/runner/run-qemu.sh" "$work/disk.qcow2" "$2" "$3" "$4" "$work/test.tar"
