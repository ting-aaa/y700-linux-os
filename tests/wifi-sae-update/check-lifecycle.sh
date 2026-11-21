#!/bin/bash
# Run only in the private RAM image and network namespace prepared by ram-userspace.
set -euo pipefail
umask 077
trap 'echo "WIFI_UPDATE_LIFECYCLE_ERROR line=$LINENO" >&2' ERR
cd /run/wifi-update
[[ $(findmnt -nro FSTYPE /) == overlay && $(findmnt -nro FSTYPE /run) == tmpfs ]]
for interface in /sys/class/net/*; do
    [[ $(readlink -f "$interface") == /sys/devices/virtual/net/* ]]
done
shopt -s nullglob
phys=(/sys/class/ieee80211/*)
[[ -d /sys/class/net/lo && ${#phys[@]} == 0 && -z $(ip route show default) && ! -e /run/dbus/system_bus_socket ]]
[[ ! -e /run/systemd/system && ! -e /etc/y700/user-configured ]]
sha256sum --strict -c SHA256SUMS
inventory() {
    dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
        sed -n 's/^installed\t//p' | LC_ALL=C sort
}
inventory > /run/wifi-original-inventory
[[ $(wc -l </run/wifi-original-inventory) == 1240 ]]
echo 'ffb8818f1fd41efb3b7c7a14782abd62b37bf5dd687cfaa923d3419d785f51c3  /run/wifi-original-inventory' | sha256sum --strict -c -
ip link set lo up
install -d -m755 /run/dbus
dbus-daemon --system --nofork --nopidfile >/run/dbus.log 2>&1 &
bus=$!
nm= wpa=
stop_services() {
    for pid in "$nm" "$wpa"; do
        if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || :; wait "$pid" || :; fi
    done
    nm= wpa=
}
trap 'stop_services; kill "$bus" 2>/dev/null || :; wait "$bus" || :' EXIT
for _ in {1..50}; do [[ ! -S /run/dbus/system_bus_socket ]] || break; sleep .1; done
[[ -S /run/dbus/system_bus_socket ]]

profiles=/etc/NetworkManager/system-connections
mkdir -p "$profiles"
[[ -z $(ls -A "$profiles") ]]
for profile in target other; do
    nmcli --offline connection add type wifi ifname wlan0 con-name "$profile" ssid "qa-$profile" \
        connection.autoconnect no wifi-sec.key-mgmt sae \
        wifi-sec.psk "$(openssl rand -hex 16)" > "$profiles/$profile.nmconnection"
done
sha256sum "$profiles"/*.nmconnection > /run/original-profiles
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
check_running() {
    local stage=$1 nm_version=$2 wpa_version=$3
    [[ $(dpkg-query -W -f='${Version}' network-manager) == "$nm_version" ]]
    [[ $(dpkg-query -W -f='${Version}' wpasupplicant) == "$wpa_version" ]]
    /usr/sbin/wpa_supplicant -u >/run/wpa.log 2>&1 &
    wpa=$!
    /usr/sbin/NetworkManager --no-daemon >/run/nm.log 2>&1 &
    nm=$!
    timeout 15 gdbus wait --system fi.w1.wpa_supplicant1
    timeout 15 gdbus wait --system org.freedesktop.NetworkManager
    kill -0 "$nm" "$wpa"
    cmp "/proc/$nm/exe" /usr/sbin/NetworkManager
    cmp "/proc/$wpa/exe" /usr/sbin/wpa_supplicant
    gdbus call --system --dest fi.w1.wpa_supplicant1 --object-path /fi/w1/wpa_supplicant1 \
        --method org.freedesktop.DBus.Properties.Get fi.w1.wpa_supplicant1 Interfaces | grep -Fq '[]'
    for profile in target other; do
        [[ $(runuser -u y700 -- nmcli -g 802-11-wireless-security.key-mgmt connection show "$profile") == sae ]]
        [[ $(stat -c %a "$profiles/$profile.nmconnection") == 600 ]]
    done
    sha256sum --strict --status -c /run/original-profiles
    printf 'WIFI_UPDATE_LIFECYCLE stage=%s nm=%s supplicant=%s profiles=2 intact=1 radios=0\n' "$stage" "$nm_version" "$wpa_version"
    stop_services
}
check_running baseline 1.52.1-1 2:2.10-24
for stage in candidate stock; do
    if [[ $stage == candidate ]]; then
        nm_version=1.52.1-1+0y7001
        wpa_version=2:2.10-24+0y7001
    else
        nm_version=1.52.1-1
        wpa_version=2:2.10-24
    fi
    [[ $(dpkg-deb -f "$stage"/network-manager_*.deb Version) == "$nm_version" ]]
    [[ $(dpkg-deb -f "$stage"/wpasupplicant_*.deb Version) == "$wpa_version" ]]
    if ! dpkg -i "$stage"/*.deb >/run/dpkg.log 2>&1; then tail -8 /run/dpkg.log; exit 1; fi
    [[ -z $(dpkg --audit) ]]
    apt-get check >/dev/null
    awk -F '\t' -v OFS='\t' -v nm="$nm_version" -v wpa="$wpa_version" \
        '$1=="network-manager"{$2=nm} $1=="wpasupplicant"{$2=wpa} {print}' \
        /run/wifi-original-inventory > /run/wifi-expected-inventory
    inventory | cmp - /run/wifi-expected-inventory
    check_running "$stage" "$nm_version" "$wpa_version"
done
echo WIFI_UPDATE_LIFECYCLE_PASS
