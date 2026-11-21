#!/usr/bin/env bash
# Build a private, volatile desktop from ordinary sealed image files.
set -euo pipefail
umask 077
export LC_ALL=C
root_sha=041fcf2e04b5d05edbfa3147f442a019d2f260f6544b9182087bf911ff8e55b6
fat_sha=495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6
kernel_sha=4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1
dt_sha=1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d
storage_guard=0
if [[ ${1:-} == --dev12.6 ]]; then
    root_sha=74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd
    shift
elif [[ ${1:-} == --dev12.8 ]]; then
    root_sha=2d03b3d2e312f1a425c5b8f657f20fddd45f07caa54b4a937590a720fa2cf511
    shift
elif [[ ${1:-} == --dev12.9 ]]; then
    root_sha=e40d2b7b297913c7200d2238f8f79d5a28926b983866cf09ca61f3dcbd8a0ddb
    shift
elif [[ ${1:-} == --dev12.10 ]]; then
    root_sha=18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd
    shift
elif [[ ${1:-} == --dev12.12 ]]; then
    root_sha=5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3
    fat_sha=1f6d75c17b5f38ff69d57e13c671bd0c1cbccf0c74cf1ea3f79e2011445ed091
    kernel_sha=0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60
    dt_sha=53bc719146da49baff7b975c06942892278639909e48d0f998b894220c7d05b7
    storage_guard=1
    shift
fi
if [[ $# != 2 ]]; then
    echo "Usage: build-ram-trial.sh [--dev12.6|--dev12.8|--dev12.9|--dev12.10|--dev12.12] IMAGES NEW_DIRECTORY" >&2
    exit 2
fi
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
images=$(realpath -e -- "$1")
[[ -d $images && ! -e $2 && ! -L $2 ]]
dest=$(realpath -m -- "$2")
source "$repo/scripts/build-storage-guard.sh" ram "${dest%/*}"
epoch=1795150416
for input in root.ext4 linux-boot.fat; do
    [[ -f $images/$input && ! -L $images/$input ]]
done
[[ $(stat -c %s "$images/root.ext4") == 6442450944 ]]
(
    cd "$images"
    printf '%s  %s\n' "$root_sha" root.ext4 "$fat_sha" linux-boot.fat | sha256sum --strict -c
)

work=$(mktemp -d -- "${dest%/*}/.y700-ram-build.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
cd "$work"
mkdir append bundle
for name in kernel.efi board.dtb; do
    mcopy -i "$images/linux-boot.fat" "::/EFI/debian/$name" "bundle/$name"
done
mcopy -i "$images/linux-boot.fat" ::/EFI/debian/initrd original-initrd
mcopy -i "$images/linux-boot.fat" ::/loader/entries/debian.conf original.conf
sha256sum --strict -c <<HASHES
$kernel_sha  bundle/kernel.efi
$dt_sha  bundle/board.dtb
6d3832e03eaea523a55c6bf12f90e1cf1146a34df1a264bdeefec9c8398d00ce  original-initrd
HASHES
if (( storage_guard )); then
    mv -- bundle/board.dtb release-board.dtb
    bash "$repo/scripts/build-diskless-dtb.sh" release-board.dtb bundle/board.dtb
    printf '%s  bundle/board.dtb\n' 8ad76f844d20ebb57f7ebcaad91c61e0484f139a1e9fdfccec02ba198c02cf82 | sha256sum --strict -c -
fi
options=$(sed -n 's/^options //p' original.conf)
read -ra stock_options <<< "$options"
ram_options=(rdinit=/y700-ram-trial-init y700.media=ram fstab=no systemd.gpt_auto=0 noresume)
for option in "${stock_options[@]}"; do
    case $option in
        rdinit=/init|root=PARTLABEL=linux|rw|androidboot.boot_devices=*) ;;
        console=*|androidboot.hardware=*|androidboot.console=*|androidboot.usbcontroller=*|clk_ignore_unused|pd_ignore_unused|mem_sleep_default=*|drm_kms_helper.fbdev_emulation=*)
            ram_options+=("$option") ;;
        *) echo "Unexpected sealed boot option: $option" >&2; exit 1 ;;
    esac
done
printf '%s\n' "${ram_options[*]}" > bundle/cmdline.txt

# The sealed ext4 stays intact (ACLs, capabilities, hard links and UUID).
# Its *compressed carrier* fits in newc; the 6-GiB ext4 is never a cpio member.
carrier=append/y700-root.squashfs
mksquashfs "$images/root.ext4" "$carrier" -noappend -no-progress -exit-on-error \
    -comp zstd -Xcompression-level 8 -b 256K -processors 4 -mem 256M -no-xattrs \
    -all-root -root-mode 0500 -p 'root.ext4 m 0400 0 0' -mkfs-time "$epoch" -all-time "$epoch"
[[ $(unsquashfs -ls "$carrier") == $'squashfs-root\nsquashfs-root/root.ext4' ]]
actual_root=$(unsquashfs -processors 2 -cat "$carrier" root.ext4 | sha256sum)
[[ ${actual_root%% *} == "$root_sha" ]]
carrier_hash=$(sha256sum "$carrier")
carrier_hash=${carrier_hash%% *}
printf 'CARRIER sha256=%s bytes=%s member=root.ext4 root_sha256=%s\n' \
    "$carrier_hash" "$(stat -c %s "$carrier")" "$root_sha"

if (( storage_guard )); then
    source_init=$repo/src/boot/ram-trial-init
    for marker in 'exec </dev/console >/dev/console 2>&1' 'fail() {' 'ram=/run/y700-ram'; do
        [[ $(grep -Fxc "$marker" "$source_init") == 1 ]]
    done
    # Install the diagnostic failure handler before the first mount check. Verify storage before opening the desktop.
    sed -e '/^fail() {/,/^}/d' -e "/^exec <\/dev\/console/r $repo/src/boot/ram-trial-storage-check" \
        -e '/^ram=\/run\/y700-ram$/i check_storage' "$source_init" > append/y700-ram-trial-init
    chmod 0755 append/y700-ram-trial-init
else
    install -m 0755 "$repo/src/boot/ram-trial-init" append/y700-ram-trial-init
fi
sh -n append/y700-ram-trial-init
chmod 0400 "$carrier"
touch -d "@$epoch" append/y700-ram-trial-init "$carrier"
# The kernel accepts a raw newc archive after a compressed initramfs. Align
# its first header to four bytes, including the stock gzip member's length.
original_size=$(stat -c %s original-initrd)
offset=$(( (original_size + 3) / 4 * 4 ))
cp original-initrd bundle/initrd
truncate -s "$offset" bundle/initrd
(
    cd append
    printf '%s\n' y700-ram-trial-init y700-root.squashfs |
        cpio --quiet --reproducible --owner 0:0 -o -H newc
) >> bundle/initrd
total=$(stat -c %s bundle/initrd)
[[ $total -lt 2147483648 ]]
cmp -n "$original_size" original-initrd bundle/initrd
read_archive() {
    tail -c "+$((offset + 1))" bundle/initrd | cpio --quiet -i --to-stdout "$1"
}
read_archive y700-ram-trial-init | cmp - append/y700-ram-trial-init
packed_hash=$(read_archive y700-root.squashfs | sha256sum)
[[ ${packed_hash%% *} == "$carrier_hash" ]]
printf 'RAM_INITRD bytes=%s newc_offset=%s carrier_sha256=%s\n' "$total" "$offset" "$carrier_hash"
cd bundle
chmod 0600 kernel.efi board.dtb initrd cmdline.txt
sha256sum kernel.efi board.dtb initrd cmdline.txt > SHA256SUMS
sha256sum --strict -c SHA256SUMS
cd "$work"
mv -T --no-clobber -- bundle "$dest"
[[ ! -e bundle ]]
