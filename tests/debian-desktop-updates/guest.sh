#!/bin/bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
cd /opt/y700-topology
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
grep -qw y700.topology_fixture=1 /proc/cmdline
[[ $(cat /sys/block/vda/ro) == 1 && $(cat /proc/1/comm) == systemd ]]
finish() { rc=$?; trap - EXIT; echo "UPDATER_GUEST_EXIT=$rc"; ./busybox poweroff -n -f; }
trap finish EXIT
trap 'echo "UPDATER_GUEST_FAIL line=$LINENO" >&2' ERR
# The board kernel has no PL031 RTC driver on virt. Verify the fresh signature at build time.
date -u -s "@$(cat fixture-epoch)" >/dev/null
systemctl is-active --quiet systemd-logind.service
# All apt sources, indexes and trust material for this boot live in guest RAM.
mkdir -p /var/lib/apt/lists /etc/apt/sources.list.d
mount -t tmpfs tmpfs /etc/apt/sources.list.d
mount -t tmpfs tmpfs /var/lib/apt/lists
: > /etc/apt/sources.list
install -m644 fixture-keyring.gpg /etc/apt/keyrings/y700-fixture.gpg
echo 'deb [arch=arm64 signed-by=/etc/apt/keyrings/y700-fixture.gpg] file:/opt/y700-topology/repo trixie main' > /etc/apt/sources.list.d/fixture.list
apt-get -o Acquire::Languages=none update > /run/apt.log
dpkg -i debs/*.deb baseline.deb >/run/install.log || { cat /run/install.log; exit 1; }
inventory() { dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' | sed -n 's/^installed\t//p' | sort; }
inventory > /run/before
[[ $(cat /usr/share/y700-qa-updater/version) == 1.0 ]]
mapfile -t upgrades < <(apt-get -s upgrade | sed -n 's/^Inst \([^ ]*\).*/\1/p')
[[ ${upgrades[*]} == y700-qa-updater ]]
echo 'UPDATER_APT available=1 signed_file_repo=1 only_package=y700-qa-updater'
# The standalone GUI fixture uses no network device. An in-guest loopback route
# provides the network-available state; all package data comes from signed file:/.
ip link set lo up
ip route add default dev lo
# Normal admin authentication on disposable accounts. The guest has no NIC or host mounts.
(umask 077; cat /proc/sys/kernel/random/uuid > /run/updater-qa-password)
for account in root y700; do printf '%s:%s\n' "$account" "$(cat /run/updater-qa-password)" | chpasswd; done
chown y700 /run/updater-qa-password
stdbuf -oL dbus-monitor --system "type='method_call',interface='org.freedesktop.PackageKit.Transaction'" "type='signal',interface='org.freedesktop.PackageKit.Transaction',member='Finished'" > /run/updater-transactions.log 2>/dev/null &
monitor=$!
bash ./xorg.sh
method=UpdatePackages
if [[ -e product-mode ]]; then method=RefreshCache; fi
for _ in {1..25}; do
    result=$(./uv run --offline --no-project --python /usr/bin/python3 python -B transactions.py "$method")
    [[ $result == 1 ]] && break
    sleep .4
done
if [[ $result != 1 ]]; then
    grep -A1 -E 'member=(RefreshCache|UpdatePackages|Finished)' /run/updater-transactions.log | tail -35 >&2 || :
    exit 1
fi
kill "$monitor"
echo "UPDATER_TRANSACTION method=$method success=1"
if [[ -e product-mode ]]; then
    inventory | cmp - /run/before
    [[ $(cat /usr/share/y700-qa-updater/version) == 1.0 ]]
    echo 'UPDATER_PRODUCT refresh=success stock_viewer=opened unattended_updates=0'
    exit 0
fi
[[ $(cat /usr/share/y700-qa-updater/version) == 2.0 ]]
inventory > /run/after
diff -U0 /run/{before,after} > /run/delta || [[ $? == 1 ]]
[[ $(grep -Ec '^[-+]y700-qa-updater[[:space:]]' /run/delta) == 2 && $(grep -Ec '^[-+][^-+]' /run/delta) == 2 ]]
dpkg -i baseline.deb >/dev/null
inventory | cmp - /run/before
[[ $(cat /usr/share/y700-qa-updater/version) == 1.0 && -z $(dpkg --audit) ]]
echo 'UPDATER_ROLLBACK one_changed_package=1 version=1.0 inventory_restored=1'
echo UPDATER_STOCK_PASS
