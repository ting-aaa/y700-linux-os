#!/usr/bin/env bash
# Receive root.ext4 followed by linux-boot.fat on stdin. Publish only the verified pair.
set -euo pipefail
export LC_ALL=C
umask 077
die() { echo "File trial staging: $*" >&2; exit 1; }
edition=dev12.5
generic_sha=041fcf2e04b5d05edbfa3147f442a019d2f260f6544b9182087bf911ff8e55b6
esp_sha=495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6
if [[ ${1:-} == --dev12.10 ]]; then
    edition=dev12.10
    generic_sha=18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd
    shift
elif [[ ${1:-} == --dev12.11 ]]; then
    edition=dev12.11
    generic_sha=33ce23e8edac1d9c445c6b360a6355a189a151804352b032efe51320287d17a3
    esp_sha=92d47c14c4606d106ebad21ece8f5e23f244bd5aecea0c377bbe8966f8261b36
    shift
fi
inherit_bt=false
if [[ ${1:-} == --inherit-bluetooth ]]; then
    set +x
    inherit_bt=true
    shift
fi
[[ $# == 1 || $# == 2 && $inherit_bt == false && $edition == dev12.5 ]] || die 'usage: stage-file-trial-images.sh [--dev12.10|--dev12.11] [--inherit-bluetooth] MOUNTED_BASELINE [DEV12.5_PERSONAL_ROOT_SHA256]'
[[ $edition != dev12.11 || $inherit_bt == false ]] || die 'dev12.11 identity comes from the running installed desktop during personalization'
[[ $EUID == 0 ]] || die 'the images and their staging directories must belong to root'
root_sha=${2:-$generic_sha}
base=$(realpath -e -- "$1")
[[ $root_sha =~ ^[0-9a-f]{64}$ && -d $base ]] || die 'invalid root digest or mount'
[[ $(findmnt -nro FSTYPE -M "$base") == ext4 ]] || die 'expected the mounted ext4 baseline'
[[ $(findmnt -nro UUID -M "$base") == ef306764-2315-4235-8796-69e2c9b61946 ]] || die 'baseline filesystem UUID mismatch'
[[ $(cat "$base/etc/y700/image-id") == asphalt-prc-debian13-xfce-7.3.4-v1 ]] || die 'baseline image ID mismatch'
if $inherit_bt; then
    source_id="${base%/}/etc/y700/bluetooth-address"
    [[ -f $source_id && ! -L $source_id && $(realpath -e -- "$source_id") == "$source_id" &&
       $(findmnt -nro TARGET -T "$source_id") == "$base" ]] || die 'expected the installed identity on this baseline'
    exec {id_fd}<"$source_id"
    opened_id=/proc/$$/fd/$id_fd
    [[ $(stat -Lc '%d:%i' "$opened_id") == "$(stat -c '%d:%i' -- "$source_id")" &&
       $(stat -Lc '%u:%h:%a' "$opened_id") =~ ^0:1:(400|600)$ ]] || die 'expected a private root-owned identity'
    id_size=$(stat -Lc %s "$opened_id")
    [[ $id_size == 17 || $id_size == 18 ]] || die 'invalid identity size'
    address=$(cat "$opened_id")
    [[ $address =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || die 'invalid Bluetooth address'
    if [[ $id_size == 18 ]]; then fmt='%s\n'; else fmt='%s'; fi
    printf "$fmt" "$address" | cmp -s - "$opened_id" || die 'invalid identity encoding'
    exec {id_fd}<&-
    address=${address^^}
    case $address in 00:00:00:00:00:00|FF:FF:FF:FF:FF:FF|02:00:00:00:00:00) die 'placeholder Bluetooth address';; esac
    (( (16#${address:0:2} & 1) == 0 )) || die 'expected a unicast Bluetooth address'
fi
parent="${base%/}/var/lib/y700-trial"
[[ $(realpath -e -- "${parent%/*}") == "${parent%/*}" ]] || die 'unexpected baseline directory link'
if ! mkdir -m700 -- "$parent" 2>/dev/null; then
    [[ -d $parent && ! -L $parent && $(stat -c '%u:%g:%a' -- "$parent") == 0:0:700 ]] || die 'expected a private root-owned trial directory'
fi
[[ $(findmnt -nro TARGET -T "$parent") == "$base" ]] || die 'trial data must reside directly on the baseline filesystem'
exec {lock_fd}<"$parent"
flock -n "$lock_fd" || die 'another staging operation is active'
target=$parent/$edition
if [[ $edition == dev12.11 ]]; then
    [[ ! -e $target && ! -L $target ]] || die 'the installed dev12.11 directory already exists'
    target=$parent/.dev12.11-input
fi
[[ ! -e $target && ! -L $target ]] || die "$edition already exists; its saved state is retained"
stage=$(mktemp -d -- "$parent/.stage-$edition.XXXXXXXX")
cleanup() {
    if [[ -d $stage ]]; then rm -f -- "$stage/root.ext4" "$stage/linux-boot.fat" "$stage/.bluetooth-input"; rmdir -- "$stage"; fi
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
if $inherit_bt; then
    # This mode accepts only the exact generic root hash, before personalization.
    # Never open the baseline image or its pairing database for writing.
    path=/etc/y700/bluetooth-address
    printf '%s\n' "$address" > .bluetooth-input
    unset address
    write_report=$(debugfs -w -R "write .bluetooth-input $path" root.ext4 2>&1)
    grep -Eq '^Allocated inode: [0-9]+$' <<< "$write_report" || die 'could not add the identity to the trial'
    info=$(debugfs -R "stat $path" root.ext4 2>/dev/null)
    grep -Eq '^Inode: [0-9]+[[:blank:]]+Type: regular[[:blank:]]+Mode:[[:blank:]]+0600' <<< "$info" &&
        grep -Eq '^User:[[:blank:]]+0[[:blank:]]+Group:[[:blank:]]+0[[:blank:]].*Size: 18$' <<< "$info" &&
        grep -Eq '^Links: 1[[:blank:]]' <<< "$info" || die 'incorrect identity metadata in the trial'
    debugfs -R "cat $path" root.ext4 2>/dev/null | cmp -s -- .bluetooth-input - || die 'identity readback mismatch'
    rm -- .bluetooth-input
    e2fsck -fn root.ext4 >/dev/null 2>&1 || die 'personalized trial filesystem check failed'
    echo 'FILE_TRIAL_BLUETOOTH_PASS source=baseline mode=0600'
fi
cd "$parent"
mv -nT -- "$stage" "$target"
[[ ! -e $stage ]] || die 'destination appeared during staging'
sync -f "$parent"
echo "FILE_TRIAL_STAGE_PASS files=2 published=${target##*/}"
