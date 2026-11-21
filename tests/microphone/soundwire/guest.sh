#!/bin/busybox sh
set -eu
b=/bin/busybox
trap 'echo "WCD_SDW_EXIT=$?"; $b poweroff -f' EXIT
$b mount -t proc proc /proc
$b mount -t sysfs sysfs /sys
$b mount -t devtmpfs devtmpfs /dev
$b grep -zFxq linux,dummy-virt /proc/device-tree/compatible
echo 'c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063  /sys/kernel/notes' | $b sha256sum -c -
while read -r module; do $b insmod "$module"; done < /modules/dependencies
[ "$($b cat /proc/sys/kernel/tainted)" = 0 ]
for variant in original candidate; do
    $b insmod "/modules/$variant.ko"
    if [ "$variant" = original ]; then expected=1; else expected=0; fi
    $b insmod /modules/channels.ko original="$expected"
    $b rmmod channels
    $b rmmod snd_soc_wcd938x_sdw
done
# The external test module sets TAINT_OOT_MODULE (bit 12).
[ "$($b cat /proc/sys/kernel/tainted)" = 4096 ]
echo 'WCD_SDW_PASS variants=2 cases_each=5 physical_bus=0'
