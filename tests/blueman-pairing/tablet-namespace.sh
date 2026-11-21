#!/usr/bin/env bash
set -euo pipefail
stage=${1:?private staging directory}
version=${2:?expected Blueman version}
[[ $stage =~ ^/var/tmp/y700-blueman-tablet\.[a-zA-Z0-9]{8}$ ]]
for kind in mnt net pid; do
    current=$(readlink "/proc/self/ns/$kind")
    test "$current" != "$(cat "$stage/host.$kind")"
    printf '%s\n' "$current" > "$stage/test.$kind"
done
mount --make-rprivate /
mount --rbind / /
mount -o remount,bind,ro /
findmnt -nr -o OPTIONS --target / | grep -Eq '(^|,)ro(,|$)'
if [[ -d "$stage/manager" ]]; then
    for file in /usr/lib/python3/dist-packages/blueman/main/Manager.py /usr/share/blueman/ui/manager-main.ui; do
        mount --bind "$stage/manager/${file##*/}" "$file"
        mount -o remount,bind,ro "$file"
    done
fi
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /tmp
mount -t tmpfs -o mode=755,nosuid,nodev tmpfs /run
mount -t tmpfs -o mode=555,ro,nosuid,nodev,noexec tmpfs /sys
mount -t tmpfs -o mode=755,nosuid,noexec tmpfs /dev
mount -t tmpfs -o mode=755,nosuid,nodev tmpfs /home
if [[ -d /var/lib/bluetooth ]]; then
    mount -t tmpfs -o mode=700,nosuid,nodev,noexec tmpfs /var/lib/bluetooth
fi
for spec in null:1:3 zero:1:5 full:1:7 random:1:8 urandom:1:9 tty:5:0; do
    IFS=: read -r device major minor <<< "$spec"
    mknod -m666 "/dev/$device" c "$major" "$minor"
done
mkdir -m1777 /dev/shm
ln -s /proc/self/fd /dev/fd
ln -s /proc/self/fd/0 /dev/stdin
ln -s /proc/self/fd/1 /dev/stdout
ln -s /proc/self/fd/2 /dev/stderr
test ! -e /sys/class/bluetooth
test ! -e /dev/rfkill
test ! -e /dev/dri
test ! -S /run/dbus/system_bus_socket
test ! -e /home/y700
if find /var/lib/bluetooth -mindepth 1 -print -quit 2>/dev/null | grep -q .; then exit 1; fi
install -d -o y700 -g y700 -m700 /run/blueman-pairing
install -d -m755 /run/blueman-pairing/tools
cp -a "$stage/bundle/." /run/blueman-pairing/tools/
echo 'BLUEMAN_TABLET_ISOLATION private_mount_net_pid=1 root_readonly=1 live_home_hidden=1 radio_and_drm_hidden=1 real_system_bus_hidden=1'
exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C \
    BLUEMAN_TOUCH_ENTRY=1 PYTHONPATH=/run/blueman-pairing/tools/python \
    setpriv --reuid=y700 --regid=y700 --clear-groups --no-new-privs --inh-caps=-all --bounding-set=-all \
    /bin/bash /run/blueman-pairing/tools/run-session.sh "$version"
