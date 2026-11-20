#!/usr/bin/env bash
# Exercise the production stream receiver on a disposable ext4 image.
set -euo pipefail
[[ $EUID == 0 && $# == 1 ]] || { echo 'Usage (root): file-trial-staging.sh UNPACKED_GENERIC_DIRECTORY' >&2; exit 2; }
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
cat "$images/root.ext4" "$images/linux-boot.fat" | bash "$receiver" "$host"
if bash "$receiver" "$host" </dev/null; then exit 1; fi
for file in root.ext4 linux-boot.fat; do
    dest=$parent/dev12.5/$file
    cmp "$images/$file" "$dest"
    [[ $(stat -c '%u:%g:%a:%h' "$dest") == 0:0:600:1 ]]
    (( $(stat -c %b "$dest") * 512 >= $(stat -c %s "$dest") ))
done
[[ $(stat -c '%u:%g:%a' "$parent/dev12.5") == 0:0:700 ]]
umount "$host"
e2fsck -fn "$work/outer.ext4"
echo FILE_TRIAL_STAGE_REGRESSION_PASS
