#!/usr/bin/env bash
# Disposable ARM64 guest only. It supplies an owned local AP on virtual radios.
set -euo pipefail
cd /opt/wifi-test
export PATH=/opt/wifi-test/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
fail() { echo "WIFI_FIXTURE_ERROR $1" >&2; exit 1; }
grep -qw 'y700.wifi_fixture=1' /proc/cmdline || fail boot-marker
tr '\000' '\n' </proc/device-tree/compatible | grep -Fxq linux,dummy-virt || fail not-virtual-board
for device in /sys/class/net/*/device; do
    test ! -e "$device" || fail unexpected-network-device
done
test ! -e /run/systemd/system || fail unexpected-system-manager

pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait || true
}
trap cleanup EXIT
mkdir -p /run/wifi-fixture /run/dbus
test ! -e /sys/module/mac80211_hwsim || fail simulator-already-loaded
insmod ./mac80211_hwsim.ko radios=2 || fail simulator-load
radios=(/sys/class/net/wlan*)
test "${#radios[@]}" = 2 || fail expected-two-radios
for path in "${radios[@]}"; do
    driver=$(readlink -f "$path/device/driver")
    test "${driver##*/}" = mac80211_hwsim || fail unexpected-radio-driver
done
ap=${radios[0]##*/}
station=${radios[1]##*/}
/usr/lib/systemd/systemd-udevd --resolve-names=never >/dev/null 2>&1 & pids+=("$!")
for _ in {1..30}; do [[ ! -S /run/udev/control ]] || break; sleep 0.1; done
test -S /run/udev/control || fail udev-start
SYSTEMD_IN_CHROOT=0 udevadm trigger --action=add --subsystem-match=net
SYSTEMD_IN_CHROOT=0 udevadm settle --timeout=8
ip address add 192.0.2.1/24 dev "$ap"

cat > /run/wifi-fixture/hostapd.conf <<EOF
interface=$ap
driver=nl80211
ssid=Y700 Fixture Open
channel=1
hw_mode=g
auth_algs=1
ctrl_interface=/run/wifi-fixture/hostapd
EOF
hostapd /run/wifi-fixture/hostapd.conf >/dev/null 2>&1 & pids+=("$!")
ap_ready() { hostapd_cli -p /run/wifi-fixture/hostapd -i "$ap" status 2>/dev/null | grep -Fxq 'state=ENABLED'; }
for _ in {1..40}; do
    if ap_ready; then break; fi
    sleep 0.1
done
ap_ready || { echo 'WIFI_FIXTURE_ERROR ap-did-not-enable' >&2; exit 1; }
LD_LIBRARY_PATH=/opt/wifi-test/lib dnsmasq --no-daemon --port=0 --interface="$ap" --bind-interfaces \
    --dhcp-range=192.0.2.11,192.0.2.19,255.255.255.0,1h --dhcp-option=3 --dhcp-authoritative \
    >/dev/null 2>&1 & pids+=("$!")
dhcp=$!

cat > /run/wifi-fixture/NetworkManager.conf <<EOF
[main]
plugins=keyfile
dns=none
rc-manager=unmanaged

[keyfile]
unmanaged-devices=interface-name:$ap

[connectivity]
enabled=false
EOF
dbus-daemon --system --nofork --nopidfile >/dev/null 2>&1 & pids+=("$!")
for _ in {1..40}; do [[ ! -S /run/dbus/system_bus_socket ]] || break; sleep 0.1; done
test -S /run/dbus/system_bus_socket || fail system-bus-start
wpa_supplicant -u >/dev/null 2>&1 & pids+=("$!")
NetworkManager --no-daemon --config=/run/wifi-fixture/NetworkManager.conf >/dev/null 2>&1 & pids+=("$!")
station_state() {
    local value
    value=$(nmcli -g GENERAL.STATE device show "$station" 2>/dev/null) || return 1
    printf '%s\n' "${value%% *}"
}
for _ in {1..70}; do
    if [[ $(station_state) == 30 ]]; then break; fi
    sleep 0.2
done
if [[ $(station_state) != 30 ]]; then
    nmcli --colors no -t -f TYPE,STATE device status || true
    nmcli --colors no -t -f WIFI-HW,WIFI radio || true
    nmcli --colors no -g GENERAL.REASON device show "$station" || true
    printf 'WIFI_FIXTURE_DAEMONS nm=%s supplicant=%s\n' \
        "$(pgrep -xc NetworkManager || true)" "$(pgrep -xc wpa_supplicant || true)"
    nmcli -w 5 radio wifi on 2>/dev/null || fail station-not-ready
    nmcli -w 5 device set "$station" managed yes 2>/dev/null || fail station-managed
    sleep 1
    [[ $(station_state) == 30 ]] || fail station-not-ready
fi
nmcli -w 5 connection add type wifi ifname "$station" con-name 'Y700 Fixture Saved' \
    ssid 'Y700 Fixture Absent' connection.autoconnect no >/dev/null
kill -0 "$dhcp" 2>/dev/null || fail dhcp-server-start
nmcli -w 15 device wifi rescan ifname "$station"
bash ./session.sh fixture
test "$(station_state)" = 100
iw dev "$station" link | grep -Eq '^[[:space:]]*SSID: Y700 Fixture Open$'
ip -4 address show dev "$station" | grep -Eq 'inet 192\.0\.2\.(1[1-9])/24'
ping -q -c 1 -W 2 192.0.2.1 >/dev/null
echo 'WIFI_FIXTURE_PASS nm_connected=1 nl80211_associated=1 local_dhcp=1 local_ping=1'
