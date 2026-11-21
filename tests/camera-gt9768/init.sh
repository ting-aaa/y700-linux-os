#!/bin/sh
set -eu
b=/bin/busybox
$b mount -t devtmpfs devtmpfs /dev
$b mount -t sysfs sysfs /sys
$b mount -t proc proc /proc
exec >/dev/console 2>&1
trap '$b poweroff -f' EXIT
$b insmod /adapter.ko
p=/sys/module/adapter/parameters
drv=/sys/bus/i2c/drivers/asphalt-gt9768
for sensor in /sys/bus/i2c/drivers/test-hi1339/*-0020; do test -L "$sensor"; done
id=${sensor##*/}; id=${id%-0020}
dev=$id-000c
for k in 1 2 3 4 5; do test -L "$drv/$dev" && break; $b sleep 1; done
test -L "$drv/$dev"
graph=$(/graph /dev/media0 "fake-hi1339 $id-0020")
echo "$graph"
major_minor=${graph##*interface=}
node=$($b sed -n 's/^DEVNAME=//p' "/sys/dev/char/$major_minor/uevent")
vaf=
for supply in /sys/class/regulator/regulator.*; do
	if test "$($b cat "$supply/name")" = synthetic-lens; then vaf=$supply/num_users; fi
done
test -f "$vaf"
/control "/dev/$node" "$dev" "$vaf"
# An open descriptor held through unbind was closed by /control. Test two bad
# probes and verify reads never sent a DAC/init write.
before=$($b cat "$p/writes")
for fault in 1 2 5; do
	echo "$fault" > "$p/fault"
	if echo "$dev" > "$drv/bind"; then exit 1; fi
	test ! -L "$drv/$dev"
	test "$($b cat "$p/resumes")" = "$($b cat "$p/suspends")"
	test "$($b cat "$p/writes")" = "$before"
done
echo 0 > "$p/fault"
echo "$dev" > "$drv/bind"
graph=$(/graph /dev/media0 "fake-hi1339 $id-0020")
echo "$graph"
test "$($b cat "$p/writes")" = "$before"
major_minor=${graph##*interface=}
node=$($b sed -n 's/^DEVNAME=//p' "/sys/dev/char/$major_minor/uevent")
/control "/dev/$node" "$dev" "$vaf" "$id-0020"
test ! -L "$drv/$dev"
echo 'GT9768_QA_PASS bad_crc=refused wrong_id=refused reversed_crc_valid=refused rebind=1 controller=virtual'
