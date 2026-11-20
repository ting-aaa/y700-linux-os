#!/usr/bin/env bash
# Run on a Linux host. IW is the ARM64 Debian iw executable. ROOT is the
# integrated ARM64 base. INITRD is the gzip/newc initramfs from the board ESP.
# QEMU_SYSTEM_AARCH64 may select a private qemu-system-aarch64 installation.
set -euo pipefail
if [[ $# != 5 ]]; then
    echo 'Usage: early-boot.sh KERNEL INITRD ROOT IW NEW_LOG_DIRECTORY' >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/../.." && pwd)
kernel=$(realpath -e "$1")
initrd=$(realpath -e "$2")
root=$(realpath -e "$3")
iw=$(realpath -e "$4")
result=$(realpath -m "$5")
mkdir -m700 "$result"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
tree=$work/tree
mkdir "$tree"
(cd "$tree" && gzip -dc "$initrd" | cpio --quiet -id --no-absolute-filenames --no-preserve-owner)
firmware=$tree/lib/firmware
test -s "$firmware/ath11k/WCN6855/hw2.1/regdb.bin"
rm -f -- "$firmware/regulatory.db" "$firmware/regulatory.db.p7s"
sha256sum "$kernel" "$initrd" "$iw" > "$result/inputs.sha256"

install -m755 "$iw" "$tree/bin/iw"
install -m755 "$root/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1" "$tree/lib/"
for lib in libc.so.6 libnl-3.so.200 libnl-genl-3.so.200; do
    install -m755 "$root/usr/lib/aarch64-linux-gnu/$lib" "$tree/lib/$lib"
done
install -m755 "$repo/tests/wifi-regdb/probe-init" "$tree/regdb-test-init"
for variant in missing upstream debian; do
    case $variant in
        upstream) bash "$repo/scripts/stage-initrd-regdb.sh" "$root" "$firmware";;
        debian) install -m644 "$root/usr/lib/firmware/regulatory.db.p7s-debian" "$firmware/regulatory.db.p7s";;
    esac
    (cd "$tree" && find . -print0 | LC_ALL=C sort -z | cpio --quiet --null -o -H newc --owner 0:0 | gzip -n -2) > "$work/test-initrd"
    log=$result/$variant.log
    # No disk or radio. The kernel receives a test country hint, iw only reads it.
    timeout 90 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" -machine virt,gic-version=3 \
        -cpu max -smp 2 -m 768 -nodefaults -no-user-config -nic none -display none \
        -serial stdio -monitor none -no-reboot -kernel "$kernel" -initrd "$work/test-initrd" \
        -append 'console=ttyAMA0 rdinit=/regdb-test-init panic=1 cfg80211.ieee80211_regdom=CN' \
        > "$log" 2>&1
    grep -Fq 'REGDB_PROBE_COMPLETE' "$log"
    grep -Fq 'reboot: Power down' "$log"
    case $variant in
        missing) grep -Fq 'failed to load regulatory.db' "$log";;
        debian) grep -Fq 'regulatory.db is malformed or signature is missing/invalid' "$log";;
        upstream)
            if grep -Eq 'failed to load regulatory.db|signature is missing/invalid' "$log"; then exit 1; fi
            ;;
    esac
    if [[ $variant == upstream ]]; then country=CN; else country=00; fi
    grep -Fq "REGDB_DOMAIN=$country" "$log"
    printf '%s country=%s powered_off=yes\n' "$variant" "$country"
done
