#!/bin/busybox sh
set -eu
b=/bin/busybox
trap '$b poweroff -f' EXIT
$b mount -t proc proc /proc
$b mount -t sysfs sysfs /sys
$b mount -t devtmpfs devtmpfs /dev
$b grep -zFxq linux,dummy-virt /proc/device-tree/compatible
echo 'c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063  /sys/kernel/notes' | $b sha256sum -c -
while read -r mod; do $b insmod "$mod"; done < /modules/order
[ "$($b cat /sys/module/snd_soc_wcd938x/initstate)" = live ]
[ "$($b cat /proc/sys/kernel/tainted)" = 0 ]
$b insmod /modules/regmap-test.ko
v=/stock/proc/asound/card0/codecs/wcd938x/variant
reader() { PATH=/system/bin "$b" chroot /stock /system/bin/sh /reader; }
check() {
    expected=$1
    rc=0
    receipt=$(reader) || rc=$?
    [ "$rc" = "$2" ] && [ "$receipt" = "WCD_STOCK $expected" ] || exit 1
    echo "$receipt"
}
for model in WCD9380 WCD9385; do
    echo "$model" >"$v"
    check "release=CN350 source=driver_cache variant=$model" 0
done
echo VER_UNDEFINED >"$v"; check unresolved=unknown 1
$b rm "$v"; check unresolved=variant_unavailable 1
echo WCD9380 > "$v"; $b cp -a /stock/proc/asound/card0 /stock/proc/asound/card1
check unresolved=variant_unavailable 1
echo bad > /stock/sys/module/machine_dlkm/notes/.note.gnu.build-id; check unresolved=module_mismatch 1
echo wrong > /stock/incremental; check unresolved=build 1
echo 'WCD_QA_PASS native_module=live stock_reader_cases=7'
