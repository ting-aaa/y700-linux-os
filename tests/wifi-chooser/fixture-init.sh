#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
finish() {
    result=$?
    trap - EXIT
    echo "WIFI_VM_EXIT=$result"
    poweroff -f
    while :; do sleep 1; done
}
trap finish EXIT
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
[ -e /dev/fd ] || ln -s /proc/self/fd /dev/fd
grep -qw y700.wifi_fixture=1 /proc/cmdline
test "$(cat /sys/block/vda/ro)" = 1
mount -t ext4 -o ro,noload /dev/vda /lower
mount -t tmpfs tmpfs /runtime
mkdir /runtime/upper /runtime/work
mount -t overlay overlay -o lowerdir=/lower,upperdir=/runtime/upper,workdir=/runtime/work /guest
for directory in dev proc sys; do mount --bind "/$directory" "/guest/$directory"; done
mount -t tmpfs tmpfs /guest/run
mkdir -p /guest/opt/wifi-test
if grep -qw y700.wifi_actor=seat /proc/cmdline; then
    cp -a /test/. /guest/opt/wifi-test/
    cp /bin/busybox /guest/opt/wifi-test/bin/
    cp /test/fixture-seat.service /guest/etc/systemd/system/y700-wifi-fixture.service
    exec switch_root /guest /sbin/init
fi
mount --bind /test /guest/opt/wifi-test
chroot /guest /bin/bash /opt/wifi-test/fixture-guest.sh
