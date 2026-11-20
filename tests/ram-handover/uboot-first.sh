#!/usr/bin/env bash
# Exercise the U-Boot EFI loader on the hardware it targets: QEMU virt.
set -euo pipefail
umask 077
if [[ $# != 5 ]]; then
    echo 'Usage: uboot-first.sh VIRT_UBOOT BOOTAA64.EFI RAM_BUNDLE VIRT_DTB NEW_LOG_DIR' >&2
    exit 2
fi
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
export Y700_UBOOT=$(realpath -e -- "$1") Y700_BOOTAA64=$(realpath -e -- "$2")
export Y700_REAL_QEMU=$(command -v "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}")
export Y700_UBOOT_RUNNER=$here/uboot-qemu.py
export Y700_HANDOVER_BUNDLE=$(realpath -e -- "$3")
export Y700_UV=$(command -v "${UV_BIN:-uv}")
printf '%s  %s\n' ccfe8c4136a02adccdc68b2e7567fa4a06cc8874213064f62f20463803706c4f "$Y700_UBOOT" \
    76a5bba20322d4929f35c608199f21f80317ae006805315ca215382cdef4c75b "$Y700_BOOTAA64" | sha256sum --strict -c -
work=$(mktemp -d /var/tmp/y700-uboot-first.XXXXXXXX)
trap 'rm -r --one-file-system -- "$work"' EXIT
cat > "$work/qemu" <<'SCRIPT'
#!/bin/sh
exec "$Y700_UV" run --offline --no-project --python /usr/bin/python3 python -B "$Y700_UBOOT_RUNNER" "$@"
SCRIPT
chmod 700 "$work/qemu"
QEMU_SYSTEM_AARCH64=$work/qemu RAM_TRIAL_KEXEC=1 bash "$here/../ram-trial/run.sh" "$3" "$4" "$5"
serial=$5/serial.log
grep -Fq 'with efi_mgr' "$serial"
grep -Fq 'Booting: Label: usb 0 Device path:' "$serial"
[[ $(grep -Fc 'efi: EFI v2.11 by Das U-Boot' "$serial") == 2 ]]
[[ $(grep -Ec 'efi: .*MEMRESERVE=' "$serial") == 2 ]]
[[ $(grep -Fc 'ITS [mem' "$serial") == 2 ]]
grep -Fq 'RAM_QA_EFI_RESERVATIONS_OK mapped_tables=4' "$serial"
grep -Fq 'RAM_QA_KEXEC_LAYOUT_OK segments=3 tables=4' "$serial"
grep -Fxq 'RAM_QA_FIRMWARE_MEDIA_REMOVED' "$5/qemu.log"
grep -Fxq 'RAM_QA_PAYLOAD_DELIVERED' "$5/qemu.log"
echo RAM_TRIAL_UBOOT_EFI_KEXEC_PASS
