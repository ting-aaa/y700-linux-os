#!/usr/bin/env bash
# The root image is immutable. All software substitutions live in guest RAM.
set -euo pipefail
[[ $# == 11 ]] || { echo 'Usage: run-vm.sh ROOT KERNEL QCAM_DEB|installed VIRTUAL_DEBS X11_DEBS VKMS BUSYBOX UV SIM_LIBS stock|installed|PIPEWIRE_DEB NEW_LOG' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
q=$here/../qcam-photo
disk=$(realpath -e "$1"); kernel=$(realpath -e "$2"); lib=$(realpath -e "$9"); log=$(realpath -m "${11}")
[[ ! -e $log ]]
if [[ ${10} == installed ]]; then
    [[ $3 == installed ]]
    root_sha=32896d21a07a1c9529db3d007df788bb8ddcf4e5b6b0782527737ac7af1a3259
else
    root_sha=5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3
    echo "770adeb3b30681100b12c6fd1e877c5e4ec271e3c8420f9beae5b262e8331083  $3" | sha256sum --strict --quiet -c -
fi
printf '%s  %s\n' "$root_sha" "$disk" 7f9031148c554c574f2ea20a81a9b2804e97c4c6d67f6442ceef175e276b71b5 "$lib/libcamera.so.0.7.2" | sha256sum --strict --quiet -c -
(cd "$4"; sha256sum --strict --quiet -c "$q/virtual-runtime.sha256")
w=$(mktemp -d); trap 'rm -r -- "$w"' EXIT
mkdir -p "$w/i"/{bin,proc,sys,dev,lower,runtime,guest,test/{runtime,x11,virtual-libs}}
p=$w/i/test
install -m755 "$7" "$w/i/bin/busybox"; install -m755 "$8" "$p/uv"; install -m755 "$q/../xorg-dsi/init" "$w/i/init"
sed -i '/^mount --bind \/test /,$d' "$w/i/init"
cat >> "$w/i/init" <<'EOF'
mount -t tmpfs tmpfs /guest/opt/panel-test
cp -a /test/. /guest/opt/panel-test/
cp /bin/busybox /guest/run/busybox
exec switch_root /guest /bin/bash /opt/panel-test/pid1.sh
EOF
cat > "$p/pid1.sh" <<'EOF'
export DEBIAN_FRONTEND=noninteractive
bash /opt/panel-test/guest.sh
echo "PANEL_CI_EXIT=$?"
exec /run/busybox poweroff -f
EOF
install -m755 "$q/orient-vm-guest.sh" "$p/guest.sh"
install -m644 "$q/"{virtual-guest.sh,virtual-shutter.py,orient-vm-check.py} "$p/"
install -m644 "$here/session.sh" "$p/virtual-session.sh"
install -m644 "$here/"{browser.py,page.html,consent.py,system.sh} "$p/"
if [[ ${10} == installed ]]; then
  touch "$p/installed-browser-camera"
else
  install -m644 "$3" "$p/qcam.deb"
fi
install -m644 "$6" "$p/vkms.ko"
install -m644 "$4/"*.deb "$p/runtime/"; install -m644 "$5/"{libxdo3,xdotool,xvfb}_*.deb "$p/x11/"
install -m755 "$lib/"{libcamera,libcamera-base}.so.0.7.2 "$p/virtual-libs/"; install -m755 "$lib/orientation-probe" "$p/"
sed -e '/"\/base\/.*camera@20":/,/^"\/base\/.*camera@10":/s@  test_pattern: "bars"@  frames:\n    path: "/run/qcam-qa/main-source.jpg"@' \
    -e '/"\/base\/.*camera@10":/,/^"\/fixture/s@  test_pattern: "lines"@  frames:\n    path: "/run/qcam-qa/front-source.jpg"@' "$q/virtual-cameras.yaml" > "$p/virtual-cameras.yaml"
if [[ ${10} != stock && ${10} != installed ]]; then
  [[ $(dpkg-deb -f "${10}" Package) == y700-camera-pipewire &&
     $(dpkg-deb -f "${10}" Architecture) == arm64 ]]
  install -m644 "${10}" "$p/pipewire.deb"
fi
# Enter the product user session only after the WM-independent system bus and loopback exist.
sed -i '/^runuser /i bash /opt/panel-test/system.sh' "$p/virtual-guest.sh"
(cd "$w/i" && find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$w/initrd")
args=(); [[ -z ${QEMU_DATA_DIR:-} ]] || args=(-L "$QEMU_DATA_DIR")
{ sha256sum "$disk" "$kernel" "$lib/"*.so.0.7.2
  [[ ${10} == stock || ${10} == installed ]] || sha256sum "${10}"
  timeout -k 4 650 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" -machine virt,gic-version=3 -cpu max -smp 4 -m 2600 -nodefaults -no-user-config -no-reboot -nic none -monitor none -display none -serial stdio -kernel "$kernel" -initrd "$w/initrd" -append 'console=ttyAMA0 quiet loglevel=3 panic=4 y700.qcam_virtual_fixture=1' -drive "if=none,id=base,format=raw,readonly=on,file=$disk" -device virtio-blk-device,drive=base
} </dev/null 2>&1 | tr -d '\r' | tee "$log"
grep -Fxq 'PANEL_CI_EXIT=0' "$log"
expected=4; [[ ${10} == stock ]] || expected=0
grep -Fxq "BROWSER_ORIENTATION_DONE cases=4 mismatches=$expected sandbox=1 portal=1 site=1" "$log"
if [[ ${10} == installed ]]; then grep -Fxq 'FRESH_BROWSER_USER uid=1000 camera_package=.5 mapped_spa=verified' "$log"; fi
