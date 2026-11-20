#!/usr/bin/env bash
# Build a portable QCOW2 update against the unpersonalized dev12.5 root.
set -euo pipefail
if [[ $# != 6 || $EUID != 0 ]]; then
    echo 'Usage (root): build-dev12.6-root.sh SEALED_ROOT PLATFORM.deb QCAM_LIB_DIR QCAM4_DIR TOUCH_LOCK_DIR NEW_LINUX_DIR' >&2
    exit 2
fi
if [[ ${Y700_ROTATION_IMAGE_PRIVATE:-0} != 1 ]]; then
    exec unshare --mount --propagation private --net --pid --fork --ipc env Y700_ROTATION_IMAGE_PRIVATE=1 bash "$0" "$@"
fi
export LC_ALL=C UV_OFFLINE=1 SYSTEMD_OFFLINE=1 DEBIAN_FRONTEND=noninteractive
export UV_PYTHON=${UV_PYTHON:-/usr/bin/python3}
umask 077
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
source_root=$(realpath -e -- "$1")
platform=$(realpath -e -- "$2")
libs=$(realpath -e -- "$3")
camera=$(realpath -e -- "$4")
locker=$(realpath -e -- "$5")
[[ ! -e $6 && ! -L $6 ]]
out=$(realpath -m -- "$6")
[[ -f $source_root && -d ${out%/*} ]]
qemu_img=${QEMU_IMG:-qemu-img}
py=("${UV_BIN:-uv}" run --offline --no-project --python "$UV_PYTHON" python)
sealed=041fcf2e04b5d05edbfa3147f442a019d2f260f6544b9182087bf911ff8e55b6
printf '%s  %s\n' "$sealed" "$source_root" \
    651fcc5de550d9ac645b53e853693bdc751dd07bfaee1a8c75f4f84d466b04bf "$platform" | sha256sum --strict -c -
work=$(mktemp -d -- "${out%/*}/.y700-rotation-image.XXXXXXXX")
root=$work/mount
bundle=$work/result/delta
raw=$work/result/verified/updated.ext4
cleanup() {
    if mountpoint -q "$root"; then umount -R -- "$root"; fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir -p -- "$root" "$bundle" "$work/result/verified" "$work/camera"
cp -- "$libs"/lib*.deb "$camera"/y700-camera-qcam_*.deb "$work/camera/"
e2fsck -fn "$source_root" > "$bundle/parent-fsck.txt" 2>&1
cp --reflink=auto --sparse=always -- "$source_root" "$work/build.ext4"
chmod u+w "$work/build.ext4"
mount -o loop,nosuid,nodev "$work/build.ext4" "$root"
guest=(chroot "$root" /usr/bin/env SYSTEMD_OFFLINE=1 DEBIAN_FRONTEND=noninteractive)
generic() {
    [[ $(<"$root/etc/y700/image-id") == y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f ]]
    [[ -f $root/etc/machine-id && ! -s $root/etc/machine-id ]]
    [[ $("${guest[@]}" passwd -S y700 | cut -d' ' -f2) == L ]]
    for path in "$root"/{etc/y700/maintenance*,etc/y700/bluetooth-address,etc/y700/user-configured,etc/ssh/ssh_host_*,run/y700-speaker-calibration,home/y700/.ssh,root/.ssh,var/lib/y700/ssh,var/lib/systemd/random-seed,var/lib/systemd/credential.secret,.y700-disposable-build-root}; do
        [[ ! -e $path && ! -L $path ]]
    done
    for path in "$root"/{etc/NetworkManager/system-connections,var/lib/bluetooth,var/lib/y700-ssc}; do
        if [[ -d $path ]]; then [[ -z $(find "$path" -mindepth 1 -print -quit) ]]; fi
    done
    for file in regulatory.db regulatory.db.p7s; do
        [[ $("${guest[@]}" readlink -f "/lib/firmware/$file") == "/usr/lib/firmware/$file-upstream" ]]
    done
}
inventory() {
    dpkg-query --admindir="$root/var/lib/dpkg" -W '-f=${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
        sed -n 's/^installed\t//p' | sort
}
check=("${py[@]}" "$repo/scripts/verify-image-packages.py" "$root" --camera-lock "$repo/config/camera-layer.lock.json")
generic
inventory > "$work/before.tsv"
before_lock=$repo/tests/onboard-image/camera-qcam.lock.json
"${check[@]}" --sealed-dev12-5 --qcam-lock "$before_lock" | tee "$bundle/parent-inventory.txt"
mount -t proc -o nosuid,nodev,noexec proc "$root/proc"
mount -t tmpfs -o mode=755,nosuid,noexec tmpfs "$root/dev"
for pair in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$root/dev/${pair%:*}" c 1 "${pair#*:}"; done
ln -s /proc/self/fd "$root/dev/fd"
[[ ! -d $root/run/systemd/system ]]
touch "$root/.y700-disposable-build-root"
stage=$(mktemp -d -- "$root/tmp/rotation-image.XXXXXXXX")
install -m644 -- "$platform" "$stage/platform.deb"
printf '#!/bin/sh\nexit 101\n' > "$stage/policy"
chmod 755 "$stage/policy"
ln -- "$stage/policy" "$root/usr/sbin/policy-rc.d"
"${guest[@]}" dpkg --force-confold -i "${stage#"$root"}/platform.deb"
rm -- "$root/usr/sbin/policy-rc.d" "$stage/policy" "$stage/platform.deb"
rmdir -- "$stage"
"${check[@]}" --qcam-lock "$before_lock"
bash "$repo/scripts/add-board-layer.sh" camera-qcam "$root" "$work/camera"
bash "$repo/scripts/add-board-layer.sh" touch-lock "$root" "$locker"
rm -- "$root/.y700-disposable-build-root"
chmod 644 "$root/var/lib/y700/build/packages.tsv"
for lock in camera-qcam touch-lock; do cmp "$repo/config/$lock.lock.json" "$root/var/lib/y700/build/$lock.lock.json"; done
"${guest[@]}" apt-get check
[[ -z $("${guest[@]}" dpkg --audit) ]]
[[ -z $("${guest[@]}" dpkg -V y700-platform y700-camera-qcam libxss1 xfce4-screensaver y700-touch-lock) ]]
generic
"${check[@]}" | tee "$bundle/inventory.txt"
inventory > "$bundle/packages.tsv"
printf '%s  %s\n' ae129edd690fcd72820e3c286c6010474a70cefea622d53f4fe88b53f94afb21 "$work/before.tsv" \
    a5f46346523f60efb2545e290d209372daa983b094e42c37e7ced2cdb97b3d98 "$bundle/packages.tsv" | sha256sum --strict -c -
comm -3 "$work/before.tsv" "$bundle/packages.tsv" > "$bundle/package-changes.tsv"
umount -R -- "$root"
e2fsck -fn "$work/build.ext4" > "$bundle/updated-fsck.txt" 2>&1

# A safe rebase materializes sectors that differ from the sealed parent,
# including changed-to-zero sectors. Only the relative backing name is stored.
child=rotation-update.qcow2
ln -s -- "$source_root" "$bundle/root.ext4"
(cd "$bundle" && "$qemu_img" create -q -f qcow2 -F raw -b "$work/build.ext4" "$child" &&
    "$qemu_img" rebase -f qcow2 -F raw -b root.ext4 "$child")
"$qemu_img" check -f qcow2 "$bundle/$child"
"$qemu_img" compare -f raw -F qcow2 "$work/build.ext4" "$bundle/$child"
"$qemu_img" info --output=json "$bundle/$child" |
    "${py[@]}" -c 'import json,sys; i=json.load(sys.stdin); assert (i["format"],i["backing-filename-format"],i["backing-filename"],i["virtual-size"]) == ("qcow2","raw","root.ext4",6442450944)'
"$qemu_img" convert -f qcow2 -O raw "$bundle/$child" "$raw"
chmod 400 "$raw"
cmp -- "$work/build.ext4" "$raw"
e2fsck -fn "$raw" > "$bundle/reconstructed-fsck.txt" 2>&1
rm -- "$bundle/root.ext4"
printf '%s  %s\n' "$sealed" "$source_root" | sha256sum --strict -c -
printf '%s\n' "$sealed" > "$bundle/backing-root.sha256"
sha256sum "$raw" | cut -d' ' -f1 > "$bundle/new-root.sha256"
(cd "$bundle" && sha256sum -- * > SHA256SUMS)
mv -nT -- "$work/result" "$out"
test ! -e "$work/result"
echo DEV12P6_PORTABLE_ROOT_PASS
