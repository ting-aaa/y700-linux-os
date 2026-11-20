#!/usr/bin/env bash
# Short ARM64 policy test on two new writable QEMU disk files. Run as root on Linux.
set -euo pipefail
umask 077
if [[ $# != 3 || $EUID != 0 ]]; then
    echo 'Usage (root): bash tests/ram-media/run.sh SEALED_ROOT_EXT4 RAM_BUNDLE NEW_LOG_DIR' >&2
    exit 2
fi
if [[ -z ${Y700_MEDIA_MNTNS:-} ]]; then
    exec unshare -m -- env Y700_MEDIA_MNTNS=1 bash "$0" "$@"
fi
mount --make-rprivate /
here=$(cd -- "$(dirname -- "$0")" && pwd)
src=$(realpath -e "$1")
bundle=$(realpath -e "$2")
logs=$(realpath -m "$3")
[[ -f $src && ! -e $logs && ! -L $logs ]]
mkdir -m 0700 "$logs"
work=$(mktemp -d /var/tmp/y700-ram-media.XXXXXXXX)
root=$work/root
tree=$work/tree
cleanup(){
    if mountpoint -q "$root"; then umount "$root"; fi
    rm -r --one-file-system "$work"
}
trap cleanup EXIT
mkdir -p "$root" "$tree"
[[ $(sha256sum "$src" | cut -d' ' -f1) == 041fcf2e04b5d05edbfa3147f442a019d2f260f6544b9182087bf911ff8e55b6 ]]
(cd "$bundle"
    sha256sum --strict --check SHA256SUMS
    printf '%s  kernel.efi\n' 4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1 |
        sha256sum --strict --check
)
mount -o loop,ro,noload "$src" "$root"
# Recover the exact policy and busybox from the provided bundle, never from a
# host rule directory. GNU gzip stops after the stock compressed member.
cd "$work"
uv run --offline --no-project --python /usr/bin/python3 python - "$bundle/initrd" <<'PY'
from pathlib import Path
import sys
import zlib
inflator = zlib.decompressobj(31)
with open(sys.argv[1], "rb") as source, open("stock.cpio", "wb") as target:
    while not inflator.eof:
        chunk = source.read(1 << 20)
        if not chunk:
            raise SystemExit("Incomplete stock gzip")
        target.write(inflator.decompress(chunk))
    size = source.tell() - len(inflator.unused_data)
Path("offset").write_text(str((size + 3) // 4 * 4))
PY
mkdir -p "$tree"/{bin,dev,proc,sys,run,tmp,etc/udev/rules.d,usr/lib/systemd}
(cd "$tree"; cpio --quiet -idm bin/busybox < "$work/stock.cpio")
tail -c "+$(( $(cat offset) + 1 ))" "$bundle/initrd" | cpio --quiet -id y700-ram-trial-init
awk '/^cat > "\$rules" <<.RULES./ {copy=1; next} copy && /^RULES$/ {exit} copy {print}' \
    y700-ram-trial-init > "$tree/etc/udev/rules.d/99-y700-ram-media.rules"
sed -n '/^for block in \/sys\/class\/block\/\*; do$/,/^done$/p' y700-ram-trial-init > "$tree/qa-cold.sh"
grep -Fq 'blockdev --setro' "$tree/qa-cold.sh"
test "$(wc -l < "$tree/etc/udev/rules.d/99-y700-ram-media.rules")" = 2
udevadm verify "$tree/etc/udev/rules.d/99-y700-ram-media.rules"
uv run --offline --no-project --python /usr/bin/python3 python "$here/elf.py" "$root" "$tree"
ln -s ../../bin/udevadm "$tree/usr/lib/systemd/systemd-udevd"
# Some util-linux/systemd dependencies on usr-merged Debian resolve through /lib.
mkdir -p "$tree/lib"
ln -s ../usr/lib/aarch64-linux-gnu "$tree/lib/aarch64-linux-gnu"
for f in passwd group nsswitch.conf; do cp "$root/etc/$f" "$tree/etc/$f"; done
zstd -dq "$root/usr/lib/modules/7.3.4-asphalt-prc/kernel/drivers/usb/storage/usb-storage.ko.zst" -o "$tree/qa-usb-storage.ko"
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -O2 -Wall -Wextra -Werror -static "$here/open.c" -o "$tree/qa-open"
install -m 0755 "$here/guest-init" "$tree/qa-init"
(cd "$tree"; find . -print0 | sort -z | cpio --null --quiet -o -H newc | gzip -n -1) > mini-initrd.gz
sha256sum y700-ram-trial-init "$tree/etc/udev/rules.d/99-y700-ram-media.rules" "$tree/qa-cold.sh" > "$logs/policy.sha256"
umount "$root"
uv run --offline --no-project --python /usr/bin/python3 python "$here/qemu.py" \
    "$work" "$logs" "$bundle/kernel.efi" "$work/mini-initrd.gz" "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" | tee "$logs/check.log"
