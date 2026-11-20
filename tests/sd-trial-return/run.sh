#!/usr/bin/env bash
# All disks here are disposable regular files. No mounts or device access required.
set -euo pipefail
umask 077
[[ $# == 4 ]] || { echo 'Usage: run.sh BOARD_TREE EXTRACTED_QEMU TRIAL_ENTRY NEW_LOG_DIR' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
board=$(realpath -e "$1")
qemu=$(realpath -e "$2")
entry=$(realpath -e "$3")
out=$(realpath -m "$4")
mkdir -- "$out"
t=$(mktemp -d)
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
mkdir -p root/{bin,sbin,dev,proc,sys,run,lib,etc/y700} other/etc/y700
gzip -dc "$board/efi/esp/EFI/debian/initrd" | cpio --quiet -i --to-stdout bin/busybox > root/bin/busybox
zstd -dc "$board/modules/lib/modules/7.3.4-asphalt-prc/kernel/fs/efivarfs/efivarfs.ko.zst" > root/lib/efivarfs.ko
chmod 755 root/bin/busybox
printf '%s\n' asphalt-prc-debian13-xfce-7.3.4-v1 > root/etc/y700/image-id
cat > root/sbin/init <<'INIT'
#!/bin/busybox sh
set -eu
exec >/dev/ttyAMA0 2>&1
export PATH=/bin
/bin/busybox --install -s /bin
echo "SD_TRIAL_RETURN_CHECKING root=$(cat /etc/y700/image-id)"
test "$$" = 1
test "$(cat /etc/y700/image-id)" = asphalt-prc-debian13-xfce-7.3.4-v1
test -d /sys/firmware/efi
insmod /lib/efivarfs.ko
mount -t efivarfs -o ro efivarfs /sys/firmware/efi/efivars
selected=$(cat /sys/firmware/efi/efivars/LoaderEntrySelected-* | dd bs=1 skip=4 2>/dev/null | tr -d '\000')
test "$selected" = debian.conf
case " $(cat /proc/cmdline) " in *' root=PARTLABEL=linux '*) ;; *) exit 1 ;; esac
case " $(cat /proc/cmdline) " in *' y700.media=sd '*) exit 1 ;; esac
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
truncate -s 32M root.ext4
mkfs.ext4 -q -d root -U ef306764-2315-4235-8796-69e2c9b61946 root.ext4
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
mcopy -s -i internal.fat "$entry/EFI/y700-test" ::/EFI/
# Two real Linux menu entries; only the first boot receives a manual selection.
sed '/^options /s/$/ console=ttyAMA0/' "$entry/loader/entries/y700-test.conf" > y700-test.conf
mcopy -i internal.fat y700-test.conf ::/loader/entries/
for d in debian y700-test; do mcopy -o -i internal.fat "$board/efi/vm/board.dtb" "::/EFI/$d/board.dtb"; done
for f in loader/loader.conf loader/entries/debian.conf EFI/BOOT/BOOTAA64.EFI EFI/debian/kernel.efi EFI/debian/initrd; do
    mtype -i internal.fat "::$f" | cmp "$board/efi/esp/$f" -
done
mtype -i internal.fat ::/EFI/y700-test/initrd | cmp "$entry/EFI/y700-test/initrd" -
truncate -s 340M internal.img
printf 'label: gpt\nstart=256,size=77824,type=uefi,name=linux-boot\nstart=78080,size=8192,type=linux,name=linux\n' | sfdisk --sector-size 4096 internal.img >/dev/null
dd if=internal.fat of=internal.img bs=1M seek=1 conv=sparse,notrunc status=none
dd if=root.ext4 of=internal.img bs=1M seek=305 conv=sparse,notrunc status=none
sha256sum internal.img wrong-card.img > originals.sha256
for scenario in wrong-identity absent; do
    "${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python "$here/firmware.py" "$qemu" "$board/efi/qemu-uboot/u-boot.bin" "$out" "$scenario"
done
sha256sum --strict -c originals.sha256
echo SD_TRIAL_BOTH_RETURNS_PASS
