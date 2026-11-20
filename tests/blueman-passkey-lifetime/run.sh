#!/usr/bin/env bash
# Run the packaged applet on a read-only ext4 base and private GTK/BlueZ sessions.
set -euo pipefail
if [[ $EUID != 0 || ( $# != 4 && $# != 6 ) ]]; then
    echo 'Usage as root: run.sh DEV12.6.ext4 ARM64_X11_DEB_DIR DBUSMOCK.deb ARM64_UV [Y7002.deb SHA256]' >&2
    exit 2
fi
if [[ ${BLUEMAN_LIFETIME_NS:-} != 1 ]]; then
    exec unshare --mount --propagation private --net --ipc --pid --fork --kill-child --mount-proc \
        env BLUEMAN_LIFETIME_NS=1 bash "$0" "$@"
fi
here=$(cd "$(dirname "$0")" && pwd -P)
base=$(realpath -e "$1")
printf '%s  %s\n' 74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd "$base" | sha256sum --strict -c -
work=$(mktemp -d /var/tmp/blueman-lifetime.XXXXXXXX)
root=$work/root
cleanup() {
    if mountpoint -q "$root"; then umount -R "$root"; fi
    if mountpoint -q "$work/lower"; then umount "$work/lower"; fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir "$work"/{root,lower,upper,work}
mount -o ro,noload,loop "$base" "$work/lower"
mount -t overlay overlay -o "lowerdir=$work/lower,upperdir=$work/upper,workdir=$work/work" "$root"
for dir in sys dev run; do mount -t tmpfs -o nosuid,mode=755 tmpfs "$root/$dir"; done
mount -t tmpfs -o nosuid,nodev,mode=1777 tmpfs "$root/tmp"
mount -t proc proc "$root/proc"
for dev in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$root/dev/${dev%:*}" c 1 "${dev#*:}"; done
ln -s /proc/self/fd "$root/dev/fd"
mkdir -m1777 "$root/dev/shm" "$root/tmp/.X11-unix"
for deb in "$2"/{xvfb,xdotool,libxdo3}_*.deb "$3"; do dpkg-deb -x "$deb" "$root"; done
bundle=$root/opt/blueman-pairing
install -d "$bundle"
install -m755 "$4" "$bundle/uv"
install -m644 "$here/../blueman-pairing/run-session.sh" "$bundle/"
install -m644 "$here/../blueman-pairing/probe.py" "$bundle/pairing.py"
install -m644 "$here/probe.py" "$bundle/"
version=2.4.4-1+y7001
[[ $(chroot "$root" dpkg-query -W -f='${Version}' blueman) == "$version" ]]
if [[ $# == 6 ]]; then
    [[ $6 =~ ^[0-9a-f]{64}$ ]]
    printf '%s  %s\n' "$6" "$5" | sha256sum --strict -c -
    version=2.4.4-1+y7002
    [[ $(dpkg-deb -f "$5" Version) == "$version" && $(dpkg-deb -f "$5" Package) == blueman ]]
    install -m644 "$5" "$root/run/candidate.deb"
    chroot "$root" env SYSTEMD_OFFLINE=1 dpkg -i /run/candidate.deb
    audit=$(chroot "$root" dpkg --audit)
    verification=$(chroot "$root" dpkg -V blueman)
    [[ -z $audit && -z $verification ]]
fi
chroot "$root" install -d -m700 -o y700 -g y700 /run/blueman-pairing
timeout -k 4 180 unshare --mount --propagation private --pid --fork --kill-child --mount-proc="$root/proc" \
    chroot "$root" /usr/sbin/runuser -u y700 -- bash /opt/blueman-pairing/run-session.sh "$version"
