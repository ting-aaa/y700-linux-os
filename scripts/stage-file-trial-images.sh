#!/usr/bin/env bash
# Receive root.ext4 followed by linux-boot.fat on stdin. Publish only the verified pair.
set -euo pipefail
export LC_ALL=C
umask 077
die() { echo "File trial staging: $*" >&2; exit 1; }
[[ $# == 1 || $# == 2 ]] || die 'usage: stage-file-trial-images.sh MOUNTED_BASELINE [EXPECTED_PERSONAL_ROOT_SHA256]'
[[ $EUID == 0 ]] || die 'the images and their staging directories must belong to root'
root_sha=${2:-041fcf2e04b5d05edbfa3147f442a019d2f260f6544b9182087bf911ff8e55b6}
esp_sha=495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6
base=$(realpath -e -- "$1")
[[ $root_sha =~ ^[0-9a-f]{64}$ && -d $base ]] || die 'invalid root digest or mount'
[[ $(findmnt -nro FSTYPE -M "$base") == ext4 ]] || die 'expected the mounted ext4 baseline'
[[ $(findmnt -nro UUID -M "$base") == ef306764-2315-4235-8796-69e2c9b61946 ]] || die 'baseline filesystem UUID mismatch'
[[ $(cat "$base/etc/y700/image-id") == asphalt-prc-debian13-xfce-7.3.4-v1 ]] || die 'baseline image ID mismatch'
parent="${base%/}/var/lib/y700-trial"
[[ $(realpath -e -- "${parent%/*}") == "${parent%/*}" ]] || die 'unexpected baseline directory link'
if ! mkdir -m700 -- "$parent" 2>/dev/null; then
    [[ -d $parent && ! -L $parent && $(stat -c '%u:%g:%a' -- "$parent") == 0:0:700 ]] || die 'expected a private root-owned trial directory'
fi
[[ $(findmnt -nro TARGET -T "$parent") == "$base" ]] || die 'trial data must reside directly on the baseline filesystem'
exec {lock_fd}<"$parent"
flock -n "$lock_fd" || die 'another staging operation is active'
target=$parent/dev12.5
[[ ! -e $target && ! -L $target ]] || die 'dev12.5 already exists; its saved state is retained'
stage=$(mktemp -d -- "$parent/.stage-dev12.5.XXXXXXXX")
cleanup() {
    if [[ -d $stage ]]; then rm -f -- "$stage/root.ext4" "$stage/linux-boot.fat"; rmdir -- "$stage"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cd "$stage"
# Reserve both files before reading so later guest writes cannot exhaust the host by filling their holes.
fallocate -l 6442450944 root.ext4
fallocate -l 1073741824 linux-boot.fat
receive() {
    local file=$1 mib=$2 sha=$3
    local report
    # Count full input blocks as well as checking the digest: a short all-zero
    # tail might otherwise match bytes already present in the preallocation.
    report=$(dd of="$file" bs=1M count="$mib" iflag=fullblock conv=notrunc,fsync status=noxfer 2>&1) || die "$file write failed: $report"
    [[ ${report%%$'\n'*} == "$mib+0 records in" ]] || die "short $file stream"
    printf '%s  %s\n' "$sha" "$file" | sha256sum --strict -c -
    [[ $(stat -c '%u:%g:%a:%h' -- "$file") == 0:0:600:1 ]] || die 'unexpected image ownership or links'
}
receive root.ext4 6144 "$root_sha"
receive linux-boot.fat 1024 "$esp_sha"
[[ $(head -c 1 | wc -c) -eq 0 ]] || die 'trailing bytes after the EFI image'
[[ $(blkid -p -o value -s UUID root.ext4) == 171a4adb-916b-4763-9e6f-722b4a99988f ]] || die 'unexpected inner root UUID'
[[ $(debugfs -R 'cat /etc/y700/image-id' root.ext4 2>/dev/null) == y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f ]] || die 'inner system identity mismatch'
cd "$parent"
mv -nT -- "$stage" "$target"
[[ ! -e $stage ]] || die 'destination appeared during staging'
sync -f "$parent"
echo 'FILE_TRIAL_STAGE_PASS files=2 published=dev12.5'
