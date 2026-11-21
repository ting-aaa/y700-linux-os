#!/bin/bash
# Exercise both production packages and both Debian rollback packages with no NIC.
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: run-qemu.sh SEALED_ROOT UPDATE_DIR NEW_LOG' >&2; exit 2; }
: "${QEMU:?}" "${QEMU_DATA:?}" "${KERNEL_IMAGE:?}" "${ARM64_BUSYBOX:?}"
here=$(cd "$(dirname "$0")" && pwd -P)
raw=$(realpath -e "$1"); update=$(realpath -e "$2"); log=$(realpath -m "$3")
[[ ! -e $log && ! -L $3 && -d ${log%/*} ]]
printf '%s  %s\n' 18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd "$raw" \
    4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1 "$KERNEL_IMAGE" | sha256sum --strict -c -
cmp "$here/../../config/wifi-sae-update.sha256" "$update/SHA256SUMS"
(cd "$update" && sha256sum --strict -c SHA256SUMS)
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-wifi-sae-lifecycle.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
cd "$work"
mkdir -p init/{bin,proc,sys,dev,lower,runtime,guest,test/update}
install -m755 "$ARM64_BUSYBOX" init/bin/busybox
install -m755 "$here/../wifi-chooser/fixture-init.sh" init/init
cp -r "$update"/{SHA256SUMS,candidate,stock} init/test/update/
cp "$here/check-lifecycle.sh" init/test/update/
cat > init/test/fixture-guest.sh <<'GUEST'
#!/bin/bash
set -euo pipefail
tr '\000' '\n' </proc/device-tree/compatible | grep -Fxq linux,dummy-virt
[[ $(uname -m) == aarch64 && $(uname -r) == 7.3.4-asphalt-prc ]]
mkdir /run/wifi-update
cp -r /opt/wifi-test/update/. /run/wifi-update/
dbus-uuidgen > /etc/machine-id
exec setpriv --bounding-set=-sys_module,-sys_admin,-sys_boot,-sys_rawio,-sys_time \
    env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C DEBIAN_FRONTEND=noninteractive \
    bash /run/wifi-update/check-lifecycle.sh
GUEST
(cd init && find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > ../test.cpio.gz)
timeout -k 5 420 "$QEMU" -L "$QEMU_DATA" -machine virt,gic-version=3 -cpu max -m 1280 -smp 3 \
    -nodefaults -no-user-config -nic none -monitor none -display none -serial stdio -no-reboot \
    -kernel "$KERNEL_IMAGE" -initrd test.cpio.gz -append 'console=ttyAMA0 quiet loglevel=3 panic=5 y700.wifi_fixture=1' \
    -drive "file=$raw,format=raw,readonly=on,if=none,id=root" -device virtio-blk-device,drive=root \
    2>&1 | tr -d '\r' | tee "$log"
grep -Fxq WIFI_VM_EXIT=0 "$log" && grep -Fxq WIFI_UPDATE_LIFECYCLE_PASS "$log"
