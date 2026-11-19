#!/bin/bash
set -euo pipefail
cd /opt/ssc-test
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PYTHONPATH=/opt/ssc-test:/opt/ssc-test/ssc_server:/opt/ssc-test/python
export UV_CACHE_DIR=/run/ssc-proxy-uv PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
test "$(dpkg-query -W -f='${Version}' iio-sensor-proxy)" = '3.9-1~bpo13+1.y7001'
grep -qw y700.ssc_fixture=1 /proc/cmdline
test ! -e /dev/fastrpc-sdsp
test ! -S /run/dbus/system_bus_socket
mkdir -p /run/dbus /run/udev /run/polkit-1
if [[ ! -s /etc/machine-id ]]; then dbus-uuidgen > /etc/machine-id; fi
if [[ ! -e /usr/lib/aarch64-linux-gnu/libqrtr.so.1 ]]; then
    install -m644 lib/libqrtr.so.1 /usr/lib/aarch64-linux-gnu/libqrtr.so.1
fi
dbus-daemon --system --fork --nopidfile
/usr/lib/systemd/systemd-udevd --daemon
./uv run --offline --no-project --python /usr/bin/python3 python ./ssc-server >/run/ssc-server.log 2>&1 &
server=$!
proxy=
cleanup() {
    rc=$?
    if (( rc != 0 )); then
        tail -n30 /run/sensor.log 2>/dev/null || :
        tail -n10 /run/ssc-server.log 2>/dev/null || :
    fi
    [[ -z $proxy ]] || kill "$proxy" 2>/dev/null || :
    kill "$server" 2>/dev/null || :
}
trap cleanup EXIT
for _ in {1..70}; do grep -q 'Waiting for MSGs' /run/ssc-server.log && break; sleep .1; done
grep -q 'Waiting for MSGs' /run/ssc-server.log
insmod ./y700_ssc_qemu.ko
udevadm settle --timeout=10
udevadm info --query=property --name=/dev/fastrpc-sdsp >/run/ssc-udev.properties
grep -E '^IIO_SENSOR_PROXY_TYPE=|^ACCEL_MOUNT_MATRIX=' /run/ssc-udev.properties
for driver in ssc-accel ssc-light ssc-proximity ssc-compass; do
    grep '^IIO_SENSOR_PROXY_TYPE=' /run/ssc-udev.properties | grep -qw "$driver"
done
G_MESSAGES_DEBUG=all /usr/libexec/iio-sensor-proxy >/run/sensor.log 2>&1 & proxy=$!
for _ in {1..80}; do
    if busctl --system --auto-start=no --timeout=1s get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy HasAccelerometer 2>/dev/null | grep -qx 'b true'; then break; fi
    kill -0 "$proxy"
    sleep .15
done
for prop in HasAccelerometer HasAmbientLight HasProximity; do
    busctl --system --auto-start=no --timeout=2s get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy "$prop" | grep -Fx 'b true'
done
./uv run --offline --no-project --python /usr/bin/python3 python ./claims.py
echo SSC_DESKTOP_QRTR_PASS
