#!/usr/bin/env bash
# Needs root, ARM64 emulation if required, and a read-only qcow2 backing chain.
set -euo pipefail
if (( $# != 6 && $# != 8 )); then
    echo 'Usage: run-arm64.sh ROOT.qcow2 SHA256 NBD_BIN_DIR X11_DEB_DIR DBUSMOCK.deb UV_ARM64 [BLUEMAN.deb BLUEMAN_SHA256]' >&2
    exit 2
fi
if [[ ${BLUEMAN_PAIRING_NS:-} != 1 ]]; then
    test "$(id -u)" = 0
    exec unshare --mount --net --pid --fork --kill-child --mount-proc \
        env BLUEMAN_PAIRING_NS=1 bash "$0" "$@"
fi
leaf=$(realpath -e "$1")
[[ $2 =~ ^[a-f0-9]{64}$ ]]
nbd=$(realpath -e "$3")
x11=$(realpath -e "$4")
mock=$(realpath -e "$5")
uv=$(realpath -e "$6")
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
printf '%s  %s\n' "$2" "$leaf" | sha256sum -c -

work=$(mktemp -d /tmp/y700-blueman-ui.XXXXXXXX)
[[ $(realpath -e "$work") =~ ^/tmp/y700-blueman-ui\.[a-zA-Z0-9]{8}$ ]]
nbd_pid= fuse_pid=
cleanup() {
    if mountpoint -q "$work/root"; then umount -R "$work/root"; fi
    if mountpoint -q "$work/lower"; then umount "$work/lower"; fi
    if mountpoint -q "$work/view"; then fusermount3 -u "$work/view"; fi
    for pid in "$fuse_pid" "$nbd_pid"; do
        if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    done
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir "$work"/{view,lower,upper,overlay-work,root}
"$nbd/qemu-nbd" --persistent --read-only --format=qcow2 --socket="$work/disk.sock" "$leaf" &
nbd_pid=$!
for _ in {1..100}; do [[ ! -S $work/disk.sock ]] || break; sleep .05; done
test -S "$work/disk.sock"
"$nbd/nbdfuse" -r "$work/view/root.raw" --unix "$work/disk.sock" &
fuse_pid=$!
for _ in {1..100}; do [[ ! -f $work/view/root.raw ]] || break; sleep .05; done
test "$(stat -Lc %s "$work/view/root.raw")" = 6442450944
mount -o loop,ro,noload "$work/view/root.raw" "$work/lower"
mount -t overlay overlay -o "lowerdir=$work/lower,upperdir=$work/upper,workdir=$work/overlay-work" "$work/root"

root=$work/root
mount -t tmpfs -o mode=755,nosuid tmpfs "$root/dev"
for device in null zero random urandom tty; do
    touch "$root/dev/$device"
    mount --bind "/dev/$device" "$root/dev/$device"
done
ln -s /proc/self/fd "$root/dev/fd"
mkdir -m1777 "$root/dev/shm"
mount -t proc proc "$root/proc"
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$root/tmp"
mount -t tmpfs -o mode=755,nosuid,nodev tmpfs "$root/run"
for archive in "$x11"/{xvfb,xdotool,libxdo3}_*.deb "$mock"; do
    dpkg-deb -x "$archive" "$root"
done
install -d "$root/opt/blueman-pairing"
install -m755 "$uv" "$root/opt/blueman-pairing/uv"
install -m644 "$here/"{run-session.sh,probe.py} "$root/opt/blueman-pairing/"
chroot "$root" /usr/bin/install -d -o y700 -g y700 -m700 /run/blueman-pairing
printf '%s\n' 'BLUEMAN_ISOLATION image_readonly=1 network_namespace=private radio=none'
version=2.4.4-1
if (( $# == 8 )); then
    candidate=$(realpath -e "$7")
    [[ $8 =~ ^[a-f0-9]{64}$ ]]
    printf '%s  %s\n' "$8" "$candidate" | sha256sum -c -
    test "$(dpkg-deb -f "$candidate" Package)" = blueman
    test "$(dpkg-deb -f "$candidate" Architecture)" = arm64
    next_version=$(dpkg-deb -f "$candidate" Version)
    case $next_version in 2.4.4-1+y7001|2.4.4-1+y7002) ;; *) exit 1 ;; esac
    inventory() {
        chroot "$root" dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' \
            | sed -n 's/^installed\t//p' | LC_ALL=C sort
    }
    inventory > "$work/before"
    grep -Fxq $'blueman\t2.4.4-1\tarm64' "$work/before"
    install -m644 "$candidate" "$root/tmp/blueman-candidate.deb"
    chroot "$root" env SYSTEMD_OFFLINE=1 dpkg -i /tmp/blueman-candidate.deb
    test -z "$(chroot "$root" dpkg --audit)"
    test -z "$(chroot "$root" dpkg -V blueman)"
    inventory > "$work/after"
    awk -F '\t' -v OFS='\t' -v next_version="$next_version" \
        '$1 == "blueman" && $2 == "2.4.4-1" && $3 == "arm64" {$2 = next_version} {print}' \
        "$work/before" | cmp - "$work/after"
    version=$next_version
    printf '%s\n' 'BLUEMAN_PACKAGE_UPGRADE changed_tuples=1 dpkg_verify=1 audit_clean=1'
fi
timeout --kill-after=5 170 chroot "$root" /usr/sbin/runuser -u y700 -- \
    /bin/bash /opt/blueman-pairing/run-session.sh "$version"
