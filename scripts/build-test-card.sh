#!/usr/bin/env bash
# Assemble regular files only. The caller provides a new DIRECTORY, never a drive.
set -euo pipefail
export LC_ALL=C TZ=UTC
umask 077
repo=$(realpath -e "$(dirname "$0")/..")
source "$repo/packaging/sd-trial/dual-release.sh"
images=$(realpath -e "${1:?completed candidate directory}")
out=$(realpath -m "${2:?new card output directory}")
source "$repo/scripts/build-storage-guard.sh" card "${out%/*}"
mkdir -m700 -- "$out"
cd "$images"
sha256sum -c SHA256SUMS
cd "$out"
mkdir esp
mcopy -s -i "$images/linux-boot.fat" ::/EFI ::/loader esp/
# Android actions apply to the tablet, not to these removable media.
rm esp/loader/entries/{android,bootloader,recovery-b}.conf
for bls in esp/loader/entries/*.conf; do
    grep -Eq '^options .*root=PARTLABEL=linux ' "$bls"
    sed -i '/^options /s|root=PARTLABEL=linux |root=PARTLABEL=y700-test-root y700.media=sd |' "$bls"
    grep -Fq 'root=PARTLABEL=y700-test-root y700.media=sd ' "$bls"
done
root=$images/root.ext4
fatid=$(blkid -p -s UUID -o value "$images/linux-boot.fat" | tr -d '-')
format=()
layout=$'label: gpt\nunit: sectors\n\nstart=2048, size=2097152, type=uefi, name=y700-test-esp\nstart=2099200, size=12582912, type=linux, name=y700-test-root'
if [[ -f esp/loader/entries/debian-120.conf ]]; then
    # The generic initrd authenticates the root UUID, then chooses the root by physical
    # controller and GPT label. Give /boot a distinct FAT UUID when UFS is also present.
    sd_release "$(sed -n 's/^title Y700 \(dev[0-9.]*\) .*/\1/p' esp/loader/entries/debian.conf)"
    grep -Fxq "$sd_esp  linux-boot.fat" "$images/SHA256SUMS"
    grep -Fxq "$sd_root  root.ext4" "$images/SHA256SUMS"
    grep -Fxq "package_digest=$sd_inventory" "$images/identity.txt"
    cp "$images/SHA256SUMS" SOURCE-SHA256SUMS
    bash "$repo/scripts/add-sd-trial-return.sh" "--$edition" esp/EFI/debian/initrd sd-initrd
    mv -T sd-initrd esp/EFI/debian/initrd
    for bls in esp/loader/entries/debian{,-120}.conf; do
        grep -Eq '^options rdinit=/init root=PARTLABEL=y700-test-root y700.media=sd ' "$bls"
        if grep -Eq '(^| )panic=' "$bls"; then exit 1; fi
        sed -i "/^options /{ s| rdinit=/init | rdinit=/y700-dev${sd_suffix}-sd-init |; s/$/ panic=15/; }" "$bls"
    done
    rootuuid=$(blkid -p -s UUID -o value "$root")
    [[ $rootuuid == 171a4adb-916b-4763-9e6f-722b4a99988f && $fatid == 171A4ADB ]]
    epoch=$(date -d "$(dumpe2fs -h "$root" 2>/dev/null | sed -n 's/^Last write time: *//p')" +%s)
    export SOURCE_DATE_EPOCH=$epoch MTOOLSRC=/dev/null
    fatid=${sd_boot_uuid/-/}; format=(--invariant)
    layout="label: gpt
label-id: $sd_disk_id
unit: sectors

start=2048, size=2097152, type=uefi, uuid=$sd_esp_id, name=y700-test-esp
start=2099200, size=12582912, type=linux, uuid=$sd_root_id, name=y700-test-root"
    debugfs -R 'cat /etc/fstab' "$root" >original.fstab
    grep -Fxq "UUID=$rootuuid / ext4 defaults 0 1" original.fstab
    grep -Fxq 'UUID=171A-4ADB /boot vfat umask=0077 0 2' original.fstab
    sed -e "s|^UUID=$rootuuid / |PARTLABEL=y700-test-root / |" \
        -e "s|^UUID=171A-4ADB /boot |UUID=$sd_boot_uuid /boot |" original.fstab >card.fstab
    chmod 644 card.fstab; touch -d "@$epoch" card.fstab
    cp --sparse=always --reflink=auto "$root" card-root.ext4
    chmod u+w card-root.ext4
    {
        printf 'rm /etc/fstab\nwrite card.fstab /etc/fstab\n'
        for field in atime ctime mtime crtime; do printf 'set_inode_field /etc/fstab %s @%s\n' "$field" "$epoch"; done
        printf 'set_inode_field /etc/fstab uid 0\nset_inode_field /etc/fstab gid 0\n'
    } | E2FSPROGS_FAKE_TIME="$epoch" debugfs -w -f - card-root.ext4
    root=$out/card-root.ext4
    debugfs -R 'cat /etc/fstab' "$root" | cmp - card.fstab
    e2fsck -fn "$root"
fi
truncate -s 1G card-esp.fat
mkfs.fat "${format[@]}" -F 32 -S 512 -s 8 -i "$fatid" -n Y700TEST card-esp.fat
[[ $(blkid -p -s UUID -o value card-esp.fat | tr -d '-') == "$fatid" ]]
mcopy -s -i card-esp.fat esp/EFI esp/loader ::/
fsck.fat -vn card-esp.fat
mkdir check
mcopy -s -i card-esp.fat ::/EFI ::/loader check/
diff -qr esp check
truncate -s 7171M y700-test-card.img
printf '%s\n' "$layout" | sfdisk --sector-size 512 y700-test-card.img
dd if=card-esp.fat of=y700-test-card.img bs=1M seek=1 conv=sparse,notrunc status=none
dd if="$root" of=y700-test-card.img bs=1M seek=1025 conv=sparse,notrunc status=none
cmp -n 1073741824 card-esp.fat y700-test-card.img 0 1048576
cmp -n 6442450944 "$root" y700-test-card.img 0 1074790400
sha256sum y700-test-card.img > SHA256SUMS
