#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 4 ]]; then
    echo 'Usage: run.sh KERNEL LEGACY_INITRD ROOT IW_DEB' >&2
    exit 2
fi
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
kernel=$(realpath -e "$1")
initrd=$(realpath -e "$2")
root=$(realpath -e "$3")
iw_deb=$(realpath -e "$4")
format=${ROOT_FORMAT:-raw}
qemu=${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}
case $format in raw|qcow2) ;; *) exit 2;; esac
[[ $(dpkg-deb -f "$iw_deb" Package) == iw ]]
[[ $(dpkg-deb -f "$iw_deb" Version) == 6.9-1+b1 ]]
[[ $(dpkg-deb -f "$iw_deb" Architecture) == arm64 ]]

work=$(mktemp -d /tmp/y700-regdb-legacy.XXXXXXXX)
[[ $(realpath -e "$work") =~ ^/tmp/y700-regdb-legacy\.[a-zA-Z0-9]{8}$ ]]
trap 'rm -r --one-file-system -- "$work"' EXIT
gzip -dc "$initrd" | cpio --quiet -it > "$work/archive-files"
grep -Fxq bin/busybox "$work/archive-files"
if grep -Eq '(^|/)regulatory\.db(\.p7s)?$' "$work/archive-files"; then
    echo 'Legacy initramfs already contains a generic regulatory database or signature' >&2
    exit 1
fi

tree=$work/tree
install -Dm755 "$here/init" "$tree/regdb-legacy-init"
install -Dm755 "$here/verify.sh" "$tree/regdb-test/verify.sh"
install -Dm644 "$here/verify.service" "$tree/regdb-test/verify.service"
install -Dm644 "$here/../../packaging/wifi-regdb/y700-wireless-regdb.service" "$tree/regdb-test/y700-wireless-regdb.service"
install -Dm644 "$iw_deb" "$tree/regdb-test/iw.deb"
sha256sum "$kernel" "$initrd" "$iw_deb" "$tree/regdb-test/y700-wireless-regdb.service"
# Preserve the original gzip/newc member and append a separate test payload.
cat "$initrd" > "$work/initrd"
(cd "$tree" && find . -print0 | LC_ALL=C sort -z | cpio --quiet --null -o -H newc --owner 0:0 | gzip -n) >> "$work/initrd"
qemu_data=()
if [[ -n ${QEMU_DATA:-} ]]; then qemu_data=(-L "$QEMU_DATA"); fi
timeout -k 5 160 "$qemu" "${qemu_data[@]}" -machine virt,gic-version=3 -cpu max -smp 2 -m 1024 \
    -nodefaults -no-user-config -nic none -display none -monitor none -serial stdio -no-reboot \
    -kernel "$kernel" -initrd "$work/initrd" \
    -append 'console=ttyAMA0 quiet loglevel=3 panic=1 rdinit=/regdb-legacy-init y700.regdb_legacy=1 fstab=no systemd.unit=y700-regdb-verify.service' \
    -drive "if=none,id=root,format=$format,readonly=on,file=$root" -device virtio-blk-device,drive=root \
    2>&1 | tr -d '\r' | tee "$work/serial.log"
grep -Eq '(^|: )REGDB_LEGACY_PASS early_enoent=1 service_exit=0 regdb_active_us=[1-9][0-9]* nm_active_us=[1-9][0-9]* radio_count=0$' "$work/serial.log"
grep -Eq '(^|: )REGDB_LEGACY_ROLLBACK alternatives_auto=1 unit_removed=1 iw_absent=1$' "$work/serial.log"
grep -Fq 'reboot: Power down' "$work/serial.log"
