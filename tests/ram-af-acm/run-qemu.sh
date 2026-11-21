#!/usr/bin/env bash
# Exercise the real ARM64 measurement ELF, a virtio serial test transport, and no camera or disks.
set -euo pipefail
umask 077
[[ $# == 3 ]]
here=$(cd "$(dirname "$0")" && pwd)
base=$(realpath -e "$1"); addon=$(realpath -e "$2"); out=$(realpath -m "$3")
mkdir -m700 "$out"
echo "2cdddecb410b4aa3d9b63b229fc8df5fc8de61b00ed3a209a34c633d82adb453  $base/SHA256SUMS" | sha256sum -c -
(cd "$base" && sha256sum --strict -c SHA256SUMS)
(cd "$addon" && sha256sum --strict -c SHA256SUMS)
work=$(mktemp -d /var/tmp/y700-ram-af-vm.XXXXXXXX)
pid=
cleanup() {
    if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
cat "$base/initrd" "$addon/af-acm.cpio" > "$work/initrd"
args=$(cat "$addon/cmdline.txt")
mode=${AF_QA_RETURN:-none}
case $mode in
    none) ;;
    ack|deadline)
        # The shipping attachment enables the timer only on the PRC tablet. Substitute
        # the VM board predicate only in a private test entry; all units are from the archive.
        cpio --quiet -i --to-stdout y700-af-acm-init <"$addon/af-acm.cpio" >"$work/base-init"
        awk -v mode="$mode" '
            /^unit=\/newroot\/etc\/systemd\/system\/y700-ram-af-acm.service$/ { attached=1 }
            attached && /^if printf .*grep -Fxq lenovo,asphalt; then$/ {
                print "if [ \"$compat\" = linux,dummy-virt ] && grep -qw y700.ram_af_virtual=1 /proc/cmdline; then"
                ++changed; next
            }
            /^for fs in dev proc sys run; do$/ && mode=="deadline" {
                print "d=/newroot/etc/systemd/system/y700-ram-af-return.timer.d"
                print "mkdir -m 0755 \"$d\" || exit 1"
                print "printf '\''[Timer]\\nOnActiveSec=\\nOnActiveSec=80s\\n'\'' >\"$d/vm-time.conf\" || exit 1"
            }
            { print }
            END { exit changed!=1 }
        ' "$work/base-init" >"$work/y700-af-acm-qa-init"
        chmod 755 "$work/y700-af-acm-qa-init"
        sh -n "$work/y700-af-acm-qa-init"
        (cd "$work"; echo y700-af-acm-qa-init | cpio --quiet -o -H newc --owner 0:0) >> "$work/initrd"
        args=${args/rdinit=\/y700-af-acm-init /rdinit=\/y700-af-acm-qa-init }
        ;;
    *) echo 'AF_QA_RETURN must be none, ack, or deadline' >&2; exit 2 ;;
esac
qemu=("${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}")
if [[ -n ${QEMU_DATA:-} ]]; then qemu+=(-L "$QEMU_DATA"); fi
"${qemu[@]}" -machine virt,gic-version=3 -cpu max -smp 3 -m 6144 -nodefaults -no-user-config -display none -nic none \
    -monitor none -serial "file:$out/console.log" -no-reboot -kernel "$base/kernel.efi" -initrd "$work/initrd" \
    -append "$args console=ttyAMA0,115200 systemd.unit=multi-user.target y700.ram_af_virtual=1" \
    -device virtio-serial-device -chardev "socket,id=af,path=$work/port,server=on,wait=off" \
    -device virtserialport,chardev=af,name=org.y700.ram-af >"$out/qemu.log" 2>&1 & pid=$!
for _ in {1..50}; do [[ ! -S $work/port ]] || break; sleep .2; done
timeout 320 "${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python -B "$here/test-protocol.py" \
    "$work/port" | tee "$out/protocol.log"
if [[ $mode == deadline ]]; then
    grep -Fxq 'RAM_AF_IDLE closed=1 no_start=1' "$out/protocol.log"
else
    grep -Fxq 'RAM_AF_PROTOCOL_PASS wrong_start_rejected=1 synthetic=1 one_execution=1 replay=1' "$out/protocol.log"
fi
if [[ $mode != none ]]; then
    timeout 180 tail --pid="$pid" -f /dev/null
    wait "$pid"; pid=
    grep -Fq 'Y700_RAM_AF_RETURN orderly=1' "$out/console.log"
    grep -Fq 'reboot: Restarting system' "$out/console.log"
    printf 'RAM_AF_RETURN cause=%s guest_normal_reboot=1 host_kill=0\n' "$mode" | tee -a "$out/protocol.log"
fi
