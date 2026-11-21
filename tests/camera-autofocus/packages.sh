#!/bin/bash
# Exercise real dpkg on a disposable ARM64 overlay over the generic staged desktop.
set -euo pipefail
export LC_ALL=C
if [[ ${1:-} != --inside ]]; then
    [[ $EUID == 0 && $# == 3 ]] || { echo "Usage: sudo bash $0 WIFI_STAGED_ROOT_EXT4 ORIGINAL_DEBS CANDIDATE_DEBS" >&2; exit 2; }
    exec unshare --mount --net --pid --fork -- bash "$0" --inside "$(realpath -e "$1")" "$(realpath -e "$2")" "$(realpath -e "$3")"
fi
shift
image=$1
old=$2
new=$3
[[ -f $image && ! -b $image ]]
echo "0383703eac309a64e3febc286fa6c8d9fffb9c252745bb7b1647bde647a27ca0  $image" | sha256sum --strict -c -
mount --make-rprivate /
base=$(mktemp -d /var/tmp/y700-camera-af-qa.XXXXXXXX)
root=$base/overlay
mkdir "$root" "$base/lower" "$base/ram"
cleanup() {
    trap - EXIT
    for m in "$root/run/af/old" "$root/run/af/new" "$root/dev" "$root/proc" "$root/run" "$root" "$base/ram" "$base/lower"; do
        if mountpoint -q "$m"; then umount "$m" || return 1; fi
    done
    rm -rf -- "$base"
}
trap cleanup EXIT
mount -t ext4 -o loop,ro,noload "$image" "$base/lower"
mount -t tmpfs -o mode=700,size=400M tmpfs "$base/ram"
mkdir "$base/ram/"{up,work}
mount -t overlay overlay -o "lowerdir=$base/lower,upperdir=$base/ram/up,workdir=$base/ram/work" "$root"
mount -t tmpfs tmpfs "$root/run"
mount -t proc proc "$root/proc"
mount -t tmpfs tmpfs "$root/dev"
mknod -m 666 "$root/dev/null" c 1 3
mknod -m 666 "$root/dev/urandom" c 1 9
mkdir -p "$root/run/af/"{old,new}
for side in old new; do
    mount --bind "${!side}" "$root/run/af/$side"
    mount -o remount,bind,ro "$root/run/af/$side"
done
chroot "$root" /bin/bash -se <<'GUEST'
set -eu -o pipefail
export LC_ALL=C
[[ $(dpkg --print-architecture) == arm64 && ! -e /run/dbus/system_bus_socket && ! -e /dev/media0 ]]
inventory() {
    dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' | sed -n 's/^installed\t//p' | sort >"/run/af/$1.tsv"
    echo "inventory $1 $(wc -l <"/run/af/$1.tsv") $(sha256sum <"/run/af/$1.tsv" | cut -d' ' -f1)"
}
check_packages() {
    [[ -z $(dpkg --audit) ]]
    apt-get --no-download -o Debug::NoLocking=true check >/dev/null
    for app in /opt/y700-camera/bin/{qcam,cam} /usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so /opt/y700-camera/lib/gstreamer-1.0/libgstlibcamera.so; do
        LD_LIBRARY_PATH=/opt/y700-camera/lib ldd -r "$app" >/run/af/link
        if grep -E 'undefined symbol|not found' /run/af/link; then exit 1; fi
    done
}
shopt -s nullglob
for side in old new; do
    files=(/run/af/"$side"/*.deb)
    [[ ${#files[@]} == 3 ]]
    for deb in "${files[@]}"; do
        case $(dpkg-deb -f "$deb" Package) in
            y700-camera-pipewire|y700-camera-qcam|y700-camera-runtime) ;;
            *) exit 1 ;;
        esac
        dpkg-deb -W --showformat='${Package}\t${Version}\t${Architecture}\t${Depends}\n' "$deb"
    done
done
inventory baseline
echo '2d180b436086b9015044bff4053c314de4b63bce4f5406baffcd1ebce79a67d8  /run/af/baseline.tsv' | sha256sum -c -
check_packages
dpkg -i /run/af/new/*.deb
check_packages
inventory upgraded
for side in baseline upgraded; do
    grep -vE '^y700-camera-(runtime|pipewire|qcam)[[:space:]]' "/run/af/$side.tsv" >"/run/af/$side.other"
done
cmp /run/af/{baseline,upgraded}.other
grep -F $'y700-camera-pipewire\t1.4.2-1+y700.4\tarm64' /run/af/upgraded.tsv
grep -F $'y700-camera-qcam\t0.7.2-1~bpo13+1.y7005\tarm64' /run/af/upgraded.tsv
grep -F $'y700-camera-runtime\t0.7.2-1~bpo13+1.y7002\tarm64' /run/af/upgraded.tsv
dpkg -i /run/af/old/*.deb
check_packages
inventory restored
cmp /run/af/{baseline,restored}.tsv
echo 'PASS only three camera packages changed, ARM64 loader relocations and dependency checks passed, rollback restored every installed tuple'
GUEST
