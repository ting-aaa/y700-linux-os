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
actor=$(sed -nE 's/.*[[:space:]]y700.wifi_actor=([a-z]+).*/\1/p' /proc/cmdline)
case $actor in
    root) test ! -e /run/systemd/system || fail unexpected-system-manager ;;
    seat) test -e /run/systemd/system || fail system-manager-missing ;;
    *) fail bad-actor-mode ;;
esac
printf 'WIFI_STACK kernel=%s nm=%s applet=%s editor=%s\n' "$(uname -r)" \
    "$(dpkg-query -W -f='${Version}' network-manager)" \
    "$(dpkg-query -W -f='${Version}' network-manager-applet)" \
    "$(dpkg-query -W -f='${Version}' nm-connection-editor)"

pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait || true
    if [[ -e /run/netns/wifi-ap ]]; then ip netns delete wifi-ap; fi
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
ap_phy=$(basename "$(readlink -f "/sys/class/net/$ap/phy80211")")
[[ $ap_phy =~ ^phy[0-9]+$ ]] || fail ap-wiphy-missing
# Keep the destination IP out of the station's local routing table. A ping
# in the initial namespace must cross the virtual wireless link.
ip netns add wifi-ap
iw phy "$ap_phy" set netns name wifi-ap || fail ap-namespace
ap_net=(ip netns exec wifi-ap)
test ! -e "/sys/class/net/$ap" || fail ap-remained-in-station-namespace
if [[ $actor == root ]]; then
    /usr/lib/systemd/systemd-udevd --resolve-names=never >/dev/null 2>&1 & pids+=("$!")
fi
for _ in {1..30}; do [[ ! -S /run/udev/control ]] || break; sleep 0.1; done
test -S /run/udev/control || fail udev-start
SYSTEMD_IN_CHROOT=0 udevadm trigger --action=add --subsystem-match=net
SYSTEMD_IN_CHROOT=0 udevadm settle --timeout=8
"${ap_net[@]}" ip link set lo up
"${ap_net[@]}" ip address add 192.0.2.1/24 dev "$ap"

security=$(sed -nE 's/.*[[:space:]]y700.wifi_security=([a-z0-9]+).*/\1/p' /proc/cmdline)
case $security in open|wpa2|sae) ;; *) fail bad-security-mode;; esac
uv run --offline --no-project --python /usr/bin/python3 python ./prepare-ap.py "$security" "$ap"
"${ap_net[@]}" hostapd /run/wifi-fixture/hostapd.conf >/dev/null 2>&1 & pids+=("$!")
ap_ready() { hostapd_cli -p /run/wifi-fixture/hostapd -i "$ap" status 2>/dev/null | grep -Fxq 'state=ENABLED'; }
for _ in {1..40}; do
    if ap_ready; then break; fi
    sleep 0.1
done
ap_ready || { echo 'WIFI_FIXTURE_ERROR ap-did-not-enable' >&2; exit 1; }
LD_LIBRARY_PATH=/opt/wifi-test/lib "${ap_net[@]}" dnsmasq --no-daemon --port=0 --interface="$ap" --bind-interfaces \
    --dhcp-range=192.0.2.11,192.0.2.19,255.255.255.0,1h --dhcp-option=3 --dhcp-authoritative \
    >/dev/null 2>&1 & pids+=("$!")
dhcp=$!

cat > /run/wifi-fixture/NetworkManager.conf <<EOF
[main]
plugins=keyfile
dns=none
rc-manager=unmanaged

[connectivity]
enabled=false
EOF
if [[ $actor == root ]]; then
    dbus-daemon --system --nofork --nopidfile >/dev/null 2>&1 & pids+=("$!")
fi
for _ in {1..40}; do [[ ! -S /run/dbus/system_bus_socket ]] || break; sleep 0.1; done
test -S /run/dbus/system_bus_socket || fail system-bus-start
if ! pgrep -x wpa_supplicant >/dev/null; then
    wpa_supplicant -u >/dev/null 2>&1 & pids+=("$!")
fi
if pgrep -x NetworkManager >/dev/null; then fail unexpected-networkmanager; fi
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
if [[ $actor == seat ]]; then
    chown y700 /run/wifi-fixture/network.json
    [[ -c /dev/tty1 ]] || fail local-vt-missing
    if [[ $(cat /sys/class/tty/tty0/active) != tty1 ]]; then
        uv run --offline --no-project --python /usr/bin/python3 python - <<'PY' || fail local-vt-activation
import fcntl

with open('/dev/tty0', 'rb', buffering=0) as vt:
    fcntl.ioctl(vt, 0x5606, 1)  # VT_ACTIVATE
    fcntl.ioctl(vt, 0x5607, 1)  # VT_WAITACTIVE
PY
    fi
    unit=y700-wifi-session-test.service
    install -o y700 -m600 /dev/null /run/wifi-fixture/seat-receipt
    status=0
    systemd-run --quiet --wait --collect --unit="$unit" -p User=y700 -p PAMName=login \
        -p StandardInput=tty -p TTYPath=/dev/tty1 -p StandardOutput=journal -p StandardError=journal \
        -E XDG_SESSION_TYPE=x11 -E XDG_SESSION_CLASS=user -E XDG_SEAT=seat0 -E XDG_VTNR=1 \
        /opt/wifi-test/seat-actor.sh "$security" &
    seat_job=$!
    tail --pid="$seat_job" -s .3 -n +1 -f /run/wifi-fixture/seat-receipt | grep --line-buffered -E '^WIFI_' || true
    wait "$seat_job" || status=$?
    (( status == 0 )) || fail pam-seat-session
else
    bash ./session.sh fixture "$security"
fi
test "$(station_state)" = 100
iw dev "$station" link | grep -Eq '^Connected to[[:space:]]'
ip -4 address show dev "$station" | grep -Eq 'inet 192\.0\.2\.(1[1-9])/24'
ip route get 192.0.2.1 oif "$station" | grep -Eq " dev $station "
ping -q -c 1 -W 2 -I "$station" 192.0.2.1 >/dev/null
if [[ $security == sae ]]; then
    peer=$(cat "/sys/class/net/$station/address")
    details=$(hostapd_cli -p /run/wifi-fixture/hostapd -i "$ap" sta "$peer")
    grep -Fxq 'AKMSuiteSelector=00-0f-ac-8' <<<"$details" || fail negotiated-sae-missing
    grep -Eq '^flags=.*\[MFP\]' <<<"$details" || fail negotiated-pmf-missing
    echo 'WIFI_SAE_NEGOTIATED akm=SAE pmf=1'
fi
nmcli -w 8 device disconnect "$station" >/dev/null || fail station-cleanup
echo 'WIFI_FIXTURE_PASS nm_connected=1 nl80211_associated=1 local_dhcp=1 local_ping=1'
