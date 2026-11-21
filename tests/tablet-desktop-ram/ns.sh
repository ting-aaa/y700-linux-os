#!/bin/bash
set -euo pipefail
ulimit -c 0
cd "$1"
stage=$PWD
[[ $$ == 1 && $(stat -c '%u:%a' .) == 0:700 && $(findmnt -nro PROPAGATION /) == private ]]
for ns in mnt pid net ipc; do [[ $(readlink /proc/self/ns/$ns) != "$(cat "host-$ns")" ]]; done
sha=6155d87d5d5b9d5557e86362f09fb17328aef200861e94eb292a669c35659c7c
[[ $(stat -c %s root.ext4) == 6442450944 ]]
echo "$sha  root.ext4" | sha256sum --strict -c -
echo "DEV1213_RAW sha256=$sha allocated_mib=$(($(stat -c %b root.ext4)/2048)) memory_available_kib=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
mkdir lower changes root
mount -t ext4 -o loop,ro,noload,nosuid,nodev root.ext4 lower
[[ $(findmnt -nro OPTIONS -T lower) == ro,* ]]
mount -t tmpfs -o size=320m,mode=755,nosuid,nodev tmpfs changes
mkdir changes/{upper,work}
mount -t overlay overlay -o "lowerdir=$stage/lower,upperdir=$stage/changes/upper,workdir=$stage/changes/work,nosuid,nodev" root
for path in dev sys run tmp; do
    opts=size=128m,mode=755,nosuid,nodev
    case $path in dev) opts=size=4m,mode=755,nosuid;; sys) opts=size=4k,mode=555,ro,nosuid,nodev,noexec;; tmp) opts=size=128m,mode=1777,nosuid,nodev;; esac
    mount -t tmpfs -o "$opts" tmpfs "root/$path"
done
mount -t proc -o nosuid,nodev,noexec proc root/proc
mount -t tmpfs -o ro,nodev,nosuid,noexec tmpfs root/proc/sys
for item in null:3 zero:5 random:8 urandom:9; do mknod -m666 "root/dev/${item%:*}" c 1 "${item#*:}"; done
ln -s /proc/self/fd root/dev/fd
install -d -m1777 root/dev/shm root/tmp/.X11-unix
install -d -m755 root/qa/{bin,lib}
install -m755 tools/{Xvfb,xdotool,uv} root/qa/bin/
install -m644 tools/libxdo.so.3 root/qa/lib/
install -m644 tablet-apps.sh chooser.py board-chooser.py virtual-shutter.py desktop.sh root/qa/
# Only the test process preloads these virtual-camera libraries.
install -m755 tools/{libcamera,libcamera-base}.so.0.7.2 tools/libyuv.so.0 root/qa/lib/
ln -s libcamera-base.so.0.7.2 root/qa/lib/libcamera-base.so.0.7
ln -s libcamera.so.0.7.2 root/qa/lib/libcamera.so.0.7
install -d root/usr/share/libcamera/pipeline/virtual
sed -e '/^  frames:$/,+1c\  test_pattern: "lines"' -e 's/Synthetic red and green patches/sc202cs/' \
    -e 's/Synthetic colour bars/hi1339/' -e 's/Synthetic diagonal lines/s5k4h7/' \
    -e '/^"\/fixture\/unknown/,$d' virtual-cameras.yaml > root/usr/share/libcamera/pipeline/virtual/virtual.yaml
[[ $(chroot root passwd -S y700 | cut -d' ' -f2) == L && $(chroot root id -u y700) == 1000 ]]
[[ ! -s lower/etc/machine-id && ! -e lower/etc/y700/user-configured ]]
chroot root dbus-uuidgen >root/etc/machine-id
install -d -m700 -o 1000 -g 1000 root/run/user/1000
. lower/etc/os-release
[[ $IMAGE_VERSION == dev12.13 && $(chroot root dpkg-query -W -f='${Version}' y700-platform) == '0.1.0~dev12.8+gpu1.2' ]]
printf '%s  %s\n' 3d77058cde509e6f3256f332d4a2469d9448490ce6628001defdadd08711b5b8 lower/var/lib/y700/build/packages.tsv | sha256sum --strict -c -
chroot root dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' | sed -n 's/^installed\t//p' | LC_ALL=C sort > inventory
[[ $(wc -l <inventory) == 1241 ]]
printf '%s  inventory\n' 5f991636f274f7d21c38f4eaf4e119d6491a1c7c901fdb818518548333574098 | sha256sum --strict -c -
echo 'DEV1213_ROOT release=dev12.13 platform=0.1.0~dev12.8+gpu1.2 packages=1241 ext4_readonly=1 tmpfs_writable=1'
chroot root setpriv --reuid=1000 --regid=1000 --clear-groups --no-new-privs env -i \
 PATH=/qa/bin:/usr/local/bin:/usr/bin:/bin LD_LIBRARY_PATH=/qa/lib HOME=/home/y700 USER=y700 LOGNAME=y700 \
 XDG_RUNTIME_DIR=/run/user/1000 XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 XDG_SESSION_DESKTOP=xfce \
 XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg UV_OFFLINE=1 UV_PYTHON_DOWNLOADS=never \
 GDK_BACKEND=x11 GDK_SCALE=2 DISPLAY=:73 NO_AT_BRIDGE=0 LC_ALL=C.UTF-8 \
 dbus-run-session -- bash /qa/desktop.sh dev12.13
[[ ! -s lower/etc/machine-id ]]
echo 'DEV1213_DESKTOP_PASS locked_generic_account=1 private_session=1 camera_buffers=0'
