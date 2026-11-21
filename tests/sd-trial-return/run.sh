#!/usr/bin/env bash
# All disks here are disposable regular files. No mounts or device access required.
set -euo pipefail
umask 077
file_trial=0
if [[ ${1:-} == --file-trial ]]; then file_trial=1; shift; fi
[[ $# == 4 ]] || { echo 'Usage: run.sh [--file-trial] BOARD_TREE EXTRACTED_QEMU TRIAL_ENTRY NEW_LOG_DIR' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
board=$(realpath -e "$1")
qemu=$(realpath -e "$2")
entry=$(realpath -e "$3")
new_sd=0
if [[ -f $entry/loader/entries/y700-sd-12-12.conf ]]; then
    (( ! file_trial ))
    new_sd=1
fi
out=$(realpath -m "$4")
mkdir -- "$out"
t=$(mktemp -d /var/tmp/y700-menu-return.XXXXXXXX)
trap 'rm -r --one-file-system -- "$t"' EXIT
cd "$board/efi/esp"
sha256sum --strict -c <<'HASHES'
76a5bba20322d4929f35c608199f21f80317ae006805315ca215382cdef4c75b  EFI/BOOT/BOOTAA64.EFI
e518d8f7c6412541a171b5eb650755bfc2a93d5386bbc8bafeee6fd782d519f0  loader/loader.conf
0be9b2a8e86347c5f64bbe0d9688d3f20b08f4ff9d5da0d93705557dc290015e  loader/entries/debian.conf
9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db  EFI/debian/kernel.efi
bf83d82958cc0921808154afd0c9b522bde567254dac9e156384bac6b147366a  EFI/debian/initrd
1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d  EFI/debian/board.dtb
HASHES
(cd "$entry" && sha256sum --strict -c SHA256SUMS)
cd "$t"
mkdir -p root/{bin,sbin,dev,proc,sys,run,lib,etc/y700,var/lib} other/etc/y700
gzip -dc "$board/efi/esp/EFI/debian/initrd" | cpio --quiet -i --to-stdout bin/busybox > root/bin/busybox
zstd -dc "$board/modules/lib/modules/7.3.4-asphalt-prc/kernel/fs/efivarfs/efivarfs.ko.zst" > root/lib/efivarfs.ko
chmod 755 root/bin/busybox
printf '%s\n' asphalt-prc-debian13-xfce-7.3.4-v1 > root/etc/y700/image-id
printf '%s\n' baseline-canary > root/etc/y700/fixture-canary
cat > root/sbin/init <<'INIT'
#!/bin/busybox sh
set -eu
exec >/dev/ttyAMA0 2>&1
export PATH=/bin
/bin/busybox --install -s /bin
echo "SD_TRIAL_RETURN_CHECKING root=$(cat /etc/y700/image-id)"
test "$$" = 1
test "$(cat /etc/y700/image-id)" = asphalt-prc-debian13-xfce-7.3.4-v1
test "$(cat /etc/y700/fixture-canary)" = baseline-canary
test -d /sys/firmware/efi
insmod /lib/efivarfs.ko
mount -t efivarfs -o ro efivarfs /sys/firmware/efi/efivars
selected=$(cat /sys/firmware/efi/efivars/LoaderEntrySelected-* | dd bs=1 skip=4 2>/dev/null | tr -d '\000')
test "$selected" = debian.conf
case " $(cat /proc/cmdline) " in *' root=PARTLABEL=linux '*) ;; *) exit 1 ;; esac
case " $(cat /proc/cmdline) " in *' y700.media='*) exit 1 ;; esac
grep -q ' / ext4 ' /proc/mounts
expected=$(cat /etc/y700/kernel-notes.sha256)
actual=$(sha256sum /sys/kernel/notes)
test "${actual%% *}" = "$expected"
echo "SD_TRIAL_RETURN_BASELINE_PASS pid1=1 root=internal original_kernel_notes=$expected entry=$selected"
poweroff -f
INIT
chmod 755 root/sbin/init
printf '%s\n' 2e6b047aba528bfdea5549b9aae9af362a9af055bb630a650bcdd7c654ec9066 > root/etc/y700/kernel-notes.sha256
printf '%s\n' intentional-test-mismatch > other/etc/y700/image-id
if (( new_sd )); then
    printf '%s\n' y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f >other/etc/y700/image-id
    printf '%s\n' IMAGE_VERSION=dev12.11 >other/etc/os-release
fi
truncate -s 32M root.ext4
make_baseline() {
    mkfs.ext4 -Fq -d root -U ef306764-2315-4235-8796-69e2c9b61946 root.ext4
    if (( file_trial )); then
        # mkfs -d preserves the invoking user's ownership. Model root-owned
        # deployment paths inside the image even on an unprivileged build host.
        (cd root && find var -print) | while IFS= read -r path; do
            printf 'set_inode_field /%s uid 0\nset_inode_field /%s gid 0\n' "$path" "$path"
        done > dirs.debugfs
        debugfs -w -f dirs.debugfs root.ext4 >/dev/null
    fi
}
make_baseline
truncate -s 16M other.ext4
mkfs.ext4 -q -d other -U 171a4adb-916b-4763-9e6f-722b4a99988f other.ext4
truncate -s 20M wrong-card.img
printf 'label: gpt\nstart=2048,size=32768,type=linux,name=y700-test-root\n' | sfdisk --sector-size 512 wrong-card.img >/dev/null
dd if=other.ext4 of=wrong-card.img bs=1M seek=1 conv=sparse,notrunc status=none
truncate -s 304M internal.fat
mkfs.fat -F 32 -S 4096 -s 1 internal.fat >/dev/null
mmd -i internal.fat ::/EFI ::/loader ::/loader/entries
for d in BOOT debian; do mcopy -s -i internal.fat "$board/efi/esp/EFI/$d" ::/EFI/; done
mcopy -i internal.fat "$board/efi/esp/loader/loader.conf" ::/loader/
mcopy -i internal.fat "$board/efi/esp/loader/entries/debian.conf" ::/loader/entries/
name=y700-test
if (( file_trial )); then name=y700-file; fi
if (( new_sd )); then name=y700-sd-12-12; fi
mcopy -s -i internal.fat "$entry/EFI/$name" ::/EFI/
# Two real Linux menu entries; only the first boot receives a manual selection.
sed '/^options /s/$/ console=ttyAMA0/' "$entry/loader/entries/$name.conf" > "$name.conf"
title=$(sed -n 's/^title //p' "$name.conf")
mcopy -i internal.fat "$name.conf" ::/loader/entries/
for d in debian "$name"; do mcopy -o -i internal.fat "$board/efi/vm/board.dtb" "::/EFI/$d/board.dtb"; done
for f in loader/loader.conf loader/entries/debian.conf EFI/BOOT/BOOTAA64.EFI EFI/debian/kernel.efi EFI/debian/initrd; do
    mtype -i internal.fat "::$f" | cmp "$board/efi/esp/$f" -
done
mtype -i internal.fat "::/EFI/$name/initrd" | cmp "$entry/EFI/$name/initrd" -
truncate -s 340M internal.img
printf 'label: gpt\nstart=256,size=77824,type=uefi,name=linux-boot\nstart=78080,size=8192,type=linux,name=linux\n' | sfdisk --sector-size 4096 internal.img >/dev/null
dd if=internal.fat of=internal.img bs=1M seek=1 conv=sparse,notrunc status=none
dd if=root.ext4 of=internal.img bs=1M seek=305 conv=sparse,notrunc status=none
scenarios=(wrong-identity absent)
if (( file_trial )); then scenarios=(file-absent file-symlink file-identity); fi
if (( new_sd )); then scenarios=(sd12-old-release sd12-wrong-fat sd12-absent); fi
for scenario in "${scenarios[@]}"; do
    case $scenario in
        sd12-wrong-fat)
            mkdir -p other/var/lib/y700/build
            cp "$here/../../config/platform-desktop-update.lock.json" other/var/lib/y700/build/
            printf '%s\n' IMAGE_VERSION=dev12.12 >other/etc/os-release
            printf '%s\n' 'PARTLABEL=y700-test-root / ext4 defaults 0 1' 'UUID=12DC-1212 /boot vfat umask=0077 0 2' >other/etc/fstab
            mkfs.ext4 -Fq -d other -U 171a4adb-916b-4763-9e6f-722b4a99988f other.ext4
            truncate -s 64M other.fat
            mkfs.fat -F 32 -i 171A4ADB other.fat >/dev/null
            truncate -s 83M wrong-card.img
            printf 'label: gpt\nstart=2048,size=131072,type=uefi,name=y700-test-esp\nstart=133120,size=32768,type=linux,name=y700-test-root\n' |
                sfdisk --sector-size 512 wrong-card.img >/dev/null
            dd if=other.fat of=wrong-card.img bs=1M seek=1 conv=notrunc status=none
            dd if=other.ext4 of=wrong-card.img bs=1M seek=65 conv=notrunc status=none
            ;;
        file-symlink)
            private=root/var/lib/y700-trial/dev12.5
            mkdir -p "$private"
            chmod 700 "$private" "${private%/*}"
            ln -s /etc/y700/fixture-canary "$private/root.ext4"
            ;;
        file-identity)
            rm -- "$private/root.ext4"
            cp --sparse=always other.ext4 "$private/root.ext4"
            truncate -s 6G "$private/root.ext4"
            truncate -s 1G "$private/linux-boot.fat"
            mkfs.fat -F32 -i 171A4ADB "$private/linux-boot.fat" >/dev/null
            chmod 600 "$private"/*
            ;;
    esac
    if [[ $scenario == file-symlink || $scenario == file-identity ]]; then
        make_baseline
        dd if=root.ext4 of=internal.img bs=1M seek=305 conv=notrunc status=none
    fi
    sha256sum internal.img wrong-card.img > originals.sha256
    "${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python "$here/firmware.py" "$qemu" "$board/efi/qemu-uboot/u-boot.bin" "$out" "$scenario" "$title"
    sha256sum --strict -c originals.sha256
done
if (( file_trial )); then echo FILE_TRIAL_THREE_RETURNS_PASS
elif (( new_sd )); then echo DEV1212_SD_THREE_RETURNS_PASS
else echo SD_TRIAL_BOTH_RETURNS_PASS; fi
