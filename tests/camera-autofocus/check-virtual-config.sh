#!/bin/bash
# Exercise the probe against Debian's real, NV12-only synthetic camera on a PC.
set -euo pipefail
export LC_ALL=C
if [[ ${1:-} != --inside ]]; then
    [[ $EUID == 0 && ( $# == 3 || $# == 4 ) ]] || {
        echo 'Usage as root: check-virtual-config.sh ARM64_ROOT_DIR VIRTUAL_RUNTIME_DEBS MEASUREMENT_ELF [CONFIG_ONLY_LIB_DIR]' >&2
        exit 2
    }
    exec unshare --mount --propagation private --net --pid --fork --kill-child bash "$0" --inside "$@"
fi
shift
root=$(realpath -e "$1")
packages=$(realpath -e "$2")
tool=$(realpath -e "$3")
config_libs=
if [[ $# == 4 ]]; then config_libs=$(realpath -e "$4"); fi
lock=$(realpath -e "$(dirname "$0")/../qcam-photo/virtual-runtime.sha256")
[[ $root != / && -x $root/usr/bin/setpriv ]]
(cd "$packages" && sha256sum --strict --status -c "$lock")
w=$(mktemp -d /var/tmp/y700-virtual-af-config.XXXXXXXX)
r=$w/mnt
cleanup() {
    if mountpoint -q "$r"; then umount -R "$r" || return 1; fi
    rm -r --one-file-system -- "$w"
}
trap cleanup EXIT
mkdir "$r" "$w"/{upper,work,deps}
while read -r _ name; do dpkg-deb -x "$packages/$name" "$w/deps"; done <"$lock"
mount -t overlay overlay -o "lowerdir=$w/deps:$root,upperdir=$w/upper,workdir=$w/work" "$r"
mount -t tmpfs -o mode=0755 tmpfs "$r/run"
mount -t tmpfs -o mode=0755 tmpfs "$r/sys"
mount -t tmpfs -o mode=0755 tmpfs "$r/dev"
mount -t proc -o nosuid,nodev,noexec proc "$r/proc"
mknod -m666 "$r/dev/null" c 1 3
mknod -m666 "$r/dev/urandom" c 1 9
mkdir -m1777 "$r/dev/shm"
install -m755 "$tool" "$r/run/optical"
dir=$r/usr/share/libcamera/pipeline/virtual
mkdir -p "$dir"
cat >"$dir/virtual.yaml" <<'YAML'
%YAML 1.1
---
"/base/soc@0/cci@ac15000/i2c-bus@0/camera@20":
  supported_formats:
  - width: 800
    height: 600
    frame_rates: [30, 60]
  - width: 640
    height: 480
    frame_rates: [30, 60]
  test_pattern: "bars"
  location: "CameraLocationBack"
  model: "Synthetic configuration"
YAML
probe() {
    local mode=$1 libs=$2
    shift 2
    rc=0
    timeout 15 chroot "$r" /usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups \
        /usr/bin/env -i HOME=/tmp LC_ALL=C "LD_LIBRARY_PATH=$libs" \
        LIBCAMERA_PIPELINES_MATCH_LIST=virtual LIBCAMERA_LOG_LEVELS='*:FATAL' "$@" \
        /run/optical "$mode" >"$w/result" 2>&1 || rc=$?
    cat "$w/result"
}
for mode in --check-rear-config --rear-af; do
    probe "$mode" /usr/lib/aarch64-linux-gnu
    [[ $rc == 1 ]]
    for row in 'step=lookup rear=1' 'step=acquire rc=0' 'step=validate status=adjusted streams=1' \
               'step=validated width=640 height=480 format=NV12 fourcc=0x3231564e stride=640' \
               'step=configure called=0 rc=none errno=none' 'step=release rc=0'; do
        grep -Fxq "AF_CONFIG $row" "$w/result"
    done
    grep -Fxq 'AF_ERROR reason=no_cpu_rgb_mode' "$w/result"
    echo "VIRTUAL_CONFIG_REJECTION mode=$mode exit=$rc"
done
if [[ -n $config_libs ]]; then
    # Separate synthetic pipeline for ABGR negotiation. It rejects frame export and start.
    mkdir -p "$r/run/config-only" "$r/opt/y700-camera/share/libcamera/pipeline/virtual"
    install -m644 "$dir/virtual.yaml" "$r/opt/y700-camera/share/libcamera/pipeline/virtual/"
    for lib in libcamera libcamera-base; do
        install -m755 "$config_libs/$lib.so.0.7.2" "$r/run/config-only/$lib.so.0.7"
    done
    libs=/run/config-only:/usr/lib/aarch64-linux-gnu
    probe --check-rear-config "$libs"
    [[ $rc == 0 ]]
    grep -Fxq 'AF_CONFIG step=configure called=1 rc=0 errno=0' "$w/result"
    grep -Fxq 'AF_CONFIG step=configured width=640 height=480 format=ABGR8888 fourcc=0x34324241 stride=2560' "$w/result"
    grep -Fxq 'AF_CONFIG step=release rc=0' "$w/result"
    grep -Fxq 'AF_CONFIG_ONLY result=pass allocated=0 started=0 queued=0 af_triggered=0 pixels_read=0' "$w/result"
    echo 'VIRTUAL_CONFIG_ACCEPTED exit=0'
    probe --check-rear-config "$libs" Y700_QA_CONFIG_ENOSPC=1
    [[ $rc == 1 ]]
    grep -Fxq 'AF_CONFIG step=configure called=1 rc=-28 errno=28' "$w/result"
    grep -Fxq 'AF_CONFIG step=release rc=0' "$w/result"
    grep -Fxq 'AF_ERROR reason=configure_failed' "$w/result"
    echo 'VIRTUAL_CONFIG_ERROR errno=28 exit=1'
fi
