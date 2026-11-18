#!/bin/sh
# Run on the tablet after the attended microSD boot; reads system state only.
set -eu
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
uuid=${1:?expected candidate UUID from identity.txt}
expected=y700-prc-$uuid
test "$(cat /etc/y700/image-id)" = "$expected" || fail 'The running system has a different image identity'
test -d /sys/firmware/efi || fail 'EFI runtime missing'
tr '\000' '\n' < /proc/device-tree/compatible | grep -Fxq lenovo,asphalt || fail 'Wrong board compatible'
test "$(tr -d '\000' < /proc/device-tree/region_country)" = PRC || fail 'Wrong board region'
test "$(uname -r)" = 7.3.4-asphalt-prc || fail 'Unexpected kernel'
test "$(cat /proc/1/comm)" = systemd || fail 'Unexpected PID 1'
test "$(findmnt -nro UUID /)" = "$uuid" || fail 'Unexpected root UUID'
rootdev=$(findmnt -nro SOURCE /)
espdev=$(findmnt -nro SOURCE /boot)
test "$rootdev" = "$(readlink -f /dev/disk/by-partlabel/y700-test-root)" || fail 'Unexpected root partition'
test "$espdev" = "$(readlink -f /dev/disk/by-partlabel/y700-test-esp)" || fail 'Unexpected ESP'
parent=$(lsblk -no PKNAME "$rootdev")
test "$parent" = "$(lsblk -no PKNAME "$espdev")" || fail 'ESP is not on the root card'
test "$(cat "/sys/class/block/$parent/device/type")" = SD || fail 'Root is not on SD'
case "$(readlink -f "/sys/class/block/$parent")" in */8804000.mmc/*|*/8804000.sdhci/*) ;; *) fail 'Unexpected SD controller' ;; esac
test "$(findmnt -nro FSTYPE /)" = ext4 && test "$(findmnt -nro FSTYPE /boot)" = vfat || fail 'Unexpected filesystems'
test "$(dpkg-query -W -f='${Version}' y700-platform)" = '0.1.0~dev2' || fail 'Unexpected platform package'
test "$(dpkg-query -W -f='${db:Status-Status}\n' | grep -cx installed)" = 993 || fail 'Unexpected package count'
test -z "$(dpkg --audit)" || fail 'Package audit failed'
printf 'PHYSICAL_BOOT_PASS image=%s kernel=%s root=%s esp=%s pid1=systemd media=SD packages=993\n' "$expected" "$(uname -r)" "$rootdev" "$espdev"
