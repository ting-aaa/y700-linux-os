#!/usr/bin/env bash
# Mount the selected ARM64 development root read-only and use a disposable upper layer.
set -euo pipefail
if (( $# != 5 && $# != 6 )); then
    echo 'Usage: run-arm64.sh ROOT.qcow2 SHA256 NBD_BIN_DIR X11_DEB_DIR ARM64_UV [OFFLINE_DEB_DIR]' >&2
    exit 2
fi
if [[ ${Y700_CHINESE_INPUT_NS:-} != 1 ]]; then
    test "$(id -u)" = 0
    exec unshare --mount --net --pid --fork --kill-child --mount-proc \
        env Y700_CHINESE_INPUT_NS=1 bash "$0" "$@"
fi
test "$$" = 1
fixture=$(cd -- "$(dirname -- "$0")" && pwd -P)
leaf=$(realpath -e "$1")
[[ $2 =~ ^[a-f0-9]{64}$ ]]
nbd=$(realpath -e "$3")
x11=$(realpath -e "$4")
uv=$(realpath -e "$5")
printf '%s  %s\n' "$2" "$leaf" | sha256sum -c -
work=$(mktemp -d /tmp/y700-chinese-input.XXXXXXXX)
[[ $(realpath -e "$work") =~ ^/tmp/y700-chinese-input\.[a-zA-Z0-9]{8}$ ]]
server= fuse=
cleanup() {
    # This shell is PID 1. Stop namespace-only desktop helpers before unmounting.
    for task in /proc/[0-9]*; do
        pid=${task##*/}
        if [[ $pid != 1 && $pid != "$fuse" && $pid != "$server" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    if mountpoint -q "$work/root"; then umount -Rl "$work/root"; fi
    if mountpoint -q "$work/lower"; then umount "$work/lower"; fi
    if mountpoint -q "$work/view"; then fusermount3 -u "$work/view"; fi
    for pid in "$fuse" "$server"; do
        if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    done
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir "$work"/{view,lower,upper,overlay-work,root}
"$nbd/qemu-nbd" --persistent --read-only --format=qcow2 --socket="$work/root.sock" "$leaf" &
server=$!
for _ in {1..100}; do [[ ! -S $work/root.sock ]] || break; sleep .05; done
test -S "$work/root.sock"
"$nbd/nbdfuse" -r "$work/view/root.raw" --unix "$work/root.sock" &
fuse=$!
for _ in {1..100}; do [[ ! -f $work/view/root.raw ]] || break; sleep .05; done
test "$(stat -Lc %s "$work/view/root.raw")" = 6442450944
mount -o loop,ro,noload "$work/view/root.raw" "$work/lower"
mount -t overlay overlay -o "lowerdir=$work/lower,upperdir=$work/upper,workdir=$work/overlay-work" "$work/root"
root=$work/root
mount -t proc proc "$root/proc"
mount -t tmpfs -o mode=755,nosuid tmpfs "$root/dev"
for dev in null zero random urandom tty; do
    touch "$root/dev/$dev"
    mount --bind "/dev/$dev" "$root/dev/$dev"
done
mkdir -m1777 "$root/dev/shm"
ln -s /proc/self/fd "$root/dev/fd"
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$root/tmp"
mount -t tmpfs -o mode=755,nosuid,nodev tmpfs "$root/run"
for deb in "$x11"/{xvfb,xdotool,libxdo3}_*.deb; do dpkg-deb -x "$deb" "$root"; done
if (( $# == 6 )); then
    source_debs=$(realpath -e "$6")
    install -d "$root/tmp/input-debs"
    cp -- "$source_debs/"*.deb "$source_debs/SHA256SUMS" "$root/tmp/input-debs/"
    (cd "$root/tmp/input-debs"; sha256sum --strict -c SHA256SUMS)
    chroot "$root" env SYSTEMD_OFFLINE=1 /bin/bash -c 'dpkg -i /tmp/input-debs/*.deb'
    test -z "$(chroot "$root" dpkg --audit)"
fi
chroot "$root" dpkg-query -W onboard ibus ibus-gtk3 ibus-libpinyin im-config y700-input-pinyin
install -d "$root/opt/chinese-input"
install -m755 "$uv" "$root/opt/chinese-input/uv"
install -m755 "$fixture/desktop.sh" "$root/opt/chinese-input/"
install -m644 "$fixture/"{session.sh,probe.py,gtk-target.py} "$root/opt/chinese-input/"
chroot "$root" install -d -m700 -o y700 -g y700 /run/chinese-input
echo 'CHINESE_INPUT_ISOLATION arm64_userspace=1 base_readonly=1 private_mount_net_pid=1'
status=0
timeout -k 4 110 chroot "$root" runuser -u y700 -- /bin/bash /opt/chinese-input/session.sh || status=$?
if [[ -n ${CHINESE_INPUT_DEBUG_DIR:-} ]]; then
    install -m644 "$root/run/chinese-input/"*.log "$CHINESE_INPUT_DEBUG_DIR/" 2>/dev/null || true
    if [[ -f $root/run/chinese-input/display.png ]]; then
        install -m644 "$root/run/chinese-input/display.png" "$CHINESE_INPUT_DEBUG_DIR/"
    fi
fi
exit "$status"
