#!/usr/bin/env bash
# Exercise the split initrd, the sealed root and the AF reporting service in one cold boot.
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: check-receiver.sh BUNDLE MANIFEST_SHA256 NEW_LOG_DIRECTORY' >&2; exit 2; }
repo=$(cd -- "$(dirname -- "$0")/../.." && pwd)
bundle=$(realpath -e -- "$1")
pin=$2
[[ $pin =~ ^[a-f0-9]{64}$ && ! -e $3 ]]
work=$(realpath -m -- "$3")
mkdir -m700 -- "$work"
(cd "$bundle"; printf '%s  SHA256SUMS\n' "$pin" | sha256sum --strict -c -; sha256sum --strict -c SHA256SUMS) >"$work/inputs.log"
grep -Fq 'y700.ram_af_acm=1' "$bundle/cmdline.txt"
qemu=${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}
uv=${UV_BIN:-uv}
uv_run=("$uv" run --offline --no-project --python "${UV_PYTHON:-python3}" python -B)
args=()
if [[ -n ${QEMU_DATA:-} ]]; then args+=(-L "$QEMU_DATA"); fi
"$qemu" "${args[@]}" -machine virt,gic-version=3 -cpu max -smp 3 -m 8192 \
    -nodefaults -no-user-config -display none -nic none -no-reboot -monitor none \
    -serial "file:$work/console.log" -device virtio-serial-device \
    -chardev "socket,id=carrier,path=$work/carrier.sock,server=on,wait=off" \
    -device virtserialport,chardev=carrier,name=y700.ram.receive \
    -chardev "socket,id=af,path=$work/af.sock,server=on,wait=off" \
    -device virtserialport,chardev=af,name=org.y700.ram-af \
    -kernel "$bundle/kernel.efi" -initrd "$bundle/initrd" \
    -append "$(cat "$bundle/cmdline.txt") y700.ram_receiver_qa=1 console=ttyAMA0,115200 systemd.unit=multi-user.target y700.ram_af_virtual=1" \
    >"$work/qemu.log" 2>&1 &
vm=$!
trap 'kill "$vm" 2>/dev/null || :; wait "$vm" 2>/dev/null || :' EXIT
for ((i=0; i<120; i++)); do
    grep -q Y700_RAM_RECEIVER_READY "$work/console.log" 2>/dev/null && break
    kill -0 "$vm"; sleep .5
done
grep -q Y700_RAM_RECEIVER_READY "$work/console.log"
timeout 600 "${uv_run[@]}" "$repo/tests/ram-trial/send-carrier.py" "$bundle/carrier.squashfs" \
    --qemu-socket "$work/carrier.sock" >"$work/sender.log"
AF_QA_DISCONNECT=1 timeout 320 "${uv_run[@]}" "$repo/tests/ram-af-acm/test-protocol.py" "$work/af.sock" >"$work/protocol.log"
grep -F 'Y700_RAM_RECEIVER_VERIFIED' "$work/console.log"
grep -F 'RAM overlay ready' "$work/console.log"
grep -F 'receiver_verified=1' "$work/sender.log"
grep -E 'RAM_AF_RECONNECTED|RAM_AF_PROTOCOL_PASS' "$work/protocol.log"
grep -Fq 'RAM_AF_PROTOCOL_PASS' "$work/protocol.log"
