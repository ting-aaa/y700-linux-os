#!/bin/bash
# Uses the ordinary dev12.10 Mesa libraries, a private tmpfs and no DRM device.
set -euo pipefail
[[ $# == 3 && $EUID == 0 ]] || { echo 'Usage as root: software-control.sh DEV12.10_ROOT ARM64_ELF NEW_RESULTS' >&2; exit 2; }
if [[ $(readlink /proc/self/ns/mnt) == "$(readlink /proc/1/ns/mnt)" || $(findmnt -nro PROPAGATION -T /) != private ]]; then
    exec unshare --mount --propagation private --net -- bash "$0" "$@"
fi
image=$(realpath -e "$1")
exe=$(realpath -e "$2")
out=$(realpath -m "$3")
mkdir -m700 "$out"
echo "18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd  $image" | sha256sum --strict -c -
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
timeout -k2 45 "${runner[@]}" LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe LP_NUM_THREADS=1 /tmp/probe --software-control >"$out/software.log" 2>&1
grep -F 'GPU_SOFTWARE_CONTROL_PASS contexts=3 frames=12 pixels=24576' "$out/software.log"
if timeout -k2 15 "${runner[@]}" /tmp/probe >"$out/hardware-refusal.log" 2>&1; then exit 1; fi
grep -Fx 'GPU_CHECK_FAILED no render node' "$out/hardware-refusal.log"
(cd "$out" && sha256sum software.log hardware-refusal.log >SHA256SUMS)
