#!/bin/bash
set -euo pipefail
stage=$(realpath -e "$1")
[[ $$ == 1 && $stage =~ ^/run/y700-thunar-xi\.[[:alnum:]]{8}$ && $(findmnt -nro FSTYPE -T "$stage") == tmpfs ]]
[[ $(findmnt -nro PROPAGATION /) == private ]]
r=$stage/root
mkdir -p "$r"
mount -t tmpfs -o size=180m,mode=755 tmpfs "$r"
mkdir -p "$r"/{usr,sys,dev/shm,etc,proc,run,tmp/.X11-unix,home,root,qa,var/lib/dbus,var/log,var/tmp,var/cache/fontconfig}
mount --bind /usr "$r/usr"
mount -o remount,bind,ro,nosuid,nodev "$r/usr"
for n in bin sbin lib; do ln -s usr/$n "$r/$n"; done
for n in fonts xdg dbus-1 alternatives X11; do cp -a "/etc/$n" "$r/etc/"; done
printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'y700:x:1000:1000:Test:/home/y700:/bin/bash' >"$r/etc/passwd"
printf '%s\n' 'root:x:0:' 'y700:x:1000:' >"$r/etc/group"
for n in messagebus polkitd systemd-timesync systemd-network; do getent passwd "$n" >>"$r/etc/passwd"; getent group "$n" >>"$r/etc/group"; done
getent group netdev >>"$r/etc/group"
printf '%s\n' 'passwd: files' 'group: files' 'hosts: files' >"$r/etc/nsswitch.conf"
echo '127.0.0.1 localhost' >"$r/etc/hosts"
mount -t proc -o nosuid,nodev,noexec proc "$r/proc"
mount -t tmpfs -o ro,nosuid,nodev,noexec tmpfs "$r/proc/sys"
for pair in null:3 zero:5 urandom:9 random:8; do mknod -m666 "$r/dev/${pair%:*}" c 1 "${pair#*:}"; done
ln -s /proc/self/fd "$r/dev/fd"
chmod 1777 "$r"/{tmp,tmp/.X11-unix,dev/shm,var/tmp}
install -d -m700 -o 1000 -g 1000 "$r"/{home/y700,run/user/1000}
cp -a "$stage/data/." "$r/qa/"
if [[ -f $r/qa/candidate ]]; then
    mount --bind "$r/qa/candidate" "$r/usr/bin/thunar"
    mount -o remount,bind,ro,nosuid,nodev "$r/usr/bin/thunar"
fi
chroot "$r" dbus-uuidgen >"$r/etc/machine-id"
ln -s /etc/machine-id "$r/var/lib/dbus/machine-id"
exec env -i PATH=/qa:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin DISPLAY=:73 GDK_SCALE=2 LANG=C.UTF-8 chroot "$r" bash /qa/session.sh
