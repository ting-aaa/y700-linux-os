#!/bin/bash
# Run only as PID 1 in a new mount, PID, IPC and network namespace.
set -euo pipefail
stage=$(realpath -e "$1")
base=$(realpath -e "$2")
helpers=$(realpath -e "$3")
[[ $$ == 1 && $(id -u) == 0 && $(findmnt -nro PROPAGATION /) == private ]]
[[ $(findmnt -nro FSTYPE -T "$stage") == tmpfs ]]
for ns in pid mnt net ipc; do
    test "$(readlink "/proc/self/ns/$ns")" != "$(cat "$stage/host-$ns")"
done
umask 022
mount -t tmpfs -o size=192m,mode=755 tmpfs "$stage/root"
r=$stage/root
mkdir -p "$r/"{usr,etc/pam.d,proc,dev/shm,sys,run,home,root,tmp/.X11-unix,qa,media,var/lib/dbus,var/tmp}
pkg=$stage/payload
mkdir "$pkg"
for deb in "$stage/"*.deb; do dpkg-deb -x "$deb" "$pkg"; done
for tool in Xvfb xdotool; do install -Dm755 "$helpers/bin/$tool" "$pkg/usr/bin/$tool"; done
install -Dm644 "$helpers/lib/aarch64-linux-gnu/libxdo.so.3" "$pkg/usr/lib/aarch64-linux-gnu/libxdo.so.3"
mount -t overlay overlay -o "ro,lowerdir=$pkg/usr:$base/usr" "$r/usr"
for name in bin sbin lib; do ln -s "usr/$name" "$r/$name"; done
cp -a "$pkg/etc/." "$r/etc/"
cp -a "$base/etc/fonts" "$r/etc/"
printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' 'locktest:x:47319:47319:Lock test:/home/locktest:/bin/sh' >"$r/etc/passwd"
printf '%s\n' 'root:x:0:' 'shadow:x:42:' 'locktest:x:47319:' >"$r/etc/group"
printf '%s\n' 'passwd: files' 'group: files' 'shadow: files' 'hosts: files' >"$r/etc/nsswitch.conf"
printf '%s\n' '127.0.0.1 localhost' >"$r/etc/hosts"
# Keep the archive's xfce4-screensaver PAM service and resolve its common-auth
# include against this synthetic account with Debian's native pam_unix module.
printf '%s\n' 'auth [success=1 default=ignore] pam_unix.so nullok' \
    'auth requisite pam_deny.so' 'auth required pam_permit.so' >"$r/etc/pam.d/common-auth"
touch "$r/etc/y700-private-lock-fixture"
chmod 1777 "$r/"{tmp,tmp/.X11-unix,dev/shm,var/tmp}
install -d -m700 -o 47319 -g 47319 "$r/"{home/locktest,run/user/47319}
for spec in 'null 3' 'zero 5' 'random 8' 'urandom 9'; do
    read -r node minor <<<"$spec"
    mknod -m666 "$r/dev/$node" c 1 "$minor"
done
ln -s /proc/self/fd "$r/dev/fd"
mount -t proc -o nosuid,nodev,noexec proc "$r/proc"
mount -t tmpfs -o ro,nodev,nosuid,noexec tmpfs "$r/proc/sys"
install -m644 "$stage/"{session.sh,exercise.py} "$r/qa/"
if [[ -n ${PRIVATE_LOCK_UV:-} ]]; then install -m755 "$PRIVATE_LOCK_UV" "$r/qa/uv"; fi
chroot "$r" /usr/bin/dbus-uuidgen --ensure=/etc/machine-id
chroot "$r" /bin/ln -s /etc/machine-id /var/lib/dbus/machine-id
# Only the test's new /dev, /sys, /proc, /run, home and PAM database are visible.
exec env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME=/home/locktest \
    LC_ALL=C.UTF-8 USER=locktest LOGNAME=locktest XDG_RUNTIME_DIR=/run/user/47319 \
    XDG_CURRENT_DESKTOP=XFCE DISPLAY=:73 GDK_BACKEND=x11 UV_OFFLINE=1 UV_CACHE_DIR=/run/uv \
    GDK_SCALE=2 PRIVATE_GEOMETRY=2560x1600 NO_AT_BRIDGE=0 \
    chroot "$r" /bin/bash /qa/session.sh
