#!/usr/bin/env bash
# Run Debian ARM64 upowerd against a private system bus and synthetic power supplies.
set -euo pipefail
[[ $EUID == 0 && ( $# == 2 || $# == 4 ) ]] || {
    echo 'Usage (root): run.sh SEALED_DEV12.6.ext4 FETCHED_ARCHIVES [POWER_DESKTOP_ARCHIVES ARM64_X11_TEST_USR]' >&2; exit 2;
}
if [[ ${UP_TEST_PRIVATE:-} != 1 ]]; then
    exec unshare --mount --propagation private --net --pid --fork --ipc env UP_TEST_PRIVATE=1 bash "$0" "$@"
fi
here=$(cd "$(dirname "$0")" && pwd -P)
base=$(realpath -e "$1")
archives=$(realpath -e "$2")
export LC_ALL=C SYSTEMD_OFFLINE=1
printf '%s  %s\n' 74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd "$base" | sha256sum --strict -c -
(cd "$archives"; echo 'dcb94d31f26d21bf770419559fcd332898376238acc251784f0b6a0306f5ad41  SHA256SUMS' | sha256sum --strict -c -; sha256sum --strict -c SHA256SUMS)
work=$(mktemp -d /var/tmp/y700-upower.XXXXXXXX)
root=$work/root
cleanup() {
    if mountpoint -q "$root"; then umount -R "$root"; fi
    if mountpoint -q "$work/lower"; then umount "$work/lower"; fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir "$work"/{lower,upper,work,root}
mount -o ro,noload,loop "$base" "$work/lower"
mount -t overlay overlay -o "lowerdir=$work/lower,upperdir=$work/upper,workdir=$work/work" "$root"
mount -t proc -o nosuid,noexec,nodev proc "$root/proc"
for dir in run dev sys; do mount -t tmpfs -o nosuid,noexec,mode=755 tmpfs "$root/$dir"; done
desktop_uid=$(chroot "$root" id -u y700)
desktop_gid=$(chroot "$root" id -g y700)
chown "$desktop_uid:$desktop_gid" "$root/sys"
for pair in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$root/dev/${pair%:*}" c 1 "${pair#*:}"; done
ln -s /proc/self/fd "$root/dev/fd"
install -d "$root/run/input"
while read -r _ archive; do cp -- "$archives/$archive" "$root/run/input/"; done < "$archives/SHA256SUMS"
if [[ $# == 4 ]]; then
    repo=$(cd "$here/../.." && pwd -P)
    "${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python \
        "$repo/scripts/repair-inputs.py" verify "$3" "${Y700_TRAY_LAYER_LOCK:-$repo/config/power-desktop.lock.json}"
    cp "$3"/{xfce4-power-manager*,y700-power-desktop}_*.deb "$root/run/input/"
    for bin in Xvfb xdotool; do install -m755 "$4/bin/$bin" "$root/usr/bin/$bin"; done
    install -m644 "$4/lib/aarch64-linux-gnu/libxdo.so.3" "$root/usr/lib/aarch64-linux-gnu/"
    install -m644 "$here/tray.sh" "$root/run/tray.sh"
    install -m644 "$here/../wifi-chooser/xfce4-panel.xml" "$root/run/panel.xml"
    install -d -m1777 "$root/tmp/.X11-unix" "$root/dev/shm"
fi
[[ ! -e $root/usr/sbin/policy-rc.d && ! -L $root/usr/sbin/policy-rc.d ]]
printf '#!/bin/sh\nexit 101\n' > "$root/usr/sbin/policy-rc.d"; chmod 755 "$root/usr/sbin/policy-rc.d"
chroot "$root" sh -ec 'export DEBIAN_FRONTEND=noninteractive; dpkg -i /run/input/*.deb; apt-get check; test -z "$(dpkg --audit)"; dbus-uuidgen > /etc/machine-id'
if [[ -n ${Y700_TRAY_CANDIDATE:-} ]]; then
    [[ $# == 4 && ${Y700_TRAY_CANDIDATE_SHA256:-} =~ ^[0-9a-f]{64}$ ]]
    printf '%s  %s\n' "$Y700_TRAY_CANDIDATE_SHA256" "$Y700_TRAY_CANDIDATE" | sha256sum --strict -c -
    [[ $(dpkg-deb -f "$Y700_TRAY_CANDIDATE" Package) == xfce4-power-manager ]]
    install -m644 "$Y700_TRAY_CANDIDATE" "$root/run/input/candidate.deb"
    chroot "$root" sh -ec 'dpkg -i /run/input/candidate.deb; apt-get check; test -z "$(dpkg --audit)"'
fi
[[ $(chroot "$root" dpkg --print-architecture) == arm64 ]]
install -m 644 "$here/probe.sh" "$root/run/probe.sh"
install -d -o "$desktop_uid" -g "$desktop_gid" -m700 "$root/run/up-test"
# Bus-activated desktop helpers can outlive the probe. A dedicated PID namespace
# releases their file descriptors before the builder unmounts the private /dev.
timeout -k 3s 230s unshare --mount --propagation private --pid --fork --kill-child --mount-proc="$root/proc" \
    chroot --userspec="$desktop_uid:$desktop_gid" "$root" /usr/bin/env -i \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C HOME=/run/up-test SYSTEMD_DEVICE_VERIFY_SYSFS=0 \
    Y700_TRAY_SCREEN="${Y700_TRAY_SCREEN:-1024x768}" GDK_SCALE="${GDK_SCALE:-1}" Y700_TRAY_PANEL_SIZE="${Y700_TRAY_PANEL_SIZE:-40}" \
    Y700_TRAY_EXPECT_PRIMARY="${Y700_TRAY_EXPECT_PRIMARY:-auto}" Y700_TRAY_EXPECT_CONTEXT="${Y700_TRAY_EXPECT_CONTEXT:-visible}" \
    Y700_TRAY_CHECK_RETURN="${Y700_TRAY_CHECK_RETURN:-0}" \
    /bin/bash /run/probe.sh
