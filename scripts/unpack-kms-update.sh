#!/usr/bin/env bash
# Reconstruct the updated development image from the compressed base and QCOW2.
set -euo pipefail
umask 077
usage() { echo "Usage: bash $0 --verify | [--bluetooth-address PRIVATE_FILE] NEW_DIRECTORY" >&2; exit 2; }
fail() { echo "$1" >&2; exit 1; }

personalize=false
case ${1:-} in
    --bluetooth-address)
        set +x
        (( $# == 3 )) || usage
        private_file=$2
        shift 2
        [[ $1 != --verify ]] || usage
        personalize=true ;;
    *) (( $# == 1 )) || usage ;;
esac

read_private_address() {
    local source=$1 before metadata fd opened owner mode links size read_size LC_ALL=C
    local signature='%d:%i:%f:%u:%g:%h:%s:%y:%z'
    local invalid='Bluetooth address input must be one private, caller-owned regular file'
    [[ -f $source && ! -L $source ]] || fail "$invalid"
    before=$(stat -c "$signature" -- "$source" 2>/dev/null) || fail "$invalid"
    { exec {fd}<"$source"; } 2>/dev/null || fail "$invalid"
    opened=/proc/$BASHPID/fd/$fd
    [[ ! -L $source && -f $opened && $(stat -Lc "$signature" -- "$opened") == "$before" ]] || fail "$invalid"
    metadata=$(stat -Lc '%u %a %h %s' -- "$opened")
    read -r owner mode links size <<< "$metadata"
    [[ $owner == "$EUID" && ( $mode == 600 || $mode == 400 ) && $links == 1 ]] || fail "$invalid"
    [[ $size == 17 || $size == 18 ]] || fail 'Expected exactly one Bluetooth address'
    if IFS= read -rn 18 bluetooth_address <&"$fd"; then read_size=18; else read_size=17; fi
    [[ ! -L $source && $(stat -c "$signature" -- "$source") == "$before" &&
        $(stat -Lc "$signature" -- "$opened") == "$before" ]] || fail "$invalid"
    exec {fd}<&-
    bluetooth_address=${bluetooth_address^^}
    [[ $read_size == "$size" && $bluetooth_address =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] ||
        fail 'Expected exactly one Bluetooth address'
    case $bluetooth_address in
        00:00:00:00:00:00|FF:FF:FF:FF:FF:FF|02:00:00:00:00:00) fail 'Bluetooth address is a placeholder' ;;
    esac
    (( (16#${bluetooth_address:0:2} & 1) == 0 )) || fail 'Bluetooth address is not a unicast address'
}

# debugfs can return zero for a rejected command. Strip only its version banner.
debugfs_output() {
    local reply
    reply=$(LC_ALL=C debugfs "$@" root.ext4 2>&1) || return 1
    [[ $reply == debugfs\ * ]] || return 1
    if [[ $reply == *$'\n'* ]]; then printf '%s\n' "${reply#*$'\n'}"; fi
}

personalize_root() {
    local path=/etc/y700/bluetooth-address dir info result field
    local root_owner='^User:[[:blank:]]+0[[:blank:]]+Group:[[:blank:]]+0[[:blank:]]'
    [[ -f root.ext4 && ! -L root.ext4 && $(stat -c %h root.ext4) == 1 ]] ||
        fail 'Expected an independent staged root image'
    for dir in /etc /etc/y700; do
        info=$(debugfs_output -R "stat $dir") || fail 'Could not examine the staged root image'
        grep -Eq '^Inode: [0-9]+[[:blank:]]+Type: directory[[:blank:]]+Mode:[[:blank:]]+07[0145][0145][[:blank:]]' <<< "$info" &&
            grep -Eq "$root_owner" <<< "$info" || fail 'Unexpected directory metadata in the staged root image'
    done
    info=$(debugfs_output -R "stat $path") || fail 'Could not examine the staged Bluetooth address path'
    [[ ${info% } == "$path: File not found by ext2_lookup" ]] ||
        fail 'Bluetooth address path already exists or could not be checked'

    printf '%s\n' "$bluetooth_address" > ../bluetooth-input
    unset bluetooth_address
    result=$(debugfs_output -w -R "write ../bluetooth-input $path") || fail 'Bluetooth address write failed'
    [[ $result =~ ^Allocated\ inode:\ [0-9]+$ ]] || fail 'Bluetooth address write failed'
    for field in 'uid 0' 'gid 0' 'mode 0100600'; do
        result=$(debugfs_output -w -R "set_inode_field $path $field") || fail 'Bluetooth address metadata write failed'
        [[ -z $result ]] || fail 'Bluetooth address metadata write failed'
    done

    info=$(debugfs_output -R "stat $path") || fail 'Bluetooth address readback failed'
    grep -Eq '^Inode: [0-9]+[[:blank:]]+Type: regular[[:blank:]]+Mode:[[:blank:]]+0600[[:blank:]]' <<< "$info" &&
        grep -Eq "$root_owner.*Size: 18$" <<< "$info" &&
        grep -Eq '^Links: 1[[:blank:]]' <<< "$info" || fail 'Bluetooth address metadata readback failed'
    result=$(debugfs_output -R "dump $path ../bluetooth-readback") || fail 'Bluetooth address readback failed'
    [[ -z $result ]] && cmp -s -- ../bluetooth-input ../bluetooth-readback || fail 'Bluetooth address readback failed'
    rm -- ../bluetooth-input ../bluetooth-readback
    LC_ALL=C e2fsck -fn root.ext4 >/dev/null 2>&1 || fail 'Personalized ext4 image failed its filesystem check'

    mv -T -- SHA256SUMS UNPERSONALIZED-SHA256SUMS
    sha256sum asphalt-prc-u-boot.img linux-boot.fat root.ext4 identity.txt > SHA256SUMS
    sha256sum --strict -c SHA256SUMS
}

bundle=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
manifest_names() {
    local source=$1 name pattern='^[0-9a-f]{64}  ' record
    shift
    local -a rows
    mapfile -t rows < "$source"
    (( ${#rows[@]} == $# )) || return 1
    for record in "${rows[@]}"; do
        name=$1; shift
        [[ $record =~ $pattern && ${record:66} == "$name" ]] || return 1
    done
}
patch=
extras=(y700-camera-qcam_0.7.2-1~bpo13+1.y7002_arm64.deb blueman_2.4.4-1+y7001_arm64.deb chinese-ime.tar xorg-dsi.tar)
for version in dev8 dev9 dev10 dev11.1 dev12.1 dev12.2; do
    expected=(base/SHA256SUMS base/unpack.sh "$version.qcow2" identity.txt RAW-SHA256SUMS
        "y700-platform_0.1.0~${version}_all.deb")
    case $version in
        dev8) counts=(0) ;;
        dev9) counts=(0 1 2 3) ;;
        dev10) counts=(3 4) ;;
        dev11.1|dev12.1|dev12.2) counts=(4) ;;
    esac
    for count in "${counts[@]}"; do
        if manifest_names "$bundle/SHA256SUMS" "${expected[@]}" "${extras[@]:0:count}"; then
            patch=$version.qcow2
            break 2
        fi
    done
done
[[ -n $patch ]] || { echo 'Unsupported update manifest' >&2; exit 1; }
manifest_names "$bundle/RAW-SHA256SUMS" asphalt-prc-u-boot.img linux-boot.fat root.ext4 identity.txt
manifest_names "$bundle/base/SHA256SUMS" asphalt-prc-u-boot.img.zst linux-boot.fat.zst root.ext4.zst identity.txt RAW-SHA256SUMS
if [[ $1 != --verify ]]; then
    [[ -n $1 && $1 != -* && $1 != */ ]] || exit 2
    parent=$(cd -- "$(dirname -- "$1")" && pwd -P)
    target=$parent/$(basename -- "$1")
    [[ ! -e $target && ! -L $target ]] || { echo 'Choose a new destination' >&2; exit 1; }
    # Reserve the three logical image sizes plus the private overlay and metadata.
    available=$(df -B1 --output=avail "$parent" | tail -1)
    required=$((41406464 + 1073741824 + 6442450944 + $(stat -Lc %s "$bundle/$patch") + 16777216))
    (( available >= required )) || { echo "Need $required free bytes at the destination" >&2; exit 1; }
fi
(cd "$bundle" && sha256sum --strict -c SHA256SUMS)
if [[ $1 == --verify ]]; then
    bash "$bundle/base/unpack.sh" --verify
    echo 'Compressed base and update payload verified. Extraction checks the complete resulting raw image.'
    exit
fi
command -v qemu-img >/dev/null
if $personalize; then
    command -v debugfs >/dev/null && command -v e2fsck >/dev/null || fail 'Bluetooth personalization requires e2fsprogs'
    read_private_address "$private_file"
fi
stage=$(mktemp -d --tmpdir="$parent" ".y700-$version.XXXXXXXX")
cleanup() {
    if [[ -d $stage ]]; then
        rm -f -- "$stage/image/"{asphalt-prc-u-boot.img,linux-boot.fat,root.ext4,identity.txt,SHA256SUMS,UNPERSONALIZED-SHA256SUMS} \
            "$stage/image/$patch" "$stage/"{bluetooth-input,bluetooth-readback}
        if [[ -d $stage/image ]]; then rmdir -- "$stage/image"; fi
        rmdir -- "$stage"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
bash "$bundle/base/unpack.sh" "$stage/image"
cd "$stage/image"
# Use a private overlay copy; only the freshly unpacked regular file is writable.
[[ -f root.ext4 && ! -L root.ext4 && $(stat -c %h root.ext4) == 1 ]]
cp --sparse=always -- "$bundle/$patch" "$patch"
qemu-img check -f qcow2 "$patch"
qemu-img commit -d -f qcow2 -b "$stage/image/root.ext4" "$patch"
rm -- "$patch"
cp -- "$bundle/identity.txt" identity.txt
cp -- "$bundle/RAW-SHA256SUMS" SHA256SUMS
sha256sum --strict -c SHA256SUMS
if $personalize; then personalize_root; fi
cd "$stage"
mv -T --no-clobber -- image "$target"
[[ ! -e image ]] || { echo 'The destination appeared during extraction' >&2; exit 1; }
printf 'Unpacked and verified %s\n' "$target"
