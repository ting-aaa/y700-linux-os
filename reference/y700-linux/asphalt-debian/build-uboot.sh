#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
w=$(realpath "${1:?EFI work directory}")
pkgs="$here/../asphalt-upstream/pkgs"
cd "$w"
test "$(git -C "$pkgs" rev-parse HEAD)" = 8dcb481fc2ce91794fd294630e06f15a52ec7513
test "$(nix --extra-experimental-features nix-command hash path upstream)" = 'sha256-BXIpyAY+uKSohrdG4BxAo0zq4CYmh2z9rFw1jA7Yu8s='
test ! -e board-src
cp -a upstream board-src
nix-instantiate --eval --strict --json "$here/uboot-board.nix" > spec.json
cd board-src
while read -r patch; do patch --batch --forward -p1 < "$patch"; done < <(jq -r '.patches[]' ../spec.json)
action="$pkgs/mobile-boot-action"
cp "$action/firmware.c" lib/efi_loader/efi_mobile_boot_action.c
cp "$action/protocol.h" include/mobile_boot_action.h
cp "$action/pon-transaction.h" lib/efi_loader/mobile_pon_transaction.h
for f in qcom-ab qcom-ab-firmware qcom-ab-confirm; do
    dest=${f//-/_}
    cp "$action/$f.h" "lib/efi_loader/mobile_$dest.h"
done
cat "$pkgs/u-boot/sm8475/asphalt/asphalt.env" "$pkgs/u-boot/charger.env" > board/qualcomm/asphalt.env
export ARCH=arm CROSS_COMPILE=aarch64-linux-gnu-
make "$(jq -r .defconfig ../spec.json)"
scripts/kconfig/merge_config.sh -m .config "$(jq -r .baseConfig ../spec.json)"
jq -r .config ../spec.json >> .config
make olddefconfig
make -j12
for k in EFI_LOADER EFI_MOBILE_QCOM_AB_CONFIRM SCSI CMD_FAT CMD_BOOTEFI; do grep -qx "CONFIG_$k=y" .config; done
