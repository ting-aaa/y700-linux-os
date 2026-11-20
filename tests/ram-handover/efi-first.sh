#!/usr/bin/env bash
# Give the first kernel actual EDK II configuration tables without an ESP.
set -euo pipefail
umask 077
if [[ $# != 4 ]]; then
    echo 'Usage: efi-first.sh AAVMF_CODE.no-secboot.fd RAM_BUNDLE VIRT_DTB NEW_LOG_DIR' >&2
    exit 2
fi
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
firmware=$(realpath -e "$1")
trial=$(realpath -e "$2")
dtb=$(realpath -e "$3")
out=$(realpath -m "$4")
: "${RAM_TRIAL_BASELINE_KERNEL:?Set RAM_TRIAL_BASELINE_KERNEL to the sealed baseline kernel}"
qemu=$(command -v "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}")
printf '%s  %s\n' de01af793c9ff318ac206d8c12e404a2e89baa39bd10e12ed0437a2f69fe012a "$firmware" | sha256sum --strict -c -

work=$(mktemp -d /var/tmp/y700-efi-first.XXXXXXXX)
trap 'rm -f -- "$work/qemu"; rmdir -- "$work"' EXIT
cat > "$work/qemu" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
args=()
while (( $# )); do
    case "$1" in
        -machine)
            [[ $2 == virt,gic-version=3 ]]
            args+=(-machine virt,gic-version=3,acpi=off)
            shift 2
            ;;
        -cpu)
            [[ $2 == max ]]
            args+=(-cpu cortex-a72)
            shift 2
            ;;
        -bios|-drive|-blockdev|-pflash|*irqchip.gicv3_nolpi*|*its=off*)
            echo 'Unexpected media or IRQ configuration in the EFI-first trial' >&2
            exit 2
            ;;
        *) args+=("$1"); shift ;;
    esac
done
exec "$Y700_EFI_QEMU" -bios "$Y700_EFI_FIRMWARE" "${args[@]}"
WRAPPER
chmod 700 "$work/qemu"
result=0
Y700_EFI_FIRMWARE="$firmware" Y700_EFI_QEMU="$qemu" QEMU_SYSTEM_AARCH64="$work/qemu" RAM_TRIAL_KEXEC=1 \
    bash "$here/../ram-trial/run.sh" "$trial" "$dtb" "$out" || result=$?

if [[ -r $out/serial.log ]]; then
    awk '
        /Linux version 7\.3\.4-asphalt-prc/ { boot++ }
        /efi: EFI v[0-9].*Ubuntu distribution of EDK II/ { firmware[boot] = 1 }
        /efi: .*MEMRESERVE=/ { memreserve[boot] = 1 }
        /ITS \[mem/ { its[boot] = 1 }
        /GICv3: using LPI property table @0x/ { lpi[boot] = $NF }
        END {
            for (i = 1; i <= boot; i++)
                printf "RAM_TRIAL_EFI_IRQ boot=%d edk2=%d memreserve=%d its=%d property_table=%s\n",
                    i, firmware[i], memreserve[i], its[i], (lpi[i] ? lpi[i] : "absent")
            if (boot != 2 || !firmware[1] || !memreserve[1] || !its[1] || !its[2] || !lpi[1] || !lpi[2])
                exit 1
        }
    ' "$out/serial.log" | tee "$out/efi-irq.log" || { (( result != 0 )) || result=1; }
else
    (( result != 0 )) || result=1
fi
if (( result != 0 )); then exit "$result"; fi
echo RAM_TRIAL_EFI_KEXEC_PASS
