#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
grep -qw 'y700.virtual_hid=1' /proc/cmdline
grep -zFxq 'linux,dummy-virt' /proc/device-tree/compatible
[[ $(uname -m) == aarch64 && -z $(ls -A /sys/class/bluetooth 2>/dev/null) ]]
cd /opt/y700-virtual-hid
if grep -qw y700.windows_report=1 /proc/cmdline; then export Y700_WINDOWS_REPORT=1; fi
if grep -qw y700.virtual_typing=1 /proc/cmdline; then
    export Y700_BT_TYPING=1
    dpkg-query -W bluez onboard y700-platform
fi
mkdir -p /var/lib/bluetooth /run/dbus /dev/shm
bond_phase=
for phase in seed resume; do
    if grep -qw "y700.virtual_bond=$phase" /proc/cmdline; then bond_phase=$phase; fi
done
greeter=0
if grep -qw y700.virtual_greeter=1 /proc/cmdline; then greeter=1; fi
if [[ -n $bond_phase ]]; then
    mount -t ext4 -o nodev,nosuid,noexec LABEL=Y700_BT_TEST /var/lib/bluetooth
    chmod 700 /var/lib/bluetooth
    echo "COLD_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)"
else
    mount -t tmpfs -o mode=700 tmpfs /var/lib/bluetooth
fi
if ! mountpoint -q /dev/shm; then mount -t tmpfs -o mode=1777 tmpfs /dev/shm; fi
export UV_CACHE_DIR=/run/uv UV_OFFLINE=1 PYTHONUNBUFFERED=1
pids=()
stage=kernel
cleanup() {
    local rc=$?
    if (( rc != 0 )) && [[ -z $bond_phase ]]; then
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
    if [[ -n $bond_phase ]]; then sync; umount /var/lib/bluetooth; fi
    if (( greeter )); then
        if (( rc != 0 )); then echo "GREETER_FIXTURE_ERROR line-or-stage=$stage"; fi
        echo "Y700_VIRTUAL_HID_EXIT=$rc"
    fi
}
trap cleanup EXIT
wait_for() {
    local end=$((SECONDS+15))
    until "$@"; do ((SECONDS < end)) || return 1; sleep .15; done
}
adapter_boolean() {
    local path=$1 property=$2 value=$3
    if [[ $(busctl --system --timeout=4 get-property org.bluez "$path" org.bluez.Adapter1 "$property") == "b $value" ]]; then
        return 0
    fi
    busctl --system set-property org.bluez "$path" org.bluez.Adapter1 "$property" b "$value" >/dev/null 2>&1 || :
    return 1
}
modprobe bluetooth
modprobe uhid
modprobe hid-generic
# The guest is a chroot over initramfs. Load BlueZ's AF_ALG providers here.
modprobe algif_skcipher
modprobe cmac
insmod ./hci_vhci.ko
test -c /dev/vhci && test -c /dev/uhid
stage=display
if (( ! greeter )); then
    dbus-daemon --system --fork
    if [[ -f dummy.deb ]]; then source ./desktop-xorg.sh; fi
fi
stage=bluetooth
mode=()
controller=()
if grep -qw y700.virtual_classic=1 /proc/cmdline; then mode=(classic); controller=(-B); fi
if [[ -n $bond_phase ]]; then
    install -d -m700 /run/cold-bond
    btmon -w /run/cold-bond/trace >/dev/null 2>&1 & monitor=$!; pids+=("$monitor")
    wait_for test -s /run/cold-bond/trace
fi
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
    if [[ -n $bond_phase ]]; then
        wait_for adapter_boolean "$path" Powered true
        value=true
        [[ $bond_phase != resume ]] || value=false
        wait_for adapter_boolean "$path" Pairable "$value"
    else
        busctl --system set-property org.bluez "$path" org.bluez.Adapter1 Powered b true
        busctl --system set-property org.bluez "$path" org.bluez.Adapter1 Pairable b true
    fi
done
if ((${#mode[@]})); then
    busctl --system set-property org.bluez /org/bluez/hci1 org.bluez.Adapter1 Discoverable b true
fi
if [[ $bond_phase == resume ]]; then mode+=(resume); fi
./uv run --offline --no-project --python /usr/bin/python3 python -B peer.py "${mode[@]}" >/run/peer.log 2>&1 & pids+=($!)
wait_for grep -q '^PEER_READY$' /run/peer.log
if (( greeter )); then
    stage=display
    source ./greeter-seat.sh
    stage=greeter-input
fi
if [[ -n $bond_phase ]]; then
    timeout -k 3 150 ./uv run --offline --no-project --python /usr/bin/python3 python -B cold-boot.py "$bond_phase"
    kill -INT "$monitor"
    wait "$monitor"
    if grep -qw y700.virtual_classic=1 /proc/cmdline; then
        ./uv run --offline --no-project --python /usr/bin/python3 python -B cold-boot.py "classic-trace-$bond_phase"
        echo "Y700_COLD_${bond_phase^^}_PASS"
        exit 0
    fi
    btmon -r /run/cold-bond/trace > /run/cold-bond/decoded
    grep -q 'Enabled with AES-CCM' /run/cold-bond/decoded
    if [[ $bond_phase == resume ]]; then
        grep -q 'LE Long Term Key Request Reply' /run/cold-bond/decoded
        if grep -Eq 'SMP: Pairing (Request|Response)' /run/cold-bond/decoded; then exit 1; fi
    else
        grep -q 'SMP: Pairing Request' /run/cold-bond/decoded
    fi
    echo "HCI_AES_CCM_VERIFIED pairing_exchange=$([[ $bond_phase == seed ]] && echo yes || echo no)"
    echo "Y700_COLD_${bond_phase^^}_PASS"
    exit 0
fi
timeout -k 3 125 ./uv run --offline --no-project --python /usr/bin/python3 python -B central.py "${mode[@]}"
