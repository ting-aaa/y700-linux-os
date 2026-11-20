#!/bin/bash
set -euo pipefail
[[ $# == 2 && $$ == 1 && $(findmnt -nro PROPAGATION /) == private ]]
ulimit -c 0
stage=$(realpath -e "$1")
helpers=$(realpath -e "$2")
[[ $(findmnt -nro FSTYPE -T "$stage") == tmpfs ]]
r=$stage/root
mkdir "$r"
mount -t tmpfs -o size=160m,mode=755 tmpfs "$r"
mkdir -p "$r"/{usr,sys/class,dev/shm,etc,proc,run,tmp/.X11-unix,home,root,qa/bin,qa/lib,var/lib/dbus}
mount --bind /usr "$r/usr"
mount -o remount,bind,ro,nosuid,nodev "$r/usr"
for path in bin sbin lib; do ln -s "usr/$path" "$r/$path"; done
for name in backlight drm; do ln -s "/home/y700/case/sys/class/$name" "$r/sys/class/$name"; done
for path in fonts xdg dbus-1; do cp -a "/etc/$path" "$r/etc/"; done
mkdir -p "$r/etc/alternatives"
ln -s "$(readlink -e /usr/bin/awk)" "$r/etc/alternatives/awk"
printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' 'y700:x:1000:1000:Test:/home/y700:/bin/sh' >"$r/etc/passwd"
printf '%s\n' 'root:x:0:' 'y700:x:1000:' >"$r/etc/group"
printf '%s\n' 'passwd: files' 'group: files' 'hosts: files' >"$r/etc/nsswitch.conf"
echo '127.0.0.1 localhost' >"$r/etc/hosts"
chroot "$r" dbus-uuidgen >"$r/etc/machine-id"
ln -s /etc/machine-id "$r/var/lib/dbus/machine-id"
mount -t proc -o nosuid,nodev,noexec proc "$r/proc"
for pair in null:3 zero:5 urandom:9 random:8; do mknod -m666 "$r/dev/${pair%:*}" c 1 "${pair#*:}"; done
ln -s /proc/self/fd "$r/dev/fd"
chmod 1777 "$r"/{tmp,tmp/.X11-unix,dev/shm}
install -d -m700 -o 1000 -g 1000 "$r"/{home/y700,run/user/1000}
install -m755 "$helpers/bin/"{Xvfb,xdotool} "$r/qa/bin/"
install -m644 "$helpers/lib/aarch64-linux-gnu/libxdo.so.3" "$r/qa/lib/"
cp -r "$stage/tests" "$r/qa/"
chmod -R a+rX "$r/qa/tests"
exec chroot "$r" setpriv --reuid=1000 --regid=1000 --clear-groups --no-new-privs env -i \
  PATH=/qa/bin:/usr/local/bin:/usr/bin:/bin LD_LIBRARY_PATH=/qa/lib HOME=/home/y700 USER=y700 LOGNAME=y700 \
  XDG_RUNTIME_DIR=/run/user/1000 XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 XDG_SESSION_ID=c42 \
  GDK_BACKEND=x11 GDK_SCALE=2 DISPLAY=:76 LANG=C.UTF-8 UV_OFFLINE=1 PYTHONDONTWRITEBYTECODE=1 \
  bash -ec '
    cd "$HOME"
    test ! -e /run/dbus/system_bus_socket && test ! -e /dev/input && test ! -e /dev/dri
    test -z "$(find /dev -type b -print -quit)"
    mkdir -m700 case
    Xvfb "$DISPLAY" -screen 0 2560x1600x24 -nolisten tcp >xvfb.log 2>&1 &
    xserver=$!
    trap "kill $xserver 2>/dev/null || true" EXIT
    for i in {1..50}; do if xdpyinfo >/dev/null 2>&1; then break; fi; sleep .1; done
    xdpyinfo >/dev/null || { cat xvfb.log; exit 1; }
    dbus-run-session -- bash -ec "export DBUS_SYSTEM_BUS_ADDRESS=\$DBUS_SESSION_BUS_ADDRESS; unset DBUS_SESSION_BUS_ADDRESS; exec dbus-run-session -- uv run --no-project --offline --python /usr/bin/python3 python -B /qa/tests/brightness/ambient-ui.py"
  '
