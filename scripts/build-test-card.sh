#!/usr/bin/env bash
# Assemble regular files only. The caller provides a new DIRECTORY, never a drive.
set -euo pipefail
images=$(realpath -e "${1:?completed candidate directory}")
out=$(realpath -m "${2:?new card output directory}")
mkdir -m700 -- "$out"
cd "$images"
sha256sum -c SHA256SUMS
cd "$out"
mkdir esp
mcopy -s -i "$images/linux-boot.fat" ::/EFI ::/loader esp/
# The temporary menu contains a single Debian entry. Other entries act on the tablet.
rm esp/loader/entries/{android,bootloader,recovery-b}.conf
sed -i 's|root=PARTLABEL=linux |root=PARTLABEL=y700-test-root y700.media=sd |' esp/loader/entries/debian.conf
grep -Fq 'root=PARTLABEL=y700-test-root y700.media=sd ' esp/loader/entries/debian.conf
fatid=$(blkid -p -s UUID -o value "$images/linux-boot.fat" | tr -d '-')
truncate -s 1G card-esp.fat
mkfs.fat -F 32 -S 512 -s 8 -i "$fatid" -n Y700TEST card-esp.fat
mcopy -s -i card-esp.fat esp/EFI esp/loader ::/
fsck.fat -vn card-esp.fat
mkdir check
mcopy -s -i card-esp.fat ::/EFI ::/loader check/
diff -qr esp check
truncate -s 7171M y700-test-card.img
printf 'label: gpt\nunit: sectors\n\nstart=2048, size=2097152, type=uefi, name=y700-test-esp\nstart=2099200, size=12582912, type=linux, name=y700-test-root\n' | sfdisk --sector-size 512 y700-test-card.img
dd if=card-esp.fat of=y700-test-card.img bs=1M seek=1 conv=sparse,notrunc status=none
dd if="$images/root.ext4" of=y700-test-card.img bs=1M seek=1025 conv=sparse,notrunc status=none
cmp -n 1073741824 card-esp.fat y700-test-card.img 0 1048576
cmp -n 6442450944 "$images/root.ext4" y700-test-card.img 0 1074790400
sha256sum y700-test-card.img > SHA256SUMS
