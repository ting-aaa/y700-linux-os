#!/bin/bash
# Execute only on a Linux PC. All target block devices below are new file-backed loop devices.
set -euo pipefail
export LC_ALL=C
umask 077
case ${1:-} in
    cut|cut32|verify) [[ $# == 4 ]] || exit 2 ;;
    *) echo 'Usage: run.sh cut|cut32 IMAGES RELEASE_ENTRY NEW_SCRATCH  |  verify IMAGES RECOVERY_ENTRY SCRATCH' >&2; exit 2 ;;
esac
[[ $EUID == 0 ]]
if [[ ${Y700_RECOVERY_NS:-0} != 1 ]]; then
    exec unshare --mount --propagation private env Y700_RECOVERY_NS=1 bash "$0" "$@"
fi
here=$(cd "$(dirname "$0")" && pwd -P)
action=$1
images=$(realpath -e "$2")
entry=$(realpath -e "$3")
work=$(realpath -m "$4")
[[ $work =~ ^/var/tmp/y700-file-recovery\.[a-zA-Z0-9_-]+$ ]]
if [[ $action != verify ]]; then
    mkdir -m700 "$work"
fi
cd "$work"
[[ $(stat -c '%u:%g:%a' .) == 0:0:700 ]]
loop= vm_pid=
cleanup() {
    if [[ -n $vm_pid ]]; then kill -KILL "$vm_pid" 2>/dev/null || :; wait "$vm_pid" 2>/dev/null || :; fi
    if mountpoint -q mount; then umount mount; fi
    if [[ -n $loop ]]; then losetup -d "$loop"; fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
offset=$((1024*1024))
gib=$((1024*1024*1024))
case $action in
    cut) size=$((9*gib)) ;;
    cut32) size=$((38*gib)) ;;
    verify)
        size=$(($(stat -c %s dirty.raw) - 2*offset))
        [[ $size == "$((9*gib))" || $size == "$((38*gib))" ]]
        ;;
esac
outer_uuid=ef306764-2315-4235-8796-69e2c9b61946
inner=mount/var/lib/y700-trial/dev12.10
open_outer() {
    local file=$1
    shift
    [[ -f $file && ! -L $file ]]
    loop=$(losetup --find --show --sector-size 4096 "$@" --offset "$offset" --sizelimit "$size" "$file")
    [[ $loop =~ ^/dev/loop[0-9]+$ && $(losetup --raw -nO BACK-FILE "$loop") == "$work/$file" ]]
}
close_outer() {
    if mountpoint -q mount; then umount mount; fi
    losetup -d "$loop"; loop=
}
assert_dirty() {
    local header
    header=$(dumpe2fs -h "$1" 2>/dev/null)
    grep -E '^Filesystem features:.* needs_recovery( |$)' <<< "$header"
}
entries=("$entry"/loader/entries/*.conf)
[[ ${#entries[@]} == 1 ]]
menu=${entries[0]}
field() { sed -n "s/^$1 //p" "$menu"; }
kernel=$entry$(field linux)
initrd=$entry$(field initrd)
args=$(field options)
[[ $args == *' y700.release=dev12.10 '* ]]
(cd "$entry" && sha256sum --strict -c SHA256SUMS)
printf '%s  %s\n' 4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1 "$kernel" | sha256sum --strict -c -
tar -cf "observer-$action.tar" -C "$here" guest.sh
unit=$(printf '%s\n' '[Unit]' 'Description=QEMU-only nested ext4 recovery measurement' 'DefaultDependencies=no' 'After=local-fs.target systemd-udev-trigger.service' 'Before=shutdown.target' 'Conflicts=shutdown.target' '[Service]' 'Type=oneshot' 'ExecStartPre=/usr/bin/udevadm wait --timeout=45 /dev/disk/by-id/virtio-y700observer /dev/disk/by-id/virtio-y700fixture-part1' "ExecStart=/bin/bash -o pipefail -c 'tar -xOf /dev/disk/by-id/virtio-y700observer guest.sh | /bin/bash'" 'StandardOutput=journal+console' 'StandardError=journal+console' | base64 -w0)
boot() {
    local phase=$1 disk=$2 mode=$3 tag
    local -a opts=()
    [[ -z ${QEMU_DATA:-} ]] || opts+=(-L "$QEMU_DATA")
    [[ $mode != snapshot ]] || opts+=(-snapshot)
    opts+=(-M virt,gic-version=3 -cpu max -smp 3 -m 3072 -nodefaults -no-user-config -monitor none -display none -serial stdio -nic none -no-reboot)
    opts+=(-drive "file=$disk,format=raw,if=none,id=fixture" -device virtio-blk-device,drive=fixture,serial=y700fixture,logical_block_size=4096,physical_block_size=4096 -kernel "$kernel" -initrd "$initrd")
    opts+=(-drive "file=observer-$action.tar,format=raw,if=none,id=observer,readonly=on" -device virtio-blk-device,drive=observer,serial=y700observer)
    tag=verify; [[ $mode != cut ]] || tag=cut
    opts+=(-append "$args console=ttyAMA0 loglevel=5 systemd.unit=basic.target systemd.wants=qa-recovery.service systemd.set_credential_binary=systemd.extra-unit.qa-recovery.service:$unit y700.recovery_test=$tag")
    if [[ $mode != cut ]]; then
        timeout -k 5 300 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${opts[@]}" >"$phase.log" 2>&1
        return
    fi
    "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${opts[@]}" >"$phase.log" 2>&1 &
    vm_pid=$!
    local end=$((SECONDS+180))
    while ! grep -Fq 'FILE_RECOVERY_CUT_READY mount_rw=' "$phase.log"; do
        kill -0 "$vm_pid" && (( SECONDS < end )) || return 1
        if grep -Fq 'qa-recovery.service:' "$phase.log" && grep -Fq 'Failed with result' "$phase.log"; then return 1; fi
        sleep .2
    done
    kill -KILL "$vm_pid"
    local status=0
    wait "$vm_pid" 2>/dev/null || status=$?
    vm_pid=
    [[ $status == 137 ]]
    if grep -Fq 'y700-file-trial: clean shutdown' "$phase.log"; then return 1; fi
    echo 'FILE_RECOVERY_HARD_CUT qemu_signal=KILL exit=137' | tee -a "$phase.log"
}
if [[ $action != verify ]]; then
    printf '%s  %s\n' \
        18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd "$images/root.ext4" \
        495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6 "$images/linux-boot.fat" \
        e063768b967875bf29abac9f01e4880ce24e9dde00e2c8a7325022004bb6eea6 "$initrd" | sha256sum --strict -c -
    mkdir mount
    # The first and final 1MiB hold the virtual GPT outside the ext4 interval.
    truncate -s $((size+2*offset)) dirty.raw
    printf 'label: gpt\nunit: sectors\n\nstart=256,size=%s,type=linux,name=linux\n' "$((size/4096))" | sfdisk --sector-size 4096 dirty.raw > gpt.log
    open_outer dirty.raw
    mkfs.ext4 -q -F -m 0 -U "$outer_uuid" "$loop"
    mount "$loop" mount
    install -d -m755 mount/etc/y700
    printf '%s\n' asphalt-prc-debian13-xfce-7.3.4-v1 >mount/etc/y700/image-id
    install -d -m700 mount/var/lib/y700-trial "$inner"
    cp --sparse=always "$images/root.ext4" "$images/linux-boot.fat" "$inner/"
    chmod 600 "$inner/"*
    if [[ $action == cut32 ]]; then
        e2fsck -fp "$inner/root.ext4" >resize-before.fsck 2>&1
        truncate -s 32G "$inner/root.ext4"
        resize2fs "$inner/root.ext4" >resize.log 2>&1
        e2fsck -fn "$inner/root.ext4" >resized.fsck 2>&1
    fi
    stat -c %s "$inner/root.ext4" >mount/expected-root-bytes
    head -c32 /dev/urandom | sha256sum | cut -d' ' -f1 > expected-marker
    cp expected-marker mount/expected-marker
    close_outer
    boot power-cut dirty.raw cut
    open_outer dirty.raw --read-only
    assert_dirty "$loop" > dirty-outer.log
    mount -o ro,noload,nodev,nosuid,noexec "$loop" mount
    assert_dirty "$inner/root.ext4" > dirty-inner.log
    bash "$here/fat-state.sh" "$images/linux-boot.fat" source-fat
    bash "$here/fat-state.sh" "$inner/linux-boot.fat" dirty-fat
    grep -Fq 'bpb65=0x01' dirty-fat.state
    grep -Fq 'Dirty bit is set.' dirty-fat.fsck
    close_outer
    sha256sum dirty.raw > dirty.sha256
    boot original-refused dirty.raw snapshot
    grep -F 'backing filesystem requires attention; rebooting to default' original-refused.log
    if grep -Fq 'verified persistent root=' original-refused.log; then exit 1; fi
    sha256sum -c dirty.sha256
    echo 'FILE_RECOVERY_BASELINE first_entry_refused=1 both_ext4_need_journal=1'
    exit
fi
[[ ${menu##*/} == y700-recovery-12-10.conf && ! -e recovered.raw ]]
sha256sum --check --strict dirty.sha256
cp --reflink=auto --sparse=always dirty.raw recovered.raw
dirty_digest=$(cut -d' ' -f1 dirty.sha256)
printf '%s  recovered.raw\n' "$dirty_digest" | sha256sum -c -
boot journal-recovery recovered.raw live
grep -F 'y700-file-trial: journal replayed: backing' journal-recovery.log
grep -F 'y700-file-trial: journal replayed: root' journal-recovery.log
grep -F 'FILE_RECOVERY_BOOTED correct_release=1 pid1=systemd marker=root,esp' journal-recovery.log
grep -F 'y700-file-trial: clean shutdown' journal-recovery.log
open_outer recovered.raw --read-only
clean_ext4() {
    local dev=$1 label=$2
    dumpe2fs -h "$dev" > "$label.header" 2>/dev/null
    grep -Eq '^Filesystem state:[[:space:]]+clean$' "$label.header"
    if grep -Eq '^Filesystem features:.* needs_recovery( |$)' "$label.header"; then return 1; fi
    e2fsck -fn "$dev" > "$label.fsck" 2>&1
    echo "FILE_RECOVERY_EXT4 fs=$label state=clean needs_recovery=0 fsck_status=0"
}
clean_ext4 "$loop" final-outer
mount -o ro,noload,nodev,nosuid,noexec "$loop" mount
clean_ext4 "$inner/root.ext4" final-inner
bash "$here/fat-state.sh" "$inner/linux-boot.fat" final-fat
debugfs -R 'cat /var/lib/y700/qa-recovery-marker' "$inner/root.ext4" 2>/dev/null | cmp -s - expected-marker
mtype -i "$inner/linux-boot.fat" ::/qa-recovery-marker.txt | cmp -s - expected-marker
close_outer
sha256sum --check --strict dirty.sha256
grep -Eq '^bpb65=0x00 .* fsck_status=0$' final-fat.state
if grep -Eiq 'Dirty bit is set|Free cluster summary wrong|Leaving filesystem unchanged' final-fat.fsck; then exit 1; fi
echo 'FILE_RECOVERY_PASS original_refused=1 recovered_same_snapshot=1 fsynced_markers=2 outer_ext4=clean inner_ext4=clean fat=clean' | tee result.log
# A valid, clean pair with a different release receipt must never reach systemd.
cp --reflink=auto --sparse=always recovered.raw different-release.raw
open_outer different-release.raw
mount -o nodev,nosuid,noexec "$loop" mount
mkdir wrong-inner
(
    mount --options loop,nodev,nosuid,noexec "$inner/root.ext4" wrong-inner
    trap 'umount wrong-inner' EXIT
    assert_path=wrong-inner/var/lib/y700/build/video-player-update.lock.json
    [[ $(sha256sum "$assert_path" | cut -d' ' -f1) == 39cd516bc47679ba3c7980dc3ed43a43c1bac80e40fba690c85d33d9794fd5eb ]]
    printf '{"edition":"fixture-incompatible"}\n' > "$assert_path"
)
clean_ext4 "$inner/root.ext4" refused-inner
close_outer
sha256sum different-release.raw > different-release.sha256
boot incompatible-refused different-release.raw snapshot
grep -F 'y700-file-trial: unexpected inner release receipt' incompatible-refused.log
grep -F 'Recovery stopped. At the next power-on select Debian 13 Xfce (Lenovo Y700).' incompatible-refused.log
grep -F 'reboot: Power down' incompatible-refused.log
if grep -Fq 'verified persistent root=' incompatible-refused.log; then exit 1; fi
sha256sum --strict -c different-release.sha256
rm -- different-release.raw
echo 'FILE_RECOVERY_WRONG_RELEASE refused=1 product_systemd=0' | tee -a result.log
