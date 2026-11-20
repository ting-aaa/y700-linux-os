#!/bin/bash
# Private desktop on the tablet CPU; expose the installed userspace and read-only sysfs.
set -euo pipefail
[[ $# == 3 && $$ == 1 && $(findmnt -nro PROPAGATION /) == private ]]
ulimit -c 0
stage=$(realpath -e "$1")
helpers=$(realpath -e "$2")
[[ $(findmnt -nro FSTYPE -T "$stage") == tmpfs ]]
r=$stage/root
mkdir "$r"
mount -t tmpfs -o size=180m,mode=755 tmpfs "$r"
mkdir -p "$r"/{usr,sys,dev/shm,etc,proc,run,tmp/.X11-unix,home,root,qa/bin,qa/lib,var/lib/dbus,var/lib/upower}
mount --bind /usr "$r/usr"
mount -o remount,bind,ro,nosuid,nodev "$r/usr"
mount --bind /sys "$r/sys"
mount -o remount,bind,ro,nosuid,noexec,nodev "$r/sys"
[[ $(findmnt -nro OPTIONS -T "$r/sys") == ro,* ]]
for name in bin sbin lib; do ln -s "usr/$name" "$r/$name"; done
for path in fonts xdg dbus-1 UPower; do cp -a "/etc/$path" "$r/etc/"; done
mkdir -p "$r/etc/alternatives"
ln -s "$(readlink -e /usr/bin/awk)" "$r/etc/alternatives/awk"
cp /etc/X11/Xsession.d/62y700_battery_indicator "$r/qa/board-default"
printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' 'y700:x:1000:1000:Test:/home/y700:/bin/sh' >"$r/etc/passwd"
printf '%s\n' 'root:x:0:' 'y700:x:1000:' >"$r/etc/group"
printf '%s\n' 'passwd: files' 'group: files' 'hosts: files' >"$r/etc/nsswitch.conf"
printf '%s\n' '127.0.0.1 localhost' >"$r/etc/hosts"
chroot "$r" dbus-uuidgen >"$r/etc/machine-id"
ln -s /etc/machine-id "$r/var/lib/dbus/machine-id"
mount -t proc -o nosuid,nodev,noexec proc "$r/proc"
for pair in null:3 zero:5 urandom:9 random:8; do mknod -m666 "$r/dev/${pair%:*}" c 1 "${pair#*:}"; done
ln -s /proc/self/fd "$r/dev/fd"
chmod 1777 "$r"/{tmp,tmp/.X11-unix,dev/shm}
install -d -m700 -o 1000 -g 1000 "$r"/{home/y700,run/user/1000,var/lib/upower}
install -m755 "$helpers/bin/"{Xvfb,xdotool} "$r/qa/bin/"
install -m644 "$helpers/lib/aarch64-linux-gnu/libxdo.so.3" "$r/qa/lib/"
install -m644 "$stage/"{session.sh,board-readings.sh} "$r/qa/"
install -m644 "$stage/tray.sh" "$r/run/tray.sh"
install -m644 "$stage/panel.xml" "$r/run/panel.xml"
exec chroot "$r" setpriv --reuid=1000 --regid=1000 --clear-groups --no-new-privs env -i \
    PATH=/qa/bin:/usr/sbin:/usr/bin:/bin LD_LIBRARY_PATH=/qa/lib HOME=/home/y700 USER=y700 LOGNAME=y700 \
    LC_ALL=C.UTF-8 XDG_RUNTIME_DIR=/run/user/1000 XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 GDK_SCALE=2 \
    GDK_BACKEND=x11 Y700_TRAY_EXPECT_PRIMARY="$3" bash /qa/session.sh
