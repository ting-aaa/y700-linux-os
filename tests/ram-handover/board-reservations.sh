#!/bin/bash
# Read from one boot on the known board. Only the local summary goes to stdout.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: board-reservations.sh PINNED_USB_SSH' >&2; exit 2; }
ssh=$(realpath -e "$1")
here=$(cd "$(dirname "$0")" && pwd)
bash "$ssh" 'LC_ALL=C bash -s' <<'BOARD' |
set -euo pipefail
dt=/sys/firmware/devicetree/base
gic=$dt/soc@0/interrupt-controller@17100000
boot=$(cat /proc/sys/kernel/random/boot_id)
[[ $(uname -r) == 7.3.4-asphalt-prc && $(cat /sys/devices/system/cpu/online) == 0-7 ]]
[[ $(sha256sum /sys/kernel/notes | cut -d' ' -f1) == 2e6b047aba528bfdea5549b9aae9af362a9af055bb630a650bcdd7c654ec9066 ]]
for compatible in lenovo,asphalt qcom,sm8475; do tr '\0' '\n' <"$dt/compatible" | grep -Fx "$compatible" >/dev/null; done
tr '\0' '\n' <"$gic/compatible" | grep -Fx 'arm,gic-v3' >/dev/null
tr '\0' '\n' <"$gic/msi-controller@17140000/compatible" | grep -Fx 'arm,gic-v3-its' >/dev/null
[[ $(cat /sys/kernel/kexec_loaded) == 0 && $(cat /sys/firmware/efi/fw_platform_size) == 64 ]]
for p in linux,uefi-system-table linux,uefi-mmap-start linux,uefi-mmap-size; do test -f "$dt/chosen/$p"; done
for key in SecureBoot BootCurrent BootOrder; do
    value=absent
    if [[ -f /sys/firmware/efi/efivars/$key-8be4df61-93ca-11d2-aa0d-00e098032b8c ]]; then value=present; fi
    echo "EFI_NAME $key $value"
done
# Only the journal records for this boot and these four specific kernel messages.
journalctl -q -k -b 0 -o cat --no-pager -g '^efi: EFI v2.11 by Das U-Boot$|^efi: .*MEMRESERVE=|^ITS \[mem |^GICv3:.*using (allocated |reserved )?LPI (property|pending) table' |
    awk '/^efi: EFI v2.11 by Das U-Boot$/ {print "BOOT firmware"}
         /^efi: .*MEMRESERVE=0x[0-9a-f]+/ {print "BOOT memreserve"}
         /^ITS \[mem / {print "BOOT its"}
         /^GICv3: using LPI property table @0x/ {print "TABLE property", substr($NF,2)}
         /^GICv3: CPU[0-9]+: using (allocated|reserved) LPI pending table @0x/ {
             sub(/:$/, "", $2); print "TABLE", $2, substr($NF,2)}'
# Save tree depth on the board. A plain System RAM parent is not a reservation.
awk '/^[ ]*[0-9a-f]+-[0-9a-f]+ : / {
    depth=match($0,/[^ ]/)-1; ram=($0~/ : System RAM$/)
    under_ram[depth]=ram || (depth>=2 && under_ram[depth-2])
    if (ram) print "IOMEM ram",$1
    if ($0~/ : reserved$/) print "IOMEM", (under_ram[depth] ? "reserved_child" : "reserved_other"),$1
}' /proc/iomem
for kind in memory reserved; do
    awk -v kind="$kind" '{print "MEMBLOCK",kind,$2}' "/sys/kernel/debug/memblock/$kind"
done
# Fixed, two-cell address/two-cell size tuples. Leave bootloader seeds and other DT data alone.
fixed=$dt/reserved-memory
for prop in '#address-cells' '#size-cells'; do
    [[ $(od -An -tx1 -v "$fixed/$prop" | tr -d ' \n') == 00000002 ]]
done
for node in "$fixed"/*/reg; do
    if [[ -e ${node%/reg}/status && $(tr -d '\0' <"${node%/reg}/status") != okay &&
          $(tr -d '\0' <"${node%/reg}/status") != ok ]]; then continue; fi
    printf 'DT '; od -An -tx1 -v "$node" | tr -d ' \n'; printf '\n'
done
[[ $(cat /proc/sys/kernel/random/boot_id) == "$boot" && $(cat /sys/kernel/kexec_loaded) == 0 ]]
[[ $(cat /sys/devices/system/cpu/online) == 0-7 ]]
echo COMPLETE
BOARD
    "${UV_BIN:-uv}" run --no-project --offline --python /usr/bin/python3 python -B "$here/board-reservations.py"
