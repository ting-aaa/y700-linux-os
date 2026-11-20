#!/usr/bin/env bash
# Run only on an unbooted, writable dev11.1 clone. The source archive stays outside it.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C DEBIAN_FRONTEND=noninteractive SYSTEMD_OFFLINE=1
(( $# == 2 )) || { echo 'Usage: upgrade-dev12.1-root.sh MOUNTED-ROOT DEV12P1.deb' >&2; exit 2; }
root=$(realpath -e -- "$1")
archive=$(realpath -e -- "$2")
[[ $EUID == 0 && $root != / && $(stat -Lc '%d:%i' -- "$root") != "$(stat -Lc '%d:%i' /)" ]]
mountpoint -q -- "$root"
test "$(findmnt -n -o FSTYPE --target "$root")" = ext4
test "$(cat "$root/etc/y700/image-id")" = y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f
test ! -s "$root/etc/machine-id"
test ! -e "$root/etc/y700/user-configured"
test ! -e "$root/etc/y700/bluetooth-address"
test ! -e "$root/var/lib/y700-ssc/registry"
test ! -e "$root/run/y700-speaker-calibration"
test "$(chroot "$root" passwd -S y700 | cut -d' ' -f2)" = L
echo "844a0996e6e9947ddc6859ef2896b91c3980816cf6b373e7335b22c07e2c6bbb  $archive" | sha256sum --strict -c -
test "$(dpkg-deb -f "$archive" Package)" = y700-platform
test "$(dpkg-deb -f "$archive" Version)" = '0.1.0~dev12.1'
test "$(dpkg-deb -f "$archive" Architecture)" = all
work=$(mktemp -d)
pkg=$(mktemp -d "$root/tmp/y700-platform-upgrade.XXXXXXXX")
trap 'rm -f -- "$pkg/platform.deb" "$work/before" "$work/after" "$work/expected"; rmdir -- "$pkg" "$work"' EXIT
packages() {
    chroot "$root" dpkg-query -W '-f=${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
        sed -n 's/^installed\t//p' | sort
}
packages > "$work/before"
echo "e4cf4234ecc66c2f8a0680dd66ed60b64cd5013b38a9d9a3b6e1ab7ec5eec3dc  $work/before" | sha256sum --strict -c -
test "$(wc -l <"$work/before")" = 1112
sed 's/^y700-platform\t0.1.0~dev11\.1\tall$/y700-platform\t0.1.0~dev12.1\tall/' "$work/before" > "$work/expected"
grep -Fxq $'y700-platform\t0.1.0~dev12.1\tall' "$work/expected"
install -m644 -- "$archive" "$pkg/platform.deb"
chroot "$root" dpkg -i "${pkg#"$root"}/platform.deb"
chroot "$root" systemctl --root=/ enable y700-speaker-calibration.service
test "$(chroot "$root" systemctl is-enabled y700-speaker-calibration.service)" = enabled
test -z "$(chroot "$root" dpkg --audit)"
test -z "$(chroot "$root" dpkg -V y700-platform)"
chroot "$root" apt-get check
packages > "$work/after"
cmp "$work/expected" "$work/after"
test -x "$root/usr/libexec/y700-ssc/import-calibration"
for row in \
    '3cb6a66c10a705c4fc46030e70de4c65340258613ba3ca64c4400b3a247ef2b7 /usr/libexec/y700-speaker-calibration' \
    '516fee7ee265ab9148d451c1b127d8fa74374032bc42686577bfa8003904b4da /usr/lib/systemd/system/y700-speaker-calibration.service' \
    '3147a57e096b84286a392f23a35ec2fbf73bd969565d5359e50dbbad16caa8c7 /usr/share/alsa/ucm2/Lenovo-Y700/HiFi.conf'; do
    read -r digest path <<< "$row"
    test "$(chroot "$root" dpkg-query -S "$path")" = "y700-platform: $path"
    printf '%s  %s\n' "$digest" "$root$path" | sha256sum --strict -c -
done
test -x "$root/usr/libexec/y700-speaker-calibration"
test ! -e "$root/run/y700-speaker-calibration"
chroot "$root" dpkg-query -W '-f=${binary:Package}\t${Version}\t${Architecture}\n' > "$root/var/lib/y700/build/packages.tsv"
printf 'package_count=1112\npackage_digest=%s\n' "$(sha256sum "$work/after" | cut -d' ' -f1)"
echo DEV12P1_SINGLE_PACKAGE_UPGRADE_PASS
