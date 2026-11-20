#!/usr/bin/env bash
# Build only a child of the sealed, generic dev12.4 root. Requires Linux and ARM64 binfmt.
set -euo pipefail
if [[ $# != 6 || $EUID != 0 ]]; then
    echo 'Usage (root): run.sh DEV12.4.ext4 PLATFORM.deb QCAM_DIR SSC_DIR ONBOARD_DIR NEW_OUTPUT_DIR' >&2
    exit 2
fi
if [[ ${Y700_IMAGE_PRIVATE:-0} != 1 ]]; then
    exec unshare --mount --propagation private --net --pid --fork env Y700_IMAGE_PRIVATE=1 bash "$0" "$@"
fi
export LC_ALL=C
umask 077
repo=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
source_root=$(realpath -e -- "$1")
platform=$(realpath -e -- "$2")
qcam=$(realpath -e -- "$3")
qcam_lock=$repo/tests/onboard-image/camera-qcam.lock.json
ssc=$(realpath -e -- "$4")
onboard=$(realpath -e -- "$5")
out=$(realpath -m -- "$6")
[[ -f $source_root && -d ${out%/*} && ! -e $out && ! -L $out ]]
qemu_img=${QEMU_IMG:-qemu-img}
py=("${UV_BIN:-uv}" run --offline --no-project --python "${UV_PYTHON:-/usr/bin/python3}" python)
parent_sha=9054df11e3a7d6cceacdfa6dffdb081c4a94428468ada09076c286c61ac17f30
platform_sha=37bb3cc3afba68f6a73e9aed41958a28bd28a4f6d62a8acc11bba4d051190618
parent_inventory=e0caf1e65e742059c826219046fad6e39437c45d8b33d50325f15054a0b6ac8a
printf '%s  %s\n' "$parent_sha" "$source_root" "$platform_sha" "$platform" | sha256sum --strict -c -
"${py[@]}" "$repo/scripts/repair-inputs.py" verify "$qcam" "$qcam_lock"
"${py[@]}" "$repo/scripts/repair-inputs.py" verify "$ssc" "$repo/config/ssc.lock.json"
"${py[@]}" "$repo/scripts/repair-inputs.py" verify "$onboard" "$repo/config/onboard.lock.json"
work=$(mktemp -d -- "${out%/*}/.y700-onboard-image.XXXXXXXX")
root=$work/root
cleanup() {
    if mountpoint -q "$root"; then umount -R -- "$root"; fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir -m700 "$root" "$work/result"
cp --sparse=always --reflink=auto -- "$source_root" "$work/working.ext4"
chmod u+w "$work/working.ext4"
mount -o loop,nosuid,nodev "$work/working.ext4" "$root"
generic() {
    [[ $(<"$root/etc/y700/image-id") == y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f ]]
    [[ ! -s $root/etc/machine-id && ! -e $root/etc/y700/bluetooth-address ]]
    [[ ! -e $root/etc/y700/user-configured && ! -e $root/var/lib/y700-ssc/registry ]]
    [[ $(chroot "$root" passwd -S y700 | cut -d' ' -f2) == L ]]
}
inventory() {
    dpkg-query --admindir="$root/var/lib/dpkg" -W '-f=${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
        sed -n 's/^installed\t//p' | sort
}
generic
inventory > "$work/before.tsv"
printf '%s  %s\n' "$parent_inventory" "$work/before.tsv" | sha256sum --strict -c -
[[ $(wc -l < "$work/before.tsv") == 1112 ]]
"${py[@]}" "$repo/scripts/verify-image-packages.py" "$root" --check-upgrade onboard
mount -t proc -o nosuid,nodev,noexec proc "$root/proc"
mount -t tmpfs -o mode=755,nosuid,noexec tmpfs "$root/dev"
for pair in null:3 zero:5 random:8 urandom:9; do
    mknod -m666 "$root/dev/${pair%:*}" c 1 "${pair#*:}"
done
[[ ! -d $root/run/systemd/system && ! -e $root/usr/sbin/policy-rc.d && ! -L $root/usr/sbin/policy-rc.d ]]
printf '#!/bin/sh\nexit 101\n' > "$root/usr/sbin/policy-rc.d"
chmod 755 "$root/usr/sbin/policy-rc.d"
stage=$(mktemp -d -- "$root/tmp/keyboard-upgrade.XXXXXXXX")
archives=("$onboard"/onboard_*.deb "$qcam"/y700-camera-qcam_*.deb "$ssc"/y700-ssc-runtime_*.deb "$platform")
[[ ${#archives[@]} == 4 ]]
guest_paths=()
for archive in "${archives[@]}"; do
    dest=$stage/$(basename -- "$archive")
    install -m644 -- "$archive" "$dest"
    guest_paths+=("${dest#"$root"}")
done
guest=(chroot "$root" /usr/bin/env SYSTEMD_OFFLINE=1 DEBIAN_FRONTEND=noninteractive)
"${guest[@]}" dpkg --force-confold --install "${guest_paths[@]}"
"${guest[@]}" apt-get check
[[ -z $("${guest[@]}" dpkg --audit) ]]
[[ -z $("${guest[@]}" dpkg -V onboard y700-platform y700-camera-qcam y700-ssc-runtime) ]]
[[ $("${guest[@]}" XDG_CURRENT_DESKTOP=XFCE GSETTINGS_BACKEND=memory setpriv --reuid=y700 --regid=y700 --clear-groups \
    gsettings get org.onboard.auto-show keyboard-device-detection-enabled) == true ]]
rm -f -- "$root/usr/sbin/policy-rc.d" "$stage"/*.deb
rmdir -- "$stage"
install -m644 "$qcam_lock" "$root/var/lib/y700/build/camera-qcam.lock.json"
for lock in ssc onboard; do
    install -m644 "$repo/config/$lock.lock.json" "$root/var/lib/y700/build/$lock.lock.json"
done
record=$root/var/lib/y700/build/packages.tsv
"${guest[@]}" dpkg-query -W '-f=${binary:Package}\t${Version}\t${Architecture}\n' > "$record"
chmod 644 "$record"
inventory > "$work/after.tsv"
sed -e 's/^onboard\t1\.4\.1-10\t/onboard\t1.4.1-10+y7002\t/' \
    -e 's/^y700-camera-qcam\t0\.7\.2-1~bpo13+1\.y7002\t/y700-camera-qcam\t0.7.2-1~bpo13+1.y7003\t/' \
    -e 's/^y700-platform\t0\.1\.0~dev12\.4\t/y700-platform\t0.1.0~dev12.5\t/' \
    -e 's/^y700-ssc-runtime\t0\.1\.1\t/y700-ssc-runtime\t0.1.3\t/' "$work/before.tsv" |
    cmp - "$work/after.tsv"
comm -3 "$work/before.tsv" "$work/after.tsv" > "$work/result/package-changes.tsv"
[[ $(wc -l < "$work/result/package-changes.tsv") == 8 ]]
"${py[@]}" "$repo/scripts/verify-image-packages.py" "$root" --qcam-lock "$qcam_lock" | tee "$work/result/inventory.txt"
generic
umount -R -- "$root"
tree_digest() {
    mount -o loop,ro,noload,nodev,nosuid "$work/working.ext4" "$root"
    tar --format=pax --sort=name --numeric-owner --acls --xattrs --xattrs-include='*' \
        --pax-option='delete=atime,delete=ctime,exthdr.name=%d/PaxHeaders/%f' \
        --one-file-system -C "$root" -cf - . | sha256sum | cut -d' ' -f1
    umount -- "$root"
}
# Historical guest builds deleted files during the first seconds of 1970. A real-clock
# mount enables e2fsck's low-dtime check. Validate its complete diagnosis before
# allowing exactly those tombstones to receive normal deletion times on our copy.
cat > "$work/fsck.conf" <<EOF
[options]
    problem_log_filename = $work/fsck.xml
[problems]
    0x010036 = {
        preen_ok = true
    }
    0x010037 = {
        preen_ok = true
    }
EOF
rc=0
E2FSCK_CONFIG="$work/fsck.conf" e2fsck -fn "$work/working.ext4" > "$work/initial-fsck.log" 2>&1 || rc=$?
if [[ $rc == 4 ]]; then
    mv -- "$work/fsck.xml" "$work/before.xml"
    check=("${py[@]}" "$repo/tests/onboard-image/check-deletions.py" "$source_root" "$work/working.ext4" "$work/before.xml")
    "${check[@]}" > "$work/result/ext4-check.txt"
    tree_digest > "$work/result/live-tree.sha256"
    rc=0
    E2FSCK_CONFIG="$work/fsck.conf" e2fsck -fp "$work/working.ext4" > "$work/fsck-repair.log" 2>&1 || rc=$?
    [[ $rc == 1 ]]
    "${check[@]}" "$work/fsck.xml" | cmp - "$work/result/ext4-check.txt"
    tree_digest | cmp - "$work/result/live-tree.sha256"
else
    [[ $rc == 0 ]]
    echo epoch_deleted_unallocated_inodes=0 > "$work/result/ext4-check.txt"
    tree_digest > "$work/result/live-tree.sha256"
fi
cat "$work/result/ext4-check.txt"
e2fsck -fn "$work/working.ext4"
child=$work/result/keyboard-update.qcow2
"$qemu_img" create -q -f qcow2 -F raw -b "$work/working.ext4" "$child"
ln -s -- "$source_root" "$work/result/root.ext4"
# A normal rebase preserves the new root's contents and materializes the clusters
# that differ from the sealed root. The child records a portable backing name.
(cd "$work/result" && "$qemu_img" rebase -f qcow2 -F raw -b root.ext4 keyboard-update.qcow2)
"$qemu_img" check -f qcow2 "$child"
"$qemu_img" compare -f raw -F qcow2 "$work/working.ext4" "$child"
rm -- "$work/result/root.ext4"
printf '%s  %s\n' "$parent_sha" "$source_root" | sha256sum --strict -c -
sha256sum "$work/working.ext4" | cut -d' ' -f1 > "$work/result/new-root.sha256"
printf '%s\n' "$parent_sha" > "$work/result/backing-root.sha256"
(cd "$work/result" && sha256sum keyboard-update.qcow2 package-changes.tsv inventory.txt *sha256 ext4-check.txt > SHA256SUMS)
mv -nT -- "$work/result" "$out"
test ! -e "$work/result"
echo 'ONBOARD_IMAGE_OFFLINE_PASS'
