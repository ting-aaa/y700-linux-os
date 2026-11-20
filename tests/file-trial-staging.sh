#!/usr/bin/env bash
# Exercise the production stream receiver on a disposable ext4 image.
set -euo pipefail
[[ $EUID == 0 && ( $# == 1 || $# == 2 && $2 == --inherit-bluetooth ) ]] || { echo 'Usage (root): file-trial-staging.sh UNPACKED_GENERIC_DIRECTORY [--inherit-bluetooth]' >&2; exit 2; }
if [[ ${Y700_STAGING_PRIVATE:-0} != 1 ]]; then
    exec unshare --mount --propagation private env Y700_STAGING_PRIVATE=1 bash "$0" "$@"
fi
images=$(realpath -e -- "$1")
receiver=$(realpath -e -- "$(dirname "$0")/../scripts/stage-file-trial-images.sh")
work=$(mktemp -d /var/tmp/y700-file-stage.XXXXXXXX)
cleanup() {
    if mountpoint -q -- "$work/host"; then umount -- "$work/host"; fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir "$work/host"
fallocate -l 9G "$work/outer.ext4"
mkfs.ext4 -q -U ef306764-2315-4235-8796-69e2c9b61946 "$work/outer.ext4"
mount -o loop,nosuid,nodev "$work/outer.ext4" "$work/host"
host=$work/host
mkdir -p "$host/etc/y700" "$host/var/lib"
printf '%s\n' asphalt-prc-debian13-xfce-7.3.4-v1 > "$host/etc/y700/image-id"
parent=$host/var/lib/y700-trial
ln -s "$work" "$parent"
if bash "$receiver" "$host" </dev/null; then exit 1; fi
test -L "$parent"
rm -- "$parent"
if bash "$receiver" "$host" </dev/null; then exit 1; fi
[[ -d $parent && -z $(ls -A "$parent") ]]
exec {lock_fd}<"$parent"
flock -n "$lock_fd"
if bash "$receiver" "$host" </dev/null; then exit 1; fi
flock -u "$lock_fd"
exec {lock_fd}<&-
options=()
if [[ ${2:-} == --inherit-bluetooth ]]; then
    options=(--inherit-bluetooth)
    source_id=$host/etc/y700/bluetooth-address
    reject_identity() {
        if bash "$receiver" --inherit-bluetooth "$host" </dev/null > "$work/rejected" 2>&1; then exit 1; fi
        grep -Fq -- "$1" "$work/rejected"
        [[ -z $(ls -A "$parent") ]]
    }
    reject_identity 'expected the installed identity'
    ln -s "$host/etc/y700/image-id" "$source_id"
    reject_identity 'expected the installed identity'
    rm -- "$source_id"
    printf '%s\n' '02:00:00:00:00:00' > "$source_id"
    chmod 0644 "$source_id"
    reject_identity 'private root-owned identity'
    chmod 0600 "$source_id"
    reject_identity 'placeholder Bluetooth address'
    printf '03:00:00:00:00:ab\n' > "$source_id"
    reject_identity 'unicast Bluetooth address'
    printf '02:00:00:00:00:ab\0' > "$source_id"
    reject_identity 'invalid identity encoding'
    printf '02:00:00:00:00:ab' > "$source_id"
    chmod 0400 "$source_id"
    mkdir -p "$host/var/lib/bluetooth/synthetic"
    touch "$host/var/lib/bluetooth/synthetic/pairing-sentinel"
fi
cat "$images/root.ext4" "$images/linux-boot.fat" | bash "$receiver" "${options[@]}" "$host" | tee "$work/staging.log"
if bash "$receiver" "$host" </dev/null; then exit 1; fi
for file in root.ext4 linux-boot.fat; do
    dest=$parent/dev12.5/$file
    if [[ ${2:-} == --inherit-bluetooth && $file == root.ext4 ]]; then
        printf '%s\n' '02:00:00:00:00:AB' | cmp - <(debugfs -R 'cat /etc/y700/bluetooth-address' "$dest" 2>/dev/null)
        printf '02:00:00:00:00:ab' | cmp - "$source_id"
        [[ $(stat -c %a "$source_id") == 400 ]]
        [[ ! -e $parent/dev12.5/.bluetooth-input ]]
        debugfs -R 'stat /var/lib/bluetooth/synthetic/pairing-sentinel' "$dest" 2>&1 | grep -Fq 'File not found'
        grep -Fq 'FILE_TRIAL_BLUETOOTH_PASS' "$work/staging.log"
        if grep -Fqi '02:00:00:00:00:' "$work/staging.log"; then exit 1; fi
        e2fsck -fn "$dest" >/dev/null
    else
        cmp "$images/$file" "$dest"
    fi
    [[ $(stat -c '%u:%g:%a:%h' "$dest") == 0:0:600:1 ]]
    (( $(stat -c %b "$dest") * 512 >= $(stat -c %s "$dest") ))
done
[[ $(stat -c '%u:%g:%a' "$parent/dev12.5") == 0:0:700 ]]
umount "$host"
e2fsck -fn "$work/outer.ext4"
echo FILE_TRIAL_STAGE_REGRESSION_PASS
