#!/bin/bash
# Linux PC with native arm64 or qemu-user binfmt and loop/overlay support.
set -euo pipefail
if [[ ${1:-} != --inside ]]; then
    [[ $# == 6 && $EUID == 0 ]] || { echo 'Usage: overlay.sh DEV12.9_ROOT CANDIDATE.deb DEBIAN_STOCK.deb ARM64_XVFB ARM64_UV H264_SEEK.mp4' >&2; exit 2; }
    exec unshare --mount --pid --fork --mount-proc --net bash "$0" --inside "$@"
fi
shift
[[ $$ == 1 ]]
mount --make-rprivate /
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-parole-touch-test.XXXXXXXX")
root=$work/root
cleanup() {
    kill -TERM -1 2>/dev/null || :
    sleep .3
    kill -KILL -1 2>/dev/null || :
    umount -R "$root" 2>/dev/null || :
    umount "$work/base" 2>/dev/null || :
    if ! mountpoint -q "$root" && ! mountpoint -q "$work/base"; then rm -r --one-file-system -- "$work"; fi
}
trap cleanup EXIT
echo "e40d2b7b297913c7200d2238f8f79d5a28926b983866cf09ca61f3dcbd8a0ddb  $1" | sha256sum -c -
echo "2ba9a27f1e68eda4fbb521a0f4e9db486ea25b801fbfa2d8b3d2a4d36fb3a995  $3" | sha256sum -c -
mkdir "$root" "$work"/{upper,work,base}
mount -o loop,ro,noload "$1" "$work/base"
mount -t overlay overlay -o "lowerdir=$work/base,upperdir=$work/upper,workdir=$work/work" "$root"
mount -t proc proc "$root/proc"
mkdir -p "$root/sys/devices/system/cpu"
mount -o bind,ro /sys/devices/system/cpu "$root/sys/devices/system/cpu"
mount -t tmpfs tmpfs "$root/dev"
mkdir "$root/dev/"{pts,shm}
chmod 1777 "$root/dev/shm"
mount -t devpts devpts "$root/dev/pts"
ln -s /proc/self/fd "$root/dev/fd"
for x in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$root/dev/${x%:*}" c 1 "${x#*:}"; done
mkdir -p "$root/qa" "$root/run/dbus"
install -m644 "$2" "$root/qa/candidate.deb"
install -m644 "$3" "$root/qa/stock.deb"
install -m755 "$4" "$root/qa/Xvfb"
install -m755 "$5" "$root/qa/uv"
install -m644 "$6" "$root/qa/clip.mp4"
install -m644 "$here/geometry.py" "$here/scrub.py" "$here/../video-codec/parole-transport.py" "$root/qa/"
install -m755 "$here/session.sh" "$root/qa/"
chroot "$root" /usr/bin/env PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -eu <<'SESSION'
set -o pipefail
dbus-daemon --system --fork
dpkg-query -W -f='${binary:Package}\t${Version}\n' > /qa/packages.stock
sha256sum /usr/local/bin/y700-parole /usr/local/share/applications/org.xfce.Parole.desktop \
    /usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so > /qa/launcher.sha256
for phase in stock candidate; do
    if [[ $phase == candidate ]]; then
        dpkg -i /qa/candidate.deb
        version=$(dpkg-deb -f /qa/candidate.deb Version)
        case $version in 4.18.2-1+y7001|4.18.2-1+y7002) ;; *) exit 1 ;; esac
        [[ $(dpkg-query -W -f='${Version}' parole) == "$version" ]]
        awk -F '\t' -v v="$version" 'BEGIN{OFS=FS} $1=="parole" {$2=v} {print}' /qa/packages.stock > /qa/packages.expected
        dpkg-query -W -f='${binary:Package}\t${Version}\n' | cmp /qa/packages.expected -
        sha256sum --check /qa/launcher.sha256
    fi
    for scale in 1 2; do
        timeout -k 3 150 /qa/session.sh "$scale" "$phase" | tee "/qa/$phase.$scale.log"
        grep -q '^PAROLE_SIZE ' "/qa/$phase.$scale.log"
    done
done
# Compare against the toolkit allocations produced by the stock package in the same desktop.
for scale in 1 2; do
    keys=(theme menu_atk)
    if [[ $scale == 1 ]]; then keys+=(button slider); fi
    for key in "${keys[@]}"; do
        stock=$(sed -n "s/.* $key=\([^ ]*\).*/\1/p" "/qa/stock.$scale.log")
        candidate=$(sed -n "s/.* $key=\([^ ]*\).*/\1/p" "/qa/candidate.$scale.log")
        [[ -n $stock && $stock == "$candidate" ]]
    done
done
dpkg -i /qa/stock.deb
[[ $(dpkg-query -W -f='${Version}' parole) == 4.18.2-1 && -z $(dpkg -V parole) && -z $(dpkg --audit) ]]
dpkg-query -W -f='${binary:Package}\t${Version}\n' | cmp /qa/packages.stock -
sha256sum --check /qa/launcher.sha256
apt-get check
SESSION
echo 'PAROLE_TOUCH_PASS stock_1x_equals_candidate_1x=1 stock_rollback=1'
