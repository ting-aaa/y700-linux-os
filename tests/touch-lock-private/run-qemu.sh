#!/bin/bash
# Native ARM64 kernel handles setgid unix_chkpwd; the product disk is read-only.
set -euo pipefail
if (( $# != 6 && $# != 8 )) || [[ $# == 8 && $7 != --rotation-package ]]; then
    echo 'Usage: run-qemu.sh SEALED_ROOT.ext4 KERNEL_IMAGE ARM64_BUSYBOX ARM64_UV CANDIDATE_ARCHIVES ARM64_HELPER_USR [--rotation-package PLATFORM.deb]' >&2
    exit 2
fi
root=$(realpath -e "$1")
kernel=$(realpath -e "$2")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/y700-lock-retry.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
init=$work/init
stage=$init/check
mkdir -p "$init/"{bin,dev,proc,sys,base} "$stage/helpers/"{bin,lib/aarch64-linux-gnu}
printf '%s  %s\n' 041fcf2e04b5d05edbfa3147f442a019d2f260f6544b9182087bf911ff8e55b6 "$root" \
    4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1 "$kernel" | sha256sum --strict -c -
bash "$here/stage.sh" "$5" "$stage"
install -m755 "$3" "$init/bin/busybox"
install -m755 "$4" "$stage/uv"
install -m755 "$6/bin/"{Xvfb,xdotool} "$stage/helpers/bin/"
install -m644 "$6/lib/aarch64-linux-gnu/libxdo.so.3" "$stage/helpers/lib/aarch64-linux-gnu/"
touch "$stage/retry-in-place"
if (( $# == 8 )); then
    platform=$(realpath -e "$8")
    [[ $(dpkg-deb -f "$platform" Package) == y700-platform && $(dpkg-deb -f "$platform" Architecture) == all ]]
    echo "ROTATION_PACKAGE version=$(dpkg-deb -f "$platform" Version) sha256=$(sha256sum "$platform" | cut -d' ' -f1)"
    dpkg-deb -x "$platform" "$work/platform"
    mkdir "$stage/rotation"
    cp "$work/platform/usr/lib/y700/"{y700-auto-rotate.py,rotation_session.py} "$stage/rotation/"
    cp "$work/platform/usr/share/glib-2.0/schemas/org.y700.tablet.gschema.xml" "$stage/rotation/"
    glib-compile-schemas --strict "$stage/rotation"
    cp "$here/../rotation-session.py" "$stage/rotation/providers.py"
    cp "$here/rotation.py" "$stage/rotation/"
    (cd "$stage" && sha256sum rotation/* >> SHA256SUMS)
fi
cat > "$init/init" <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
finish() {
    echo "PRIVATE_RETRY_GUEST_EXIT=$?"
    poweroff -f
}
trap finish EXIT
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs dev /dev
test "$(cat /sys/block/vda/ro)" = 1
mount -t ext4 -o ro,noload /dev/vda /base
for d in dev proc sys; do mount --bind "/$d" "/base/$d"; done
mount -t tmpfs tmpfs /base/run
s=/run/y700-private-retry
mkdir -m700 "/base$s"
cp -a /check/. "/base$s/"
mkdir "/base$s/root"
for ns in pid mnt net ipc; do readlink "/proc/self/ns/$ns" >"/base$s/host-$ns"; done
export PATH=/usr/sbin:/usr/bin:/bin PRIVATE_LOCK_UV="$s/uv"
/bin/busybox chroot /base /bin/bash -ec 'cd "$1"; sha256sum -c SHA256SUMS; \
    unshare --mount --pid --fork --kill-child --ipc --net --propagation private \
    bash "$1/namespace.sh" "$1" / "$1/helpers"' bash "$s"
INIT
chmod 755 "$init/init"
(cd "$init"; find . -print0 | cpio --null --quiet -o -H newc | gzip -1 >"$work/initrd")
qemu_args=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then qemu_args+=(-L "$QEMU_FIRMWARE_DIR"); fi
timeout -k 4 280 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${qemu_args[@]}" \
    -machine virt,gic-version=3 -cpu max -smp 2 -m 1200 -nodefaults -no-user-config -monitor none \
    -nic none -display none -serial stdio -no-reboot -kernel "$kernel" -initrd "$work/initrd" \
    -append 'console=ttyAMA0 quiet loglevel=3 panic=3' \
    -drive "if=none,id=root,format=raw,readonly=on,file=$root" -device virtio-blk-device,drive=root \
    </dev/null 2>&1 | tr -d '\r' | tee "$work/guest.log"
grep -Fxq 'PRIVATE_RETRY_PASS native_pam=rejected-then-accepted dialog=unchanged input=pointer-only letters-and-return=onboard supplementary_groups=0' "$work/guest.log"
grep -Fxq 'PRIVATE_RETRY_GUEST_EXIT=0' "$work/guest.log"
if (( $# == 8 )); then
    grep -Fxq 'ROTATION_LOCK_RESUMED real_saver=inactive logind_hint=false fresh_lease=1 helper_calls=left,inverted stale_right=absent' "$work/guest.log"
fi
