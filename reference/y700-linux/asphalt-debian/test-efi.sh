#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
w=$(realpath "${1:?EFI work directory}")
cd "$w"
mkdir -p vm
test ! -e vm/disk.gpt
cp --sparse=always linux-boot.fat vm/esp.fat
# The QEMU machine has a PL011 UART and a simple framebuffer instead of an MSM panel.
sed -E 's|^options .*|options rdinit=/init root=PARTLABEL=linux rw console=ttyAMA0 loglevel=4 systemd.debug_shell=ttyAMA0 systemd.mask=serial-getty@ttyAMA0.service systemd.mask=y700-firstboot.service|' \
  esp/loader/entries/debian.conf > vm/debian.conf
# -nodefaults omits the optional PL061 controller and its power key.
cp ../ufs/vm-fb.dtb vm/board.dtb
fdtput -r vm/board.dtb /gpio-keys /pl061@9030000
mcopy -o -i vm/esp.fat vm/board.dtb ::/EFI/debian/board.dtb
mcopy -o -i vm/esp.fat vm/debian.conf ::/loader/entries/debian.conf
truncate -s 13316M vm/disk.gpt
printf 'label: gpt\nunit: sectors\n\nstart=256, size=262144, type=uefi, name=linux-boot\nstart=262400, size=3145728, type=linux, name=linux\n' | sfdisk --sector-size 4096 vm/disk.gpt
dd if=vm/esp.fat of=vm/disk.gpt bs=1M seek=1 conv=sparse,notrunc status=none
dd if=debian-efi.ext4 of=vm/disk.gpt bs=1M seek=1025 conv=sparse,notrunc status=none
"$w/build-venv/bin/python" "$here/test-efi.py" "$w" "${2:?QEMU bundle}"
