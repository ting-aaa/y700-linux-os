#!/bin/sh
set -eu
b=/bin/busybox
$b mount -t devtmpfs devtmpfs /dev
$b mount -t proc proc /proc
$b mount -t sysfs sysfs /sys
exec > /dev/console 2>&1
trap '$b poweroff -f' EXIT
$b insmod /videobuf2-vmalloc.ko
$b insmod /v4l2-tpg.ko
$b insmod /vimc.ko
media=/dev/media0
/check "$media" 'Sensor A' | $b grep -F 'lens="Lens A"'
/check "$media" 'Sensor B' | $b grep -F 'lens="Lens B"'
$b mkdir /held
$b mv /dev/v4l-subdev* /held/
line=$(/check "$media" 'Sensor A')
echo "MEDIA_ONLY subdev_nodes_hidden=1 $line"
devnum=${line##*interface=}
$b mv /held/v4l-subdev* /dev/
name=$($b sed -n 's/^DEVNAME=//p' "/sys/dev/char/$devnum/uevent")
range=$(/check "$media" 'Sensor A' --query-range "/dev/$name")
echo "$range"
echo "$range" | $b grep -q '^FOCUS_ABSOLUTE min=0 max=1023 step=1 default=0 '
if /check "$media" 'Sensor B' --query-range "/dev/$name"; then exit 1; fi
if /check "$media" 'Missing Sensor'; then exit 1; fi
$b rmmod vimc
$b insmod /no-link.ko
if /check "$media" 'Sensor A'; then exit 1; fi
/check "$media" 'Sensor B' | $b grep -F 'lens="Lens B"'
$b rmmod vimc
$b insmod /no-lens.ko
if reason=$(/check "$media" 'Sensor A' 2>&1); then exit 1; fi
echo "$reason" | $b grep -F 'media graph contains no lens entity'
echo 'LENS_GRAPH_QA_PASS media_only=1 query=FOCUS_ABSOLUTE wrong_node=refused missing_ancillary_link=refused missing_lens=refused moves_requested=0'
