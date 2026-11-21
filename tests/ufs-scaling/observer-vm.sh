#!/bin/bash
# Test the shipped private PID 1. All writable blocks below are synthetic regular files.
set -euo pipefail
umask 077
[[ $# == 5 ]] || { echo 'Usage: observer-vm.sh 0|1 KERNEL OBSERVER_DIRECTORY ok|guid|missing|ro|payload|nohost NEW_OUTPUT' >&2; exit 2; }
variant=$1; kernel=$(realpath -e "$2"); obs=$(realpath -e "$3"); mode=$4; out=$(realpath -m "$5")
case $variant in
  0) identity=0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60 ;;
  1) identity=243db9c43ef8f7a4a3e224106d87f2c87ba16c1ce93c475c4eafa02f8817fce6 ;;
  *) exit 2 ;;
esac
printf '%s  %s\n' "$identity" "$kernel" | sha256sum --status -c -
(cd "$obs"; sha256sum --strict -c SHA256SUMS)
here=$(cd "$(dirname "$0")" && pwd)
mkdir "$out"; w=$(mktemp -d); pid=
cleanup() { if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fi; rm -r --one-file-system -- "$w"; }
trap cleanup EXIT
guid=e59fb29e-76c1-4920-986f-56300445d5c8
label=boot_b; extra=''; expect=0
case $mode in
  ok|nohost) ;;
  guid) guid=00000000-1234-4567-8000-000000000000; expect=3 ;;
  ro) extra=y700.ufs_qa_ro=check; expect=1 ;;
  payload) expect=5 ;;
  missing) label=other; expect=2 ;;
  *) exit 2 ;;
esac
truncate -s 100M "$w/disk"
sgdisk --clear --new=41:2048:+96M --change-name=41:"$label" --partition-guid=41:"$guid" "$w/disk" >/dev/null
if [[ $mode == payload ]]; then printf X | dd of="$w/disk" bs=1 seek=1048576 conv=notrunc status=none; fi
before=$(sha256sum < "$w/disk")
args=(); [[ -z ${QEMU_DATA_DIR:-} ]] || args=(-L "$QEMU_DATA_DIR")
"${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" -machine virt,gic-version=3 -cpu max -m 320 -smp 2 \
    -nodefaults -no-user-config -nic none -no-reboot -display none -monitor none -serial "file:$out/console.log" \
    -kernel "$kernel" -initrd "$obs/initrd" -append "rdinit=/init y700.ufs_observe=1 noresume panic=5 console=ttyAMA0 quiet $extra" \
    -drive "if=none,id=test,format=raw,file=$w/disk" -device virtio-blk-device,drive=test \
    -device virtio-serial-device -chardev "socket,id=port,path=$w/port,server=on,wait=off" \
    -device virtserialport,chardev=port,name=org.y700.ufs >"$out/qemu.log" 2>&1 & pid=$!
if [[ $mode != nohost ]]; then
    for _ in {1..40}; do [[ ! -S $w/port ]] || break; sleep .1; done
    rc=0
    "${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python -B "$here/collect.py" \
        --vm-socket "$w/port" --variant "$variant" --output "$out/receipt.txt" >"$out/collector.log" || rc=$?
    [[ ($expect == 0 && $rc == 0) || ($expect != 0 && $rc == 1) ]]
    grep -Eq "^UFS1 META $variant 1 [01] [01] [012] $expect$" "$out/receipt.txt"
fi
timeout 170 tail --pid="$pid" -f /dev/null
wait "$pid"; pid=
[[ $(sha256sum < "$w/disk") == "$before" ]]
supervisor=0; [[ $mode != nohost ]] || supervisor=4
grep -Fq "UFS1 SUPERVISOR $supervisor" "$out/console.log"
grep -Fq 'reboot: Restarting system' "$out/console.log"
[[ $mode != nohost ]] || expect=not_requested
echo "UFS_VM variant=$variant mode=$mode error=$expect full_disk_same=1 returned=1 physical_ufs=0"
