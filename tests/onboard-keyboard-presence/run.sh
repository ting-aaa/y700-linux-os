#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 5 ]]; then
    echo 'Usage: run.sh ROOT_QCOW2 Y700_IMAGE VKMS_MODULE ARM64_BUSYBOX ARM64_UV' >&2
    exit 2
fi
fixture=$(cd -- "$(dirname -- "$0")" && pwd -P)
root=$(realpath -e "$1")
kernel=$(realpath -e "$2")
work=$(mktemp -d /tmp/y700-onboard-presence.XXXXXXXX)
[[ $(realpath -e "$work") =~ ^/tmp/y700-onboard-presence\.[a-zA-Z0-9]{8}$ ]]
trap 'rm -r --one-file-system -- "$work"' EXIT
tree=$work/tree
test_dir=$tree/test
mkdir -p "$tree/"{bin,dev,proc,sys,lower,upper,guest,test}
install -m755 "$4" "$tree/bin/busybox"
install -m755 "$5" "$test_dir/uv"
install -m644 "$3" "$test_dir/vkms.ko"
install -m755 "$fixture/init" "$tree/init"
cp "$fixture/"{guest.sh,actor.sh,check.py} "$test_dir/"
candidate=${PLATFORM_DEB:-}
profile=${ONBOARD_PROFILE:-default}
case $profile in default|external-off) ;; *) exit 2;; esac
focus=${ONBOARD_FOCUS:-gtk}
case $focus in gtk|touch) ;; *) exit 2;; esac
if [[ -n $candidate ]]; then
    [[ $(dpkg-deb -f "$candidate" Package) == y700-platform ]]
    sha256sum "$candidate"
    install -m644 "$candidate" "$test_dir/platform.deb"
fi
if [[ -n ${ONBOARD_DEB:-} ]]; then
    [[ $(dpkg-deb -f "$ONBOARD_DEB" Package) == onboard ]]
    sha256sum "$ONBOARD_DEB"
    install -m644 "$ONBOARD_DEB" "$test_dir/onboard.deb"
fi
cc=${AARCH64_CC:-aarch64-linux-gnu-gcc}
"$cc" -O2 -Wall -Wextra -Werror -static "$fixture/uhid.c" -o "$test_dir/uhid"
"$cc" -O2 -Wall -Wextra -Werror -static "$fixture/../touch-gestures/evdev-touch.c" -o "$test_dir/evdev-touch"
(cd "$tree" && find . -print0 | LC_ALL=C sort -z | cpio --quiet --null -o -H newc --owner 0:0 | gzip -1) > "$work/initrd"
sha256sum "$root" "$kernel" "$3"
qemu_data=()
if [[ -n ${QEMU_DATA:-} ]]; then qemu_data=(-L "$QEMU_DATA"); fi
timeout -k 5 600 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${qemu_data[@]}" -machine virt,gic-version=3 \
    -cpu max -smp 3 -m 1536 -nodefaults -no-user-config -monitor none -display none -serial stdio -nic none -no-reboot \
    -kernel "$kernel" -initrd "$work/initrd" \
    -append "console=ttyAMA0 quiet loglevel=3 panic=5 y700.onboard_fixture=1 y700.onboard_profile=$profile y700.onboard_focus=$focus y700.touch_gesture_fixture=1 fstab=no systemd.unit=onboard-fixture.service systemd.show_status=no" \
    -drive "if=none,id=root,format=qcow2,readonly=on,file=$root" -device virtio-blk-device,drive=root \
    2>&1 | tr -d '\r' | tee "$work/guest.log"
grep -Fxq 'ONBOARD_GUEST_EXIT=0' "$work/guest.log"
grep -Eq '^ONBOARD_PRESENCE_PASS detection=(true|false)$' "$work/guest.log"
if [[ -n $candidate && $profile == default ]]; then grep -Fxq 'ONBOARD_PRESENCE_PASS detection=true' "$work/guest.log"; fi
if [[ -n ${ONBOARD_DEB:-} ]]; then
    grep -Fxq 'ONBOARD_RUNTIME_DETECTION_PASS focused=1 attached=1 hidden_again=1' "$work/guest.log"
fi
if [[ $profile == external-off ]]; then grep -Fxq 'ONBOARD_PROFILE user_value=false preserved=1' "$work/guest.log"; fi
grep -Fq 'reboot: Power down' "$work/guest.log"
