#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
grep -qw 'y700.virtual_hid=1' /proc/cmdline
grep -zFxq 'linux,dummy-virt' /proc/device-tree/compatible
[[ $(uname -m) == aarch64 && -z $(ls -A /sys/class/bluetooth 2>/dev/null) ]]
cd /opt/y700-virtual-hid
if grep -qw y700.blueman_pair=1 /proc/cmdline; then export Y700_BLUEMAN_PAIR=1; fi
if grep -qw y700.blueman_keyboard=1 /proc/cmdline; then
    trap 'echo "KEYBOARD_FIXTURE_ERROR line=$LINENO"' ERR
fi
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
    if grep -qw y700.virtual_login=1 /proc/cmdline; then
        grep -Fxq IMAGE_VERSION=dev12.12 /etc/os-release
        printf '%s  /sys/kernel/notes\n' c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063 | sha256sum -c -
        secret=/var/lib/bluetooth/.qa-password
        if [[ $bond_phase == seed ]]; then
            (umask 077; od -An -N8 -tx1 /dev/urandom | tr -d ' \n' > "$secret")
        fi
        [[ $(stat -c %a "$secret") == 600 && $(wc -c < "$secret") == 16 ]]
        printf 'y700:%s\n' "$(<"$secret")" | chpasswd
        [[ $(/usr/libexec/y700-firstboot-drm/enroll --state) == active ]]
        export Y700_LE_LOGIN=1
    fi
else
    mount -t tmpfs -o mode=700 tmpfs /var/lib/bluetooth
fi
if ! mountpoint -q /dev/shm; then mount -t tmpfs -o mode=1777 tmpfs /dev/shm; fi
export UV_CACHE_DIR=/run/uv UV_OFFLINE=1 PYTHONUNBUFFERED=1
pids=()
stage=kernel
cleanup() {
    local rc=$?
    if (( rc != 0 && greeter )) && [[ ${Y700_LE_LOGIN:-0} == 1 ]]; then
        ps -u y700 -o comm= | sort -u | grep -E '^(xfce|xfwm|xfsettings|Thunar)' || :
        grep -Ei 'screensaver|autostart|xfce4-session|xfwm4' /home/y700/.xsession-errors 2>/dev/null | tail -12 || :
    fi
    if (( rc != 0 )) && [[ ${Y700_BLUEMAN_PAIR:-0} == 1 && -f /run/bluez.log ]]; then
        for event in 'Default agent set' 'Calling Agent.RequestConfirmation' 'Calling Agent.RequestAuthorization' 'Calling Agent.RequestPasskey'; do
            echo "BLUEZ_AGENT_STAGE $event count=$(grep -Fc "$event" /run/bluez.log || :)"
        done
        if [[ -r /run/cold-bond/agent-methods ]]; then
            for method in DisplayPasskey RequestPasskey RequestConfirmation; do
                echo "KEYBOARD_AGENT_STAGE $method count=$(grep -cw "$method" /run/cold-bond/agent-methods || :)"
            done
        fi
        if [[ -s /run/cold-bond/trace ]]; then
            btmon -r /run/cold-bond/trace > /run/cold-bond/decoded
            grep -E 'SMP: (Pairing (Request|Response|DHKey Check|Failed)|Security Request)|IO capability:|Authentication requirement:|@ MGMT Event: User Confirmation Request' /run/cold-bond/decoded | sort -u || :
        fi
    fi
    if (( rc != 0 )) && [[ -z $bond_phase && ${Y700_BLUEMAN_PAIR:-0} != 1 ]]; then
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
    if [[ ${Y700_LE_LOGIN:-0} == 1 && $greeter == 1 ]]; then systemctl stop bluetooth; fi
    if [[ -n $bond_phase ]]; then sync; umount /var/lib/bluetooth; fi
    if (( greeter )); then
        if (( rc != 0 )); then echo "GREETER_FIXTURE_ERROR line-or-stage=$stage"; fi
        echo "Y700_VIRTUAL_HID_EXIT=$rc"
    fi
}
trap cleanup EXIT
wait_for() {
    local end=$((SECONDS+15))
    if (( greeter )) && [[ ${Y700_LE_LOGIN:-0} == 1 ]]; then end=$((SECONDS+45)); fi
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
if [[ ${Y700_BLUEMAN_PAIR:-0} == 1 ]]; then umask 077; fi
mode=()
controller=()
if grep -qw y700.virtual_classic=1 /proc/cmdline; then mode=(classic); controller=(-B); fi
if [[ -n $bond_phase || ${Y700_BLUEMAN_PAIR:-0} == 1 ]]; then
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
if [[ ${Y700_LE_LOGIN:-0} == 1 && $greeter == 1 ]]; then
    systemctl start bluetooth
    systemctl is-active --quiet bluetooth
    echo LE_LOGIN_BLUEZ_STOCK_SERVICE_ACTIVE
else
    /usr/libexec/bluetooth/bluetoothd --nodetach --debug "${options[@]}" >/run/bluez.log 2>&1 & pids+=($!)
fi
for controller in hci0 hci1; do
    path=/org/bluez/$controller
    wait_for busctl --system --no-pager get-property org.bluez "$path" org.bluez.Adapter1 Address 2>/dev/null
    if [[ -n $bond_phase || ${Y700_BLUEMAN_PAIR:-0} == 1 ]]; then
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
stage=peer
./uv run --offline --no-project --python /usr/bin/python3 python -B peer.py "${mode[@]}" >/run/peer.log 2>&1 & pids+=($!)
wait_for grep -q '^PEER_READY$' /run/peer.log
if [[ ${Y700_BLUEMAN_PAIR:-0} == 1 ]]; then
    # rfkill predates this chroot's udevd. Replay its normal coldplug event.
    echo add >/sys/class/misc/rfkill/uevent
    wait_for runuser -u y700 -- test -r /dev/rfkill
    chown y700:y700 /run/y700-virtual-hid.sock
    chmod 600 /run/y700-virtual-hid.sock
    xrandr --newmode 2560x1600 268.50 2560 2608 2640 2720 1600 1603 1609 1646 +hsync -vsync
    xrandr --addmode DUMMY0 2560x1600
    xrandr --output DUMMY0 --mode 2560x1600
    (for ((i=0;i<300;i++)); do
        if grep -qE 'Default agent set to .* /org/bluez/agent/blueman' /run/bluez.log; then
            touch /run/blueman-default-ready; exit
        fi
        sleep .2
    done) & pids+=("$!")
    if grep -qw y700.blueman_keyboard=1 /proc/cmdline; then
        grep -Fxq IMAGE_VERSION=dev12.12 /etc/os-release
        printf '%s  /sys/kernel/notes\n' c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063 | sha256sum -c -
        mkdir -p /dev/pts
        mount -t devpts -o mode=620,gid=5 devpts /dev/pts
        # Profile mode records method headers only, never the displayed number.
        stdbuf -oL dbus-monitor --system --profile "type='method_call',interface='org.bluez.Agent1'" \
            >/run/cold-bond/agent-methods 2>/dev/null & pids+=($!)
    fi
    timeout -k 3 145 runuser -u y700 -- dbus-run-session -- bash ./numeric-session.sh
    kill -INT "$monitor"
    wait "$monitor"
    btmon -r /run/cold-bond/trace > /run/cold-bond/decoded
    if grep -qw y700.blueman_keyboard=1 /proc/cmdline; then
        ./uv run --offline --no-project --python /usr/bin/python3 python -B keyboard-trace.py
        ./uv run --offline --no-project --python /usr/bin/python3 python -B numeric-trace.py --two-connections
        echo Y700_BLUEMAN_KEYBOARD_PASS
        exit 0
    fi
    for agent in /org/bluez/agent/blueman /org/y700/test/peer; do
        [[ $(grep -c "Calling Agent.RequestConfirmation: .*path=$agent," /run/bluez.log) == 1 ]]
    done
    if grep -qw y700.blueman_deny=1 /proc/cmdline; then
        grep -Fq 'User Confirmation Negative Reply' /run/cold-bond/decoded
        grep -Fq 'SMP: Pairing Failed' /run/cold-bond/decoded
        if grep -Fq 'Enabled with AES-CCM' /run/cold-bond/decoded; then exit 1; fi
        echo Y700_BLUEMAN_HOG_REJECT_PASS
        exit 0
    fi
    for pattern in 'SMP: Pairing Request' 'SMP: Pairing Response' 'SMP: Pairing DHKey Check' 'Authenticated key from P-256' 'Enabled with AES-CCM'; do
        grep -Fq "$pattern" /run/cold-bond/decoded || { echo "Missing link stage $pattern"; exit 1; }
    done
    ./uv run --offline --no-project --python /usr/bin/python3 python -B numeric-trace.py
    echo 'HCI_REAL_PAIR numeric_comparison=1 authenticated_p256=1 aes_ccm=1 att_notify=1'
    echo Y700_BLUEMAN_HOG_PASS
    exit 0
fi
if (( greeter )); then
    stage=display
    source ./greeter-seat.sh
    stage=greeter-input
fi
if [[ -n $bond_phase ]]; then
    deadline=150
    if [[ ${Y700_LE_LOGIN:-0} == 1 && $greeter == 1 ]]; then deadline=360; fi
    timeout -k 3 "$deadline" ./uv run --offline --no-project --python /usr/bin/python3 python -B cold-boot.py "$bond_phase"
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
