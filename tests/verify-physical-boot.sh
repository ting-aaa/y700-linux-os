#!/bin/sh
# Run on the tablet after the attended microSD boot; reads system state only.
set -eu
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
identity="$here/identity.txt"
case $# in
    0) uuid=$(sed -n 's/^root_uuid=//p' "$identity") || fail 'Missing exported identity.txt' ;;
    1) uuid=$1 ;;
    *) fail 'Expected zero arguments or the candidate UUID' ;;
esac
package_count=
expected_digest=
if [ -f "$identity" ]; then
    test "$(sed -n 's/^root_uuid=//p' "$identity")" = "$uuid" || fail 'Candidate UUID differs from identity.txt'
    package_count=$(sed -n 's/^package_count=//p' "$identity")
    expected_digest=$(sed -n 's/^package_digest=//p' "$identity")
fi
if [ -z "$package_count" ] && [ -z "$expected_digest" ]; then
    # Historical candidate 03 predates the package receipt in identity.txt.
    package_count=993
    expected_digest=af07f62e90d1eb88cf0173225b92778d759af652241e8a67fea6d73b8a68c85c
fi
printf '%s\n' "$package_count" | grep -Exq '[1-9][0-9]*' || fail 'Invalid package count'
printf '%s\n' "$expected_digest" | grep -Exq '[0-9a-f]{64}' || fail 'Invalid package digest'
printf '%s\n' "$uuid" | grep -Exq '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' || fail 'Invalid expected root UUID'
expected=y700-prc-$uuid
test "$(cat /etc/y700/image-id)" = "$expected" || fail 'The running system has a different image identity'
test -d /sys/firmware/efi || fail 'EFI runtime missing'
tr '\000' '\n' < /proc/device-tree/compatible | grep -Fxq lenovo,asphalt || fail 'Wrong board compatible'
test "$(tr -d '\000' < /proc/device-tree/region_country)" = PRC || fail 'Wrong board region'
test "$(uname -r)" = 7.3.4-asphalt-prc || fail 'Unexpected kernel'
if [ -f "$identity" ]; then
    notes_digest=$(sed -n 's/^kernel_notes_sha256=//p' "$identity")
    fbdev=$(sed -n 's/^fbdev_emulation=//p' "$identity")
    case "$fbdev" in
        '') ;;
        0) test "$(cat /sys/module/drm_kms_helper/parameters/fbdev_emulation)" = N && test ! -c /dev/fb0 || fail 'Expected the KMS enrollment boot profile' ;;
        *) fail 'Unexpected framebuffer mode in identity' ;;
    esac
    if [ -n "$notes_digest" ]; then
        printf '%s\n' "$notes_digest" | grep -Exq '[0-9a-f]{64}' || fail 'Invalid kernel notes digest'
        printf '%s  /sys/kernel/notes\n' "$notes_digest" | sha256sum -c || fail 'Running kernel differs from the selected build'
    fi
fi
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
# Sort complete tab-separated records bytewise on both builder and tablet.
records=$(dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
    sed -n 's/^installed\t//p' | LC_ALL=C sort)
test "$(printf '%s\n' "$records" | wc -l)" = "$package_count" || fail 'Unexpected package count'
test "$(printf '%s\n' "$records" | sha256sum | cut -d' ' -f1)" = "$expected_digest" || fail 'Installed package versions differ from candidate'
test -z "$(dpkg --audit)" || fail 'Package audit failed'
printf 'PHYSICAL_BOOT_PASS image=%s kernel=%s root=%s esp=%s pid1=systemd media=SD packages=%s\n' "$expected" "$(uname -r)" "$rootdev" "$espdev" "$package_count"
