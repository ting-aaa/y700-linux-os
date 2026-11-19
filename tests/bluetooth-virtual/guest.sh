#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
grep -qw 'y700.virtual_hid=1' /proc/cmdline
grep -zFxq 'linux,dummy-virt' /proc/device-tree/compatible
[[ $(uname -m) == aarch64 && -z $(ls -A /sys/class/bluetooth 2>/dev/null) ]]
cd /opt/y700-virtual-hid
mkdir -p /var/lib/bluetooth /run/dbus /dev/shm
mount -t tmpfs -o mode=700 tmpfs /var/lib/bluetooth
mount -t tmpfs -o mode=1777 tmpfs /dev/shm
export UV_CACHE_DIR=/run/uv UV_OFFLINE=1 PYTHONUNBUFFERED=1
pids=()
cleanup() {
    local rc=$?
    if (( rc != 0 )); then
        for log in /run/{peer,bluez,btvirt,Xorg}.log; do
            [[ ! -e $log ]] || grep -vE 'method_(return|call)|\[signal\]|command 0x' "$log" | tail -65 || :
        done
        dmesg | tail -28
    fi
    local i
    for ((i=${#pids[@]}-1; i>=0; i--)); do
        kill "${pids[i]}" 2>/dev/null || :
        wait "${pids[i]}" 2>/dev/null || :
    done
}
trap cleanup EXIT
wait_for() {
    local end=$((SECONDS+15))
    until "$@"; do ((SECONDS < end)) || return 1; sleep .15; done
}
modprobe bluetooth
modprobe uhid
modprobe hid-generic
# The guest is a chroot over initramfs. Load BlueZ's AF_ALG providers here.
modprobe algif_skcipher
modprobe cmac
insmod ./hci_vhci.ko
test -c /dev/vhci && test -c /dev/uhid
dbus-daemon --system --fork
if [[ -f dummy.deb ]]; then source ./desktop-xorg.sh; fi
mode=()
controller=()
if grep -qw y700.virtual_classic=1 /proc/cmdline; then mode=(classic); controller=(-B); fi
./btvirt "${controller[@]}" -l2 > /run/btvirt.log 2>&1 & pids+=($!)
wait_for test -e /sys/class/bluetooth/hci1
for adapter in /sys/class/bluetooth/hci?; do
    [[ $(realpath "$adapter") == /sys/devices/virtual/bluetooth/* ]]
done
[[ $(ls /sys/class/bluetooth | wc -l) == 2 ]]
echo "Guest kernel $(uname -r), BlueZ $(/usr/libexec/bluetooth/bluetoothd --version)"
options=()
if ((${#mode[@]})); then options+=(--compat); fi
/usr/libexec/bluetooth/bluetoothd --nodetach --debug "${options[@]}" >/run/bluez.log 2>&1 & pids+=($!)
for controller in hci0 hci1; do
    path=/org/bluez/$controller
    wait_for busctl --system --no-pager get-property org.bluez "$path" org.bluez.Adapter1 Address 2>/dev/null
    busctl --system set-property org.bluez "$path" org.bluez.Adapter1 Powered b true
    busctl --system set-property org.bluez "$path" org.bluez.Adapter1 Pairable b true
done
if ((${#mode[@]})); then
    busctl --system set-property org.bluez /org/bluez/hci1 org.bluez.Adapter1 Discoverable b true
fi
./uv run --offline --no-project --python /usr/bin/python3 python -B peer.py "${mode[@]}" >/run/peer.log 2>&1 & pids+=($!)
wait_for grep -q '^PEER_READY$' /run/peer.log
timeout -k 3 125 ./uv run --offline --no-project --python /usr/bin/python3 python -B central.py "${mode[@]}"
