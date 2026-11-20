#!/usr/bin/env bash
# Boot the released initrd unchanged and deliver QA over a virtual serial port.
set -euo pipefail
umask 077
if [[ $# != 3 ]]; then
    echo 'Usage: run.sh SEALED_RAM_TRIAL_DIR VIRT_DTB NEW_LOG_DIR' >&2
    exit 2
fi
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
trial=$(realpath -e "$1")
dtb=$(realpath -e "$2")
logs=$(realpath -m "$3")
mkdir -m700 -- "$logs"
work=$(mktemp -d /var/tmp/y700-ram-boot.XXXXXXXX)
[[ $(realpath -e "$work") =~ ^/var/tmp/y700-ram-boot\.[A-Za-z0-9]{8}$ ]]
trap 'rm -r --one-file-system -- "$work"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
echo "RAM_TRIAL_EVIDENCE=$logs"
echo "RAM_TRIAL_WORK=$work"
check_inputs() {
    (cd "$trial" && sha256sum --strict -c SHA256SUMS)
    printf '%s  %s\n' \
        4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1 "$trial/kernel.efi" \
        a89bc8f2ee12f118656c6963fb9d45b862e6d5a1aeedf2630ddbe08f03079d31 "$dtb" | sha256sum --strict -c -
}
check_inputs | tee "$logs/before.log"
[[ $(wc -l < "$trial/cmdline.txt") == 1 ]]
IFS= read -r args < "$trial/cmdline.txt"
for arg in rdinit=/y700-ram-trial-init y700.media=ram fstab=no systemd.gpt_auto=0 noresume drm_kms_helper.fbdev_emulation=0; do
    [[ " $args " == *" $arg "* ]]
done
printf '%s\n' "$args" > "$logs/product-cmdline.txt"
bytes=$(stat -Lc %s "$trial/initrd")
[[ $bytes -gt 0 && $bytes -lt 4294967296 ]]
printf 'RAM_TRIAL_EXACT_INITRD bytes=%s\n' "$bytes" | tee "$logs/initrd-bytes.log"

# The virtual board's fixed simpledrm aperture matches the existing pixel oracle.
# Give the kernel the full 9 GiB while retaining that 1024x768 framebuffer.
cp -- "$dtb" "$work/ram.dtb"
fdtput -t x "$work/ram.dtb" /memory@40000000 reg 0 40000000 2 40000000
[[ $(fdtget -t x "$work/ram.dtb" /chosen/framebuffer@be000000 reg) == '0 be000000 0 300000' ]]
[[ $(fdtget -t i "$work/ram.dtb" /chosen/framebuffer@be000000 width) == 1024 ]]
[[ $(fdtget -t i "$work/ram.dtb" /chosen/framebuffer@be000000 height) == 768 ]]

seed=$work/qa
mkdir "$seed"
case ${RAM_TRIAL_VERSION:-dev12.5} in
    dev12.5) echo baseline > "$seed/lock-mode" ;;
    dev12.6) echo installed > "$seed/lock-mode" ;;
    *) echo 'Unknown RAM_TRIAL_VERSION (expected dev12.5 or dev12.6)' >&2; exit 2 ;;
esac
combined=$here/../combined-efi
awk -f "$here/adapt-observer.awk" "$combined/observe.sh" > "$seed/combined-observe.sh"
bash -n "$seed/combined-observe.sh"
cp "$here/check-root.sh" "$here/../file-trial-positive/check-login-stage.sh" "$seed/"
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -O2 -Wall -Wextra -Werror -static "$combined/touch.c" -o "$seed/combined-touch"
tar -C "$seed" -cf "$work/qa.tar" combined-observe.sh combined-touch check-root.sh check-login-stage.sh lock-mode
seed_size=$(stat -Lc %s "$work/qa.tar")
[[ $seed_size -le 1048576 ]]
cat > "$work/probe.service" <<UNIT
[Unit]
Description=Prove the diskless Y700 RAM trial
After=systemd-udev-trigger.service
Before=y700-firstboot.service
ConditionKernelCommandLine=y700.ram_probe=1
FailureAction=poweroff

[Service]
Type=oneshot
TimeoutStartSec=170
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/bin/bash -e -o pipefail -c 'grep -zFxq linux,dummy-virt /proc/device-tree/compatible; install -d -m700 /run/y700-ram-qa; until test -c /dev/virtio-ports/org.y700.ram-qa; do sleep 1; done; exec 9<>/dev/virtio-ports/org.y700.ram-qa; printf "RAM_QA_READY\\n" >&9; head -c $seed_size <&9 | tar -xf - -C /run/y700-ram-qa; exec 9>&-; exec /bin/bash /run/y700-ram-qa/combined-observe.sh setup'
UNIT
unit=$(base64 -w0 "$work/probe.service")
args+=" console=ttyAMA0,115200 loglevel=7 y700.ram_probe=1 y700.combined_efi=1 systemd.wants=y700-ram-qa.service systemd.set_credential_binary=systemd.extra-unit.y700-ram-qa.service:$unit"
if [[ ${RAM_TRIAL_RETAIN_PANIC:-0} == 1 ]]; then
    [[ ${RAM_TRIAL_KEXEC:-0} == 1 ]]
    args+=' retain_initrd'
fi
[[ ${#args} -lt 2048 ]]

qemu_data=()
if [[ -n ${QEMU_DATA:-} ]]; then qemu_data=(-L "$QEMU_DATA"); fi
kernel=$trial/kernel.efi
initrd=$trial/initrd
if [[ ${RAM_TRIAL_KEXEC:-0} == 1 ]]; then
    kernel=$(realpath -e "${RAM_TRIAL_BASELINE_KERNEL:?Set RAM_TRIAL_BASELINE_KERNEL to the sealed baseline kernel}")
    printf '%s  %s\n' 9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db "$kernel" | sha256sum --strict -c -
    bash "$here/../ram-handover/prepare.sh" "$trial" "$work/first.cpio"
    initrd=$work/first.cpio
    if [[ -n ${Y700_BOOTAA64:-} ]]; then
        bash "$here/../ram-handover/uboot-esp.sh" "$kernel" "$initrd" "$work/ram.dtb" "$args" "$work/firmware-boot.img"
    fi
fi
timeout -k 25 2100 "${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python -B "$here/qemu-ram.py" \
    "$work" "$logs" "$bytes" "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${qemu_data[@]}" \
    -machine virt,gic-version=3 -cpu max -smp 3 -m 9216 -nodefaults -no-user-config -display none -nic none -no-reboot -monitor none \
    -kernel "$kernel" -dtb "$work/ram.dtb" -initrd "$initrd" -append "$args" | tee "$logs/host-verdict.log"
check_inputs | tee "$logs/after.log"
cmp "$logs/before.log" "$logs/after.log"
if [[ ${RAM_TRIAL_KEXEC:-0} == 1 ]]; then
    grep -Fq 'RAM_QA_KEXEC_FILE_LOADED' "$logs/serial.log"
    grep -Fq 'RAM_QA_KEXEC_HANDOVER' "$logs/serial.log"
    [[ $(grep -Ec '^\[[[:space:]]*[0-9.]+\] Linux version 7\.3\.4-asphalt-prc' "$logs/serial.log") == 2 ]]
    echo RAM_TRIAL_KEXEC_DISKLESS_PASS
else
    echo RAM_TRIAL_DISKLESS_PASS
fi
