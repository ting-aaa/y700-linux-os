#!/usr/bin/env bash
set -euo pipefail
[[ $# == 10 ]] || { echo 'Usage: orient-vm.sh ROOT.ext4 KERNEL QCAM.deb VIRTUAL_DEBS X11_DEBS VKMS.ko BUSYBOX UV SIMULATED_LIBS NEW_LOG' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
disk=$(realpath -e "$1"); kernel=$(realpath -e "$2"); lib=$(realpath -e "$9"); log=$(realpath -m "${10}")
[[ ! -e $log ]]
printf '%s  %s\n' 5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3 "$disk" | sha256sum --strict -c -
case $(dpkg-deb -f "$3" Version) in
    0.7.2-1~bpo13+1.y7007) pin=3bfbc1bf91892b621af6a2ccf86b7ef4a137583f7edcf0e0cb40c2a2f353244f ;;
    0.7.2-1~bpo13+1.y7008) pin=770adeb3b30681100b12c6fd1e877c5e4ec271e3c8420f9beae5b262e8331083 ;;
    *) echo 'Unsupported qcam package' >&2; exit 2 ;;
esac
printf '%s  %s\n' "$pin" "$3" | sha256sum --strict --quiet -c -
(cd "$4" && sha256sum --strict --quiet -c "$here/virtual-runtime.sha256")
(cd "$lib" && sha256sum --strict --quiet -c SHA256SUMS)
w=$(mktemp -d)
trap 'rm -r -- "$w"' EXIT
mkdir -p "$w/init"/{bin,proc,sys,dev,lower,runtime,guest,test/runtime,test/x11,test/virtual-libs}
p=$w/init/test
install -m755 "$7" "$w/init/bin/busybox"
install -m755 "$8" "$p/uv"
install -m755 "$here/../xorg-dsi/init" "$w/init/init"
install -m755 "$here/orient-vm-guest.sh" "$p/guest.sh"
install -m644 "$here/orient-vm-session.sh" "$p/virtual-session.sh"
install -m644 "$here/"{virtual-guest.sh,virtual-shutter.py,orient-vm-check.py} "$p/"
install -m644 "$3" "$p/qcam.deb"; install -m644 "$6" "$p/vkms.ko"
install -m644 "$4/"*.deb "$p/runtime/"
install -m644 "$5/"{libxdo3,xdotool,xvfb}_*.deb "$p/x11/"
install -m755 "$lib/"{libcamera,libcamera-base}.so.0.7.2 "$p/virtual-libs/"
install -m755 "$lib/orientation-probe" "$p/"
sed -e '/"\/base\/.*camera@20":/,/^"\/base\/.*camera@10":/s@  test_pattern: "bars"@  frames:\n    path: "/run/qcam-qa/main-source.jpg"@' \
    -e '/"\/base\/.*camera@10":/,/^"\/fixture/s@  test_pattern: "lines"@  frames:\n    path: "/run/qcam-qa/front-source.jpg"@' \
    "$here/virtual-cameras.yaml" > "$p/virtual-cameras.yaml"
[[ $(grep -c -- '-source.jpg' "$p/virtual-cameras.yaml") == 3 ]]
(cd "$w/init" && find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$w/initrd")
args=(); if [[ -n ${QEMU_DATA_DIR:-} ]]; then args=(-L "$QEMU_DATA_DIR"); fi
{
    sha256sum "$kernel" "$3" "$6" "$lib/"*.so.0.7.2
    timeout -k 5 540 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" \
        -machine virt,gic-version=3 -cpu max -smp 3 -m 1536 -nodefaults -no-user-config -no-reboot \
        -nic none -monitor none -display none -serial stdio -kernel "$kernel" -initrd "$w/initrd" \
        -append 'console=ttyAMA0 quiet loglevel=3 panic=4 y700.qcam_virtual_fixture=1' \
        -drive "if=none,id=base,format=raw,readonly=on,file=$disk" -device virtio-blk-device,drive=base
} </dev/null 2>&1 | tr -d '\r' | tee "$log"
grep -Fxq 'PANEL_CI_EXIT=0' "$log"
case $(dpkg-deb -f "$3" Version) in
    *.y7007) grep -Fxq 'QCAM_ORIENTATION_LEGACY lenses=1 rotations=1 preview_checks=1 jpeg_checks=1 uncorrected=1' "$log" ;;
    *.y7008) grep -Fxq 'QCAM_ORIENTATION_PASS lenses=3 rotations=4 preview_checks=12 jpeg_checks=12 single_process=1' "$log" ;;
    *) exit 2 ;;
esac
