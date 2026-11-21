#!/bin/bash
set -euo pipefail
ulimit -c 0
cd "$1"
stage=$PWD
source ./profiles.sh
ram_profile "$3"
helper=$(realpath -e "$2")
[[ $$ == 1 && $(findmnt -nro PROPAGATION /) == private ]]
for ns in mnt pid net ipc; do
    [[ $(readlink "/proc/self/ns/$ns") != "$(cat "host-$ns")" ]]
done
mkdir squash lower changes root
mount -t squashfs -o ro,loop,nosuid,nodev,noexec carrier squash
[[ -f squash/root.ext4 && $(stat -c %s squash/root.ext4) == 6442450944 ]]
printf '%s  squash/root.ext4\n' "$root_sha" | sha256sum --strict -c
mount -t ext4 -o loop,ro,noload,nosuid,nodev squash/root.ext4 lower
mount -t tmpfs -o size=512m,mode=755,nosuid,nodev tmpfs changes
mkdir changes/{upper,work}
mount -t overlay overlay -o "lowerdir=$stage/lower,upperdir=$stage/changes/upper,workdir=$stage/changes/work,nosuid,nodev" root
[[ $(findmnt -nro OPTIONS -T lower) == ro,* && $(findmnt -nro OPTIONS -T squash) == ro,* ]]
for path in dev sys run tmp; do
    opts=size=128m,mode=755,nosuid,nodev
    case $path in
        dev) opts=size=4m,mode=755,nosuid ;;
        sys) opts=size=4k,mode=555,ro,nosuid,nodev,noexec ;;
        tmp) opts=size=128m,mode=1777,nosuid,nodev ;;
    esac
    mount -t tmpfs -o "$opts" tmpfs "root/$path"
done
mount -t proc -o nosuid,nodev,noexec proc root/proc
mount -t tmpfs -o ro,nodev,nosuid,noexec tmpfs root/proc/sys
for spec in 'null 3' 'zero 5' 'random 8' 'urandom 9'; do
    read -r node minor <<<"$spec"
    mknod -m666 "root/dev/$node" c 1 "$minor"
done
ln -s /proc/self/fd root/dev/fd
install -d -m1777 root/dev/shm root/tmp/.X11-unix
install -d -m755 root/qa/{bin,lib}
install -m755 "$helper/bin/"{Xvfb,xdotool} root/qa/bin/
install -m644 "$helper/lib/aarch64-linux-gnu/libxdo.so.3" root/qa/lib/
install -m644 desktop.sh thunar.sh root/qa/
if [[ $release == dev12.8 || $release == dev12.9 || $release == dev12.10 ]]; then
    install -m755 "$(command -v uv)" root/qa/bin/uv
    install -m644 brightness.py probe.py root/qa/
fi
chroot root dbus-uuidgen >root/etc/machine-id
user_id=$(chroot root id -u y700)
group_id=$(chroot root id -g y700)
[[ $user_id != 0 && $group_id != 0 && ! -e lower/home/y700/Y700-RAM-check ]]
install -d -m700 -o "$user_id" -g "$group_id" "root/run/user/$user_id"
LC_ALL=C chroot root dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
    sed -n 's/^installed\t//p' | LC_ALL=C sort >inventory
printf '%s  inventory\n' "$package_sha" | sha256sum --strict -c
[[ $(wc -l <inventory) == "$package_count" ]]
echo "RAM_USERSPACE machine=$(uname -m) kernel=$(uname -r) packages=$package_count root=overlay upper=tmpfs lower=ext4-ro carrier=squashfs-ro"
if [[ -f check-lifecycle.sh ]]; then
    [[ $release == dev12.10 ]]
    install -d -m700 root/run/wifi-update
    cp -r -- SHA256SUMS candidate stock check-lifecycle.sh root/run/wifi-update/
    mount -t sysfs -o ro,nodev,nosuid,noexec sysfs root/sys
    chroot root setpriv --bounding-set=-sys_module,-sys_admin,-sys_boot,-sys_rawio,-sys_time \
        env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C DEBIAN_FRONTEND=noninteractive \
        bash /run/wifi-update/check-lifecycle.sh
    umount root/sys
    exit
fi
chroot root setpriv --reuid="$user_id" --regid="$group_id" --clear-groups --no-new-privs env -i \
    PATH=/qa/bin:/usr/local/bin:/usr/bin:/bin LD_LIBRARY_PATH=/qa/lib HOME=/home/y700 USER=y700 LOGNAME=y700 \
    XDG_RUNTIME_DIR="/run/user/$user_id" XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 XDG_SESSION_DESKTOP=xfce \
    LC_ALL=C.UTF-8 GDK_BACKEND=x11 GDK_SCALE=2 NO_AT_BRIDGE=0 DISPLAY=:73 \
    dbus-run-session -- bash /qa/desktop.sh "$release"
[[ -d changes/upper/home/y700/Y700-RAM-check/hello && ! -e lower/home/y700/Y700-RAM-check ]]
echo 'RAM_USERSPACE new_folder=tmpfs-upper-only'
