#!/bin/bash
set -Eeuo pipefail
exec > /dev/console 2>&1
cd /opt/ssc-test
mode=$(sed -n 's/.*y700.ssc_lifecycle=\([^ ]*\).*/\1/p' /proc/cmdline)
[[ $(cat /proc/1/comm) == systemd && $(uname -m) == aarch64 ]]
listener=y700-ssc.service
proxy=iio-sensor-proxy.service
device=$(systemd-escape -p --suffix=device /dev/fastrpc-sdsp)
trap 'echo "SSC assertion failed at line $LINENO"; systemctl status --no-pager "$listener" "$proxy" || :; journalctl -b -u "$listener" -u "$proxy" -n 25 --no-pager' ERR
wait_state() {
    for _ in {1..180}; do
        [[ $(systemctl show --value -p ActiveState "$1") != "$2" ]] || return 0
        sleep .25
    done
    return 1
}
insert() {
    insmod ./y700_ssc_qemu.ko
    udevadm settle --timeout=20
    wait_state "$device" active
}
remove() {
    rmmod y700_ssc_qemu
    udevadm settle --timeout=20
    wait_state "$device" inactive
    wait_state "$listener" inactive
    wait_state "$proxy" inactive
    ! test -c /dev/fastrpc-sdsp
}
ready() {
    wait_state "$listener" active
    wait_state "$proxy" active
    for prop in HasAccelerometer HasAmbientLight HasProximity; do
        for _ in {1..60}; do
            value=$(busctl --auto-start=no get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy "$prop" 2>/dev/null) || value=
            [[ $value != 'b true' ]] || break
            sleep .25
        done
        test "$value" = 'b true'
    done
    test -s /var/lib/y700-ssc/registry/sns_reg_version
    systemctl show --value -p InvocationID "$listener" | grep -Eq '^[0-9a-f]{32}$'
}
case $mode in
    upgrade)
        test "$(dpkg-query -W -f='${Version}' y700-ssc-runtime)" = 0.1.1
        wait_state "$listener" inactive
        insert
        if udevadm info -q property -n /dev/fastrpc-sdsp | grep '^SYSTEMD_WANTS=' | grep -qw y700-ssc.service; then exit 1; fi
        wait_state "$listener" inactive
        printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
        chmod 755 /usr/sbin/policy-rc.d
        dpkg -i ./runtime.deb
        wait_state "$listener" inactive
        rm -f /usr/sbin/policy-rc.d
        systemctl mask "$listener"
        dpkg -i ./runtime.deb
        wait_state "$listener" inactive
        systemctl unmask "$listener"
        dpkg -i ./runtime.deb
        ready
        instance=$(systemctl show --value -p InvocationID "$listener")
        dpkg -i ./runtime.deb
        test "$instance" = "$(systemctl show --value -p InvocationID "$listener")"
        echo 'SSC upgrade: 0.1.1 device present; policy and mask preserved; native configuration activated once'
        ;;
    cold)
        test "$(dpkg-query -W -f='${Version}' y700-ssc-runtime)" = 0.1.3
        ready
        echo 'SSC coldplug: SDSP existed before PID1; distro udev coldplug activated the listener and proxy'
        ;;
    late)
        test "$(dpkg-query -W -f='${Version}' y700-ssc-runtime)" = 0.1.3
        wait_state "$listener" inactive
        wait_state "$proxy" inactive
        if systemctl list-jobs --no-legend | grep -Fq "$device"; then exit 1; fi
        insert
        ready
        echo 'SSC late: no device job on boot; module insertion activated both services'
        ;;
    *) exit 2 ;;
esac
old=$(systemctl show --value -p InvocationID "$listener")
remove
echo 'SSC removal: listener and proxy inactive'
insert
ready
test "$old" != "$(systemctl show --value -p InvocationID "$listener")"
for name in y700-ssc-device.target iio-sensor-proxy.service; do
    udevadm info -q property -n /dev/fastrpc-sdsp | grep '^SYSTEMD_WANTS=' | grep -qw "$name"
done
# Exercise queued remove/add events without waiting for the old services to
# stop in between. A stale stop job must not strand this device generation.
rmmod y700_ssc_qemu
insmod ./y700_ssc_qemu.ko
udevadm settle --timeout=20
test -c /dev/fastrpc-sdsp
udevadm info -q property -n /dev/fastrpc-sdsp | grep '^SYSTEMD_WANTS='
wait_state "$device" active
systemctl show -p ActiveState -p Wants -p Upholds "$device"
ready
echo 'SSC rapid re-add: new device and desktop proxy ready'
remove
if [[ $mode == upgrade ]]; then
    registry_before=$(sha256sum /var/lib/y700-ssc/registry/sns_reg_version)
    dpkg -i ./rollback.deb
    systemctl daemon-reload
    udevadm control --reload
    test "$(dpkg-query -W -f='${Version}' y700-ssc-runtime)" = 0.1.1
    test "$registry_before" = "$(sha256sum /var/lib/y700-ssc/registry/sns_reg_version)"
    insert
    if udevadm info -q property -n /dev/fastrpc-sdsp | grep '^SYSTEMD_WANTS=' | grep -Eq 'y700-ssc(-device)?\.'; then exit 1; fi
    wait_state "$listener" inactive
    rmmod y700_ssc_qemu
    echo 'SSC rollback: sealed 0.1.1 restored, registry version preserved, listener inactive on later SDSP add'
fi
if [[ $mode == late ]]; then
    systemctl mask "$listener"
    cursor=$(journalctl -b -n0 --show-cursor | sed -n 's/^-- cursor: //p')
    test -n "$cursor"
    insert
    sleep 4
    test "$(systemctl show --value -p MainPID "$listener")" = 0
    test "$(systemctl show --value -p LoadState "$listener")" = masked
    test "$(systemctl show --value -p MainPID "$proxy")" = 0
    attempts=$(journalctl -b --after-cursor="$cursor" --no-pager --output=cat | grep -c 'y700-ssc.service.*masked' || :)
    (( attempts <= 10 ))
    echo "SSC masked hotplug: listener and proxy PIDs zero; masked-unit messages in four seconds=$attempts"
    rmmod y700_ssc_qemu
    udevadm settle --timeout=20
fi
echo "SSC_LIFECYCLE_PASS $mode" > /dev/console
