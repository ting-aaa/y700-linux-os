#!/usr/bin/env bash
set -euo pipefail
touch_auth=false
if [[ ${1:-} == --touch-auth ]]; then touch_auth=true; shift; fi
[[ $# == 6 || $# == 7 ]] || { echo 'run.sh DEV1213_ROOT KERNEL ARM64_BUSYBOX DUMMY.deb ARM64_UV FOUR_ARCHIVES_DIR [PRODUCT_ARCHIVES]'; exit 2; }
if $touch_auth && [[ $# != 7 ]]; then echo 'The touch-auth run requires the product desktop entry.' >&2; exit 2; fi
here=$(cd "$(dirname "$0")" && pwd)
common=$here/../display-touch-topology
root=$(realpath -e "$1"); kernel=$(realpath -e "$2"); archives=$(realpath -e "$6")
echo "6155d87d5d5b9d5557e86362f09fb17328aef200861e94eb292a669c35659c7c  $root" | sha256sum --strict -c -
echo "0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60  $kernel" | sha256sum --strict -c -
(cd "$archives" && sha256sum --strict -c - <<'HASH'
22133c8d6557bde95c38dabf5d947b616ef398fa9d6f59181c12eac6a2cef345  gnome-package-updater_43.0-4_arm64.deb
b7a8e1b5bfb032e24f8e83a005af9edafd2d108daa3f9894fde0c366f5dce6d0  gnome-packagekit-common_43.0-4_all.deb
38edb33fc56cdfb8a1eb5db52eee0410514217d024f4073bb3906cd030c93b7f  libpackagekit-glib2-18_1.3.1-1+deb13u1_arm64.deb
91bbd203d2b713e634507b7a160595db5323a519fe338ccf61d80e3dd43934e2  packagekit_1.3.1-1+deb13u1_arm64.deb
HASH
)
work=$(mktemp -d "${TMPDIR:-/tmp}/y700-apt-ui.XXXXXXXX"); trap 'rm -r --one-file-system -- "$work"' EXIT
mkdir -p "$work/payload/debs"
# Reuse the known Xorg/libinput layout, replacing its standalone daemon/session startup.
sed -e '/^dbus-daemon --system --fork$/d' -e '/^\/usr\/lib\/systemd\/systemd-udevd --daemon$/d' \
    -e 's@^runuser -u y700 .*@bash ./seat.sh@' "$common/guest.sh" > "$work/payload/xorg.sh"
cp "$here"/{guest.sh,session.sh,probe.py,auth.py,seat.sh,transactions.py} "$work/payload/"
if $touch_auth; then
    touch "$work/payload/touch-auth-mode"
    cp "$here/touch_auth.py" "$work/payload/"
fi
for file in gnome-package-updater_43.0-4_arm64.deb gnome-packagekit-common_43.0-4_all.deb \
            libpackagekit-glib2-18_1.3.1-1+deb13u1_arm64.deb packagekit_1.3.1-1+deb13u1_arm64.deb; do
    cp "$archives/$file" "$work/payload/debs/"
done
if [[ $# == 7 ]]; then
    product=$(realpath -e "$7")
    (cd "$product" && sha256sum --strict -c - <<'HASH'
378041bae6ed8ca97c3e7ba77465d02f977e24e1f61594e9f4691eb403b8eb00  gir1.2-packagekitglib-1.0_1.3.1-1+deb13u1_arm64.deb
547ea83736f209c8175e30047eed1a57e8afbe481115e0bf3d166017c2d3b2ae  y700-software-updates_0.1.0_all.deb
HASH
    )
    cp "$product"/{gir1.2-packagekitglib-1.0_1.3.1-1+deb13u1_arm64,y700-software-updates_0.1.0_all}.deb "$work/payload/debs/"
    touch "$work/payload/product-mode"
fi
install -m755 "$5" "$work/payload/uv"
bash "$here/make-repo.sh" "$work" "$work/payload"
touchdir="$work/init/test"
mkdir -p "$work/init"/{bin,dev,guest,lower,proc,run,sys,test}
printf '%s  %s\n' 5ed4d469b062060a051d7d0e5edaaf5f1d3c93d9abc3f7989e1beee018cc0c5d "$4" | sha256sum -c -
install -m755 "$3" "$work/init/bin/busybox"
install -m755 "$here/init" "$work/init/init"
cp "$here/seat.service" "$touchdir/"
cp -a "$work/payload/." "$touchdir/"
cp "$4" "$touchdir/dummy.deb"
date -u +%s > "$touchdir/fixture-epoch"
touch "$touchdir/old-watcher"
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -O2 -Wall -Wextra -Werror -static "$here/../brightness/slider-touch-input.c" -o "$touchdir/evdev-touch"
(cd "$work/init" && find . -print0 | cpio -o --null --quiet -H newc | gzip -1 > "$work/initrd")
qemu_args=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then qemu_args+=(-L "$QEMU_FIRMWARE_DIR"); fi
timeout -k 4 425 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${qemu_args[@]}" -machine virt,gic-version=3 \
    -cpu max -smp 3 -m 1536 -nodefaults -no-user-config -monitor none -display none -serial stdio -nic none -no-reboot \
    -kernel "$kernel" -initrd "$work/initrd" -append 'console=ttyAMA0 loglevel=3 y700.touch_gesture_fixture=1 y700.topology_fixture=1 panic=4 fstab=no systemd.unit=y700-updater-qa.service systemd.show_status=no' \
    -drive "if=none,id=root,format=raw,readonly=on,file=$root" -device virtio-blk-device,drive=root \
    </dev/null 2>&1 | tr -d '\r' | tee "$work/console"
grep -Fxq UPDATER_GUEST_EXIT=0 "$work/console"
