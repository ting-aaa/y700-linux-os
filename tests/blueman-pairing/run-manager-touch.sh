#!/bin/bash
# Run the same Manager interaction using the existing Type-B/libinput guest.
set -euo pipefail
if [[ ${1:-} == --guest ]]; then
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    grep -qw y700.topology_fixture=1 /proc/cmdline
    grep -zFxq linux,dummy-virt /proc/device-tree/compatible
    [[ $(cat /sys/block/vda/ro) == 1 ]]
    [[ -z $(ls -A /sys/class/rfkill) && -z $(ls -A /sys/class/bluetooth) ]]
    # The isolated guest has no logind seat to give Blueman its normal
    # read access. There are no radio devices behind this guest rfkill node.
    [[ -c /dev/rfkill ]]
    chown root:y700 /dev/rfkill
    chmod 0640 /dev/rfkill
    cd /opt/y700-topology
    tar -xf old-watcher
    [[ ! -s /etc/machine-id ]]
    dbus-uuidgen >/etc/machine-id
    for deb in dbusmock.deb xdotool.deb libxdo3.deb; do dpkg-deb -x "$deb" /; done
    dpkg -i candidate.deb
    install -d -m700 -o y700 -g y700 /run/blueman-pairing
    install -d /run/udev/rules.d
    printf '%s\n' 'SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NT36523N Capacitive Touchscreen", GROUP="y700", MODE="0640"' > /run/udev/rules.d/99-manager-touch.rules
    ln -s /opt/y700-topology/app /opt/blueman-pairing
    exec bash ./xorg-guest.sh
fi
if [[ ${1:-} == --user ]]; then
    trap 'echo "MANAGER_TOUCH_FIXTURE_ERROR line=$LINENO"' ERR
    [[ $(id -u) == 1000 ]]
    /usr/bin/xrandr --output DUMMY0 --mode portrait --primary --pos 0x0 --fb 1600x2560
    xid=$(xinput list --id-only 'NT36523N Capacitive Touchscreen')
    [[ $xid =~ ^[0-9]+$ ]]
    xinput list --long "$xid" | grep -F 'Touch mode: direct'
    nodes=()
    for node in /sys/class/input/event*/device/name; do
        [[ $(cat "$node") == 'NT36523N Capacitive Touchscreen' ]] || continue
        event=${node%/device/name}
        nodes+=("/dev/input/${event##*/}")
    done
    [[ ${#nodes[@]} == 1 && -r ${nodes[0]} ]]
    # An evdev reader observes without taking the XI2 touch sequence from GTK.
    cat "${nodes[0]}" >"$XDG_RUNTIME_DIR/touches" & watch=$!
    trap 'kill "$watch" 2>/dev/null || :; wait "$watch" 2>/dev/null || :' EXIT
    BLUEMAN_TOUCH_ENTRY=1 BLUEMAN_TYPE_B=1 bash /opt/blueman-pairing/run-session.sh 2.4.4-1+y7003
    kill "$watch"
    wait "$watch" 2>/dev/null || :
    trap - EXIT
    /opt/blueman-pairing/uv run --offline --no-project --python /usr/bin/python3 python - "$XDG_RUNTIME_DIR/touches" <<'PY'
from pathlib import Path
import struct
import sys

records = struct.iter_unpack("@llHHi", Path(sys.argv[1]).read_bytes())
tracking = [value for _, _, kind, code, value in records if (kind, code) == (3, 0x39)]
assert len(tracking) == 20 and len(set(tracking[::2])) == 10
assert min(tracking[::2]) >= 0 and tracking[1::2] == [-1] * 10
print("MANAGER_TYPE_B libinput=1 touch_begin=10 touch_end=10")
PY
    echo TOPOLOGY_PASS
    exit
fi
if [[ $# != 8 || ! $8 =~ ^(en|zh)$ ]]; then
    echo 'Usage: run-manager-touch.sh DEV1212_ROOT KERNEL_EFI ARM64_BUSYBOX DUMMY.deb ARM64_UV X11_DEB_DIR DBUSMOCK.deb en|zh; set BLUEMAN_MANAGER_DEB to y7003' >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
common=$here/../display-touch-topology
root=$(realpath -e "$1")
pkg=$(realpath -e "${BLUEMAN_MANAGER_DEB:?ARM64 y7003 package}")
printf '%s  %s\n' \
    5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3 "$root" \
    0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60 "$2" \
    f0b06bc9c290ce3d7b6ee78dbb1ca41fee5a2143a6af03c63cfeb80059c2597b "$pkg" | sha256sum --strict -c -
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-blueman-touch.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
qemu-img create -q -f qcow2 -F raw -b "$root" "$work/disk.qcow2"
mkdir -p "$work"/{runner,touch-gestures,payload/app}
# The full Manager, accessibility stack and applet need more memory and
# startup time than the small topology check this runner normally boots.
sed -e 's/timeout -k 4 150 /timeout -k 4 400 /' -e 's/-smp 2 -m 640 /-smp 3 -m 1536 /' \
    "$common/run-qemu.sh" >"$work/runner/run-qemu.sh"
cp "$common/guest.sh" "$work/payload/xorg-guest.sh"
cp "$0" "$work/payload/run-manager-touch.sh"
cp "$here/"{manager.py,probe.py,run-session.sh} "$work/payload/app/"
printf '%s\n' portrait >"$work/payload/app/orientation"
printf '%s\n' "$8" >"$work/payload/app/language"
install -m755 "$5" "$work/payload/app/uv"
cp "$pkg" "$work/payload/candidate.deb"
cp "$7" "$work/payload/dbusmock.deb"
for name in xdotool libxdo3; do cp "$6"/"$name"_*.deb "$work/payload/$name.deb"; done
printf '#!/bin/bash\ncd /opt/y700-topology && tar -xf old-watcher ./run-manager-touch.sh && exec bash ./run-manager-touch.sh --guest\n' >"$work/runner/guest.sh"
printf '#!/bin/bash\nexec bash ./run-manager-touch.sh --user\n' >"$work/runner/cases.sh"
printf '#include "%s"\n' "$here/../brightness/slider-touch-input.c" >"$work/touch-gestures/evdev-touch.c"
tar -C "$work/payload" --mtime=@0 -cf "$work/case.tar" .
bash "$work/runner/run-qemu.sh" "$work/disk.qcow2" "$2" "$3" "$4" "$work/case.tar"
