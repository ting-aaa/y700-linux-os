#!/bin/bash
# Run on Linux with native ARM64 or qemu-aarch64 binfmt. The image is mounted read-only.
set -euo pipefail
if [[ ${1:-} != --inside ]]; then
    [[ $# == 6 && $EUID == 0 ]] || { echo 'Usage as root: test-overlay.sh ROOT.ext4 COMBINED.tar.gz ARM64_XVFB ARM64_UV ARM64_GSTREAMER_TOOLS.deb SILENT_CLIP.mp4' >&2; exit 2; }
    exec unshare --mount --net --pid --fork --mount-proc bash "$0" --inside "$@"
fi
shift
[[ $$ == 1 ]]
mount --make-rprivate /
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-parole-integration.XXXXXXXX")
root=$work/root
cleanup() {
    # All children are confined to this PID namespace, including D-Bus-activated services.
    kill -TERM -1 2>/dev/null || :
    sleep .2
    kill -KILL -1 2>/dev/null || :
    for directory in "$root/sys/devices/system/cpu" "$root/dev/pts" "$root/proc" "$root/dev" "$root" "$work/base"; do
        if mountpoint -q "$directory"; then umount "$directory"; fi
    done
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
echo "2d03b3d2e312f1a425c5b8f657f20fddd45f07caa54b4a937590a720fa2cf511  $1" | sha256sum -c -
mkdir "$root" "$work/"{base,upper,work}
mount -o loop,ro,noload "$1" "$work/base"
mount -t overlay overlay -o "lowerdir=$work/base,upperdir=$work/upper,workdir=$work/work" "$root"
mount -t proc proc "$root/proc"
mkdir -p "$root/sys/devices/system/cpu"
mount --bind /sys/devices/system/cpu "$root/sys/devices/system/cpu"
mount -o remount,bind,ro "$root/sys/devices/system/cpu"
mount -t tmpfs tmpfs "$root/dev"
mkdir "$root/dev/"{pts,shm}
chmod 1777 "$root/dev/shm"
mount -t devpts devpts "$root/dev/pts"
ln -s /proc/self/fd "$root/dev/fd"
for spec in 'null 1 3' 'zero 1 5' 'random 1 8' 'urandom 1 9' 'tty 5 0'; do
    read -r name major minor <<< "$spec"; mknod -m666 "$root/dev/$name" c "$major" "$minor"
done
mkdir -p "$root/qa" "$root/run/dbus"
tar -xzf "$2" -C "$root/qa"
install -m755 "$3" "$root/qa/Xvfb"
install -m755 "$4" "$root/qa/uv"
dpkg-deb -x "$5" "$root/qa/tools"
install -m644 "$6" "$root/qa/clip.mp4"
install -m644 "$here/check-session.py" "$root/qa/"
install -d "$root/usr/local/bin"
touch "$root/usr/local/bin/y700-parole"
if chroot "$root" /qa/y700-parole-iris/install.sh --check > "$work/conflict" 2>&1; then exit 1; fi
grep -Fx 'Local file conflict: /usr/local/bin/y700-parole' "$work/conflict"
rm "$root/usr/local/bin/y700-parole"
chroot "$root" /qa/y700-parole-iris/install.sh --install
stat -c '%i %Y' "$root/usr/local/bin/y700-parole" > "$work/stat"
chroot "$root" /qa/y700-parole-iris/install.sh --install
stat -c '%i %Y' "$root/usr/local/bin/y700-parole" | cmp "$work/stat" -
chroot "$root" /qa/y700-parole-iris/install.sh --verify
chroot "$root" /bin/bash -eu <<'SESSION'
dbus-daemon --system --fork
install -d -m700 -o y700 -g y700 /run/player
export DISPLAY=:87 XAUTHORITY=/run/player/Xauthority XDG_RUNTIME_DIR=/run/player XDG_CURRENT_DESKTOP=XFCE
export PATH=/qa/tools/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C GDK_SCALE=2
(printf '\377\377\000\000\000\00287\000\022MIT-MAGIC-COOKIE-1\000\020'; head -c16 /dev/urandom) > "$XAUTHORITY"
chown y700:y700 "$XAUTHORITY"
chmod 600 "$XAUTHORITY"
/qa/Xvfb "$DISPLAY" -screen 0 1600x1000x24 -nolisten tcp -auth "$XAUTHORITY" >/run/X.log 2>&1 & xpid=$!
trap 'kill "$xpid" 2>/dev/null || :' EXIT
for _ in {1..70}; do if xdpyinfo >/dev/null 2>&1; then break; fi; sleep .1; done
xdpyinfo >/dev/null
runuser -u y700 -- env HOME=/home/y700 XDG_CACHE_HOME=/run/player/cache UV_CACHE_DIR=/run/player/uv UV_OFFLINE=1 \
    dbus-run-session -- /qa/uv run --offline --no-project --python /usr/bin/python3 python -B /qa/check-session.py /qa/clip.mp4
SESSION
echo 'INTEGRATED_PLAYER_PASS exact_parent=1 install_twice=1 conflict_rejected=1'
