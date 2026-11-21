#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
cd /opt/qcam-virtual
grep -qw y700.qcam_virtual_fixture=1 /proc/cmdline
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
test "$(cat /sys/block/vda/ro)" = 1
if compgen -G '/dev/video[0-9]*' >/dev/null; then
    echo 'Unexpected pre-existing V4L2 camera' >&2
    exit 1
fi
for deb in x11/*.deb; do dpkg-deb -x "$deb" /; done
for deb in runtime/*.deb; do dpkg-deb -x "$deb" /opt/qcam-virtual/runtime-root; done
test "$(dpkg-deb -f runtime/libcamera0.7_*.deb Version)" = 0.7.2-1
dpkg-deb -f ./qcam.deb Package Version Architecture
test "$(dpkg-deb -f ./qcam.deb Package)" = y700-camera-qcam
test "$(dpkg-deb -f ./qcam.deb Architecture)" = arm64
dpkg-deb -x ./qcam.deb /
printf 'QCAM_VIRTUAL_ELF '; sha256sum /opt/y700-camera/bin/qcam
runtime=/opt/qcam-virtual/runtime-root/usr/lib/aarch64-linux-gnu
if [[ -d ./virtual-libs ]]; then
    install -m755 ./virtual-libs/{libcamera,libcamera-base}.so.0.7.2 "$runtime"
    sha256sum "$runtime"/{libcamera,libcamera-base}.so.0.7.2
fi
test -L "$runtime/libcamera.so.0.7"
LD_LIBRARY_PATH="$runtime" ldd /opt/y700-camera/bin/qcam > /run/qcam-libraries
grep -F "$runtime/libcamera.so.0.7" /run/qcam-libraries
if grep -F 'not found' /run/qcam-libraries; then exit 1; fi

config=/usr/share/libcamera/pipeline/virtual
mkdir -p "$config"
install -m644 ./virtual-cameras.yaml "$config/virtual.yaml"
# The disposable test has no physical cameras. Grant its actor access to
# the kernel's synthetic buffer allocator without changing any live policy.
test -c /dev/udmabuf
chown y700 /dev/udmabuf
chmod u+rw /dev/udmabuf
for heap in /dev/dma_heap/*; do
    [[ ! -c $heap ]] || { chown y700 "$heap"; chmod u+rw "$heap"; }
done
mkdir -p /dev/shm
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /dev/shm
install -d -m1777 /tmp/.X11-unix
install -d -m700 -o y700 -g y700 /run/qcam-qa
runuser -u y700 -- dbus-run-session -- bash ./virtual-session.sh
