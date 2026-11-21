#!/usr/bin/env bash
set -euo pipefail
[[ $# == 7 ]] || { echo 'Usage: run.sh KERNEL ROOT BUSYBOX ARM64_UV BUILT_WITH_TEST_VHCI PINNED_PEER_GIT NEW_LOG' >&2; exit 2; }
kernel=$(realpath "$1"); disk=$(realpath "$2"); busybox=$(realpath "$3"); uv=$(realpath "$4")
build=$(realpath "$5"); peer=$(realpath "$6"); log=$(realpath -m "$7")
[[ ! -e $log && ! -L $log && -d $(dirname "$log") ]]
here=$(cd "$(dirname "$0")" && pwd)
echo "6155d87d5d5b9d5557e86362f09fb17328aef200861e94eb292a669c35659c7c  $disk" | sha256sum --strict -c -
case $(sha256sum "$kernel" | cut -d' ' -f1) in
    0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60|b103d0fcd65a08cadb592fbdc69c8c483a7727ef212c15e464208f5c30a1a625) ;;
    *) echo 'Expected a dev12.13 board kernel' >&2; exit 2;;
esac
(cd "$build" && sha256sum --strict -c SHA256SUMS)
work=$(mktemp -d /tmp/y700-uac-qemu.XXXXXXXX)
trap 'rm -r --one-file-system -- "$work"' EXIT
mkdir -p "$work/init"/{bin,dev,guest,lower,proc,run,sys,test}
cd "$work/init"
git -C "$peer" archive 34d6fac0eb369e4a6238b4719036ab39743a9a93 usbip | tar -xC test
install -m755 "$busybox" bin/busybox
install -m755 "$here/../microphone/virtual/init" init
install -m755 "$uv" test/uv
install -m644 "$here/../microphone/virtual/session.py" test/session.py
cp "$here"/{device.py,check-tone.py,guest.sh} "$build"/*.deb "$build/test-only"/*.ko test/
find . -print0 | cpio --null --quiet -o -H newc | gzip -1 > "$work/initrd.gz"
args=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then args+=(-L "$QEMU_FIRMWARE_DIR"); fi
timeout -k 5 170 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" -machine virt,gic-version=3 \
    -cpu max -smp 3 -m 768 -nodefaults -no-user-config -display none -nic none -serial stdio -monitor none -no-reboot \
    -kernel "$kernel" -initrd "$work/initrd.gz" -append 'console=ttyAMA0 panic=4 loglevel=3 y700.test_uac=1' \
    -drive "if=none,id=root,format=raw,readonly=on,file=$disk" -device virtio-blk-device,drive=root \
    </dev/null 2>&1 | tr -d '\r' | tee "$log"
grep -q '^UAC_PASS ' "$log"
grep -Fxq MIC_FIXTURE_EXIT=0 "$log"
