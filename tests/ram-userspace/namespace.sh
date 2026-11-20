#!/bin/bash
set -euo pipefail
ulimit -c 0
cd "$1"
stage=$PWD
helper=$(realpath -e "$2")
[[ $$ == 1 && $(findmnt -nro PROPAGATION /) == private ]]
for ns in mnt pid net ipc; do
    [[ $(readlink "/proc/self/ns/$ns") != "$(cat "host-$ns")" ]]
done
mkdir squash lower changes root
mount -t squashfs -o ro,loop,nosuid,nodev,noexec carrier squash
[[ -f squash/root.ext4 && $(stat -c %s squash/root.ext4) == 6442450944 ]]
printf '%s  squash/root.ext4\n' 74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd | sha256sum --strict -c
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
install -m644 desktop.sh root/qa/
chroot root dbus-uuidgen >root/etc/machine-id
user_id=$(chroot root id -u y700)
group_id=$(chroot root id -g y700)
[[ $user_id != 0 && $group_id != 0 && ! -e lower/home/y700/Y700-RAM-check ]]
install -d -m700 -o "$user_id" -g "$group_id" "root/run/user/$user_id"
LC_ALL=C chroot root dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
    sed -n 's/^installed\t//p' | LC_ALL=C sort >inventory
printf '%s  inventory\n' a5f46346523f60efb2545e290d209372daa983b094e42c37e7ced2cdb97b3d98 | sha256sum --strict -c
[[ $(wc -l <inventory) == 1115 ]]
echo "RAM_USERSPACE machine=$(uname -m) kernel=$(uname -r) packages=1115 root=overlay upper=tmpfs lower=ext4-ro carrier=squashfs-ro"
chroot root setpriv --reuid="$user_id" --regid="$group_id" --clear-groups --no-new-privs env -i \
    PATH=/qa/bin:/usr/local/bin:/usr/bin:/bin LD_LIBRARY_PATH=/qa/lib HOME=/home/y700 USER=y700 LOGNAME=y700 \
    XDG_RUNTIME_DIR="/run/user/$user_id" XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 XDG_SESSION_DESKTOP=xfce \
    LC_ALL=C.UTF-8 GDK_BACKEND=x11 GDK_SCALE=2 NO_AT_BRIDGE=0 DISPLAY=:73 \
    dbus-run-session -- bash /qa/desktop.sh
[[ -d changes/upper/home/y700/Y700-RAM-check/hello && ! -e lower/home/y700/Y700-RAM-check ]]
echo 'RAM_USERSPACE new_folder=tmpfs-upper-only'
