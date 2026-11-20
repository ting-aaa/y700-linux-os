#!/bin/bash
# Exercise the sealed desktop on the running board's CPU using only RAM.
set -euo pipefail
if (( $# != 3 )); then
    echo 'Usage: run.sh PINNED_USB_SSH SEALED_RAM_BUNDLE DEVICE_XVFB_USR' >&2
    exit 2
fi
ssh=$(realpath -e "$1")
bundle=$(realpath -e "$2")
helper=$3
[[ $helper =~ ^/var/tmp/[A-Za-z0-9._/-]+/usr$ && $helper != */../* ]]
here=$(cd "$(dirname "$0")" && pwd)
source "$here/profiles.sh"
initrd_sha=$(sha256sum "$bundle/initrd" | cut -d' ' -f1)
ram_profile "$initrd_sha"
stage=$(bash "$ssh" bash -s <<'CHECK'
set -eu
test "$(uname -m)" = aarch64
tr '\0' '\n' </proc/device-tree/compatible | grep -Fxq 'lenovo,asphalt'
tr '\0' '\n' </proc/device-tree/compatible | grep -Fxq 'qcom,sm8475'
test "$(findmnt -nro FSTYPE -T /run)" = tmpfs
test "$(wc -l </proc/swaps)" = 1
awk '/MemAvailable:/ {exit !($2 >= 8*1024*1024)}' /proc/meminfo
df -PB1 /run | awk 'NR==2 {exit !($4 >= 3*1024^3)}'
umask 077
mktemp -d /run/y700-ram-userspace.XXXXXXXX
CHECK
)
[[ $stage =~ ^/run/y700-ram-userspace\.[[:alnum:]]{8}$ ]]
cleanup() {
    bash "$ssh" "cd / && test -d '$stage' && ! grep -Fq '$stage/' /proc/self/mountinfo && rm -r --one-file-system -- '$stage' && test ! -e '$stage'" ||
        { echo 'Could not verify RAM staging cleanup' >&2; exit 1; }
}
trap cleanup EXIT
actors=(-C "$here" device.sh namespace.sh desktop.sh thunar.sh profiles.sh)
if [[ $release == dev12.8 || $release == dev12.9 ]]; then actors+=(brightness.py -C "$here/../brightness" probe.py); fi
tar -cf - "${actors[@]}" |
    bash "$ssh" "umask 077; tar -xf - -C '$stage'"
start=$SECONDS
timeout 180 bash "$ssh" "umask 077; cat > '$stage/initrd'" <"$bundle/initrd"
printf 'RAM_USERSPACE usb_bytes=%s seconds=%s\n' "$(stat -c %s "$bundle/initrd")" "$((SECONDS-start))"
bash "$ssh" bash "$stage/device.sh" "$stage" "$helper" "$initrd_sha"
