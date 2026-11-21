#!/bin/bash
# Uses the image's Mesa libraries, a private tmpfs and no DRM device.
set -euo pipefail
[[ $EUID == 0 ]] || exit 2
if [[ $(readlink /proc/self/ns/mnt) == "$(readlink /proc/1/ns/mnt)" || $(findmnt -nro PROPAGATION -T /) != private ]]; then
    exec unshare --mount --propagation private --net -- bash "$0" "$@"
fi
probe=gles
expected=18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd
if [[ ${1:-} == --vulkan-dev12.11 ]]; then
    shift
    probe=vulkan
    expected=33ce23e8edac1d9c445c6b360a6355a189a151804352b032efe51320287d17a3
fi
[[ $# == 3 ]] || { echo 'Usage: software-control.sh [--vulkan-dev12.11] SEALED_ROOT ARM64_ELF NEW_RESULTS' >&2; exit 2; }
image=$(realpath -e "$1")
exe=$(realpath -e "$2")
out=$(realpath -m "$3")
mkdir -m700 "$out"
echo "$expected  $image" | sha256sum --strict -c -
r=$(mktemp -d /var/tmp/y700-render-control.XXXXXXXX)
cleanup() {
    cd /
    for m in "$r/dev" "$r/proc" "$r/tmp" "$r"; do if mountpoint -q "$m"; then umount "$m" || return 1; fi; done
    rmdir "$r"
}
trap cleanup EXIT
mount -t ext4 -o ro,loop,noload "$image" "$r"
mount -t tmpfs -o mode=1777,size=64M tmpfs "$r/tmp"
mount -t proc -o nosuid,nodev,noexec proc "$r/proc"
mount -t tmpfs -o size=2M tmpfs "$r/dev"
mknod -m666 "$r/dev/null" c 1 3
mknod -m666 "$r/dev/urandom" c 1 9
install -m755 "$exe" "$r/tmp/probe"
runner=(chroot --userspec=65534:65534 "$r" /usr/bin/env -i PATH=/usr/bin:/bin HOME=/tmp LC_ALL=C MESA_SHADER_CACHE_DISABLE=true)
if [[ $probe == vulkan ]]; then
    install -d -m700 -o 65534 -g 65534 "$r/tmp/runtime"
    runner+=(VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json XDG_RUNTIME_DIR=/tmp/runtime LP_NUM_THREADS=1)
    timeout -k2 45 "${runner[@]}" /tmp/probe --software-control >"$out/software.log" 2>&1
    grep -F 'VULKAN_SOFTWARE_CONTROL_PASS' "$out/software.log"
    if timeout -k2 20 "${runner[@]}" /tmp/probe >"$out/hardware-refusal.log" 2>&1; then exit 1; fi
    grep -Fx 'VULKAN_FAIL no Turnip Adreno 730 hardware device' "$out/hardware-refusal.log"
else
    timeout -k2 45 "${runner[@]}" LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe LP_NUM_THREADS=1 /tmp/probe --software-control >"$out/software.log" 2>&1
    grep -F 'GPU_SOFTWARE_CONTROL_PASS contexts=3 frames=12 pixels=24576' "$out/software.log"
    if timeout -k2 15 "${runner[@]}" /tmp/probe >"$out/hardware-refusal.log" 2>&1; then exit 1; fi
    grep -Fx 'GPU_CHECK_FAILED no render node' "$out/hardware-refusal.log"
fi
(cd "$out" && sha256sum software.log hardware-refusal.log >SHA256SUMS)
