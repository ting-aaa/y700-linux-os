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
grep -Fxq 'RAM_AF_PROTOCOL_PASS wrong_start_rejected=1 synthetic=1 one_execution=1 replay=1' "$out/protocol.log"
