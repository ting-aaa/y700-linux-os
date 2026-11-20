#!/usr/bin/env bash
# Offline disposable rootfs only. Never invoke against a live/mounted tablet.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
root=$(realpath -e "${1:?disposable ARM64 rootfs directory}")
debs=$(realpath -e "${2:?locked repair archive directory}")
package=$(realpath -e "${3:?y700-platform deb}")
camera_debs=''
camera_lock=''
if [[ $# -gt 5 || ( -n ${5:-} && -z ${4:-} ) ]]; then
    echo 'Usage: integrate-rootfs.sh ROOT REPAIR_ARCHIVES PLATFORM_DEB [CAMERA_ARCHIVES [CAMERA_LOCK]]' >&2
    exit 2
fi
if [[ -n ${4:-} ]]; then
    camera_debs=$(realpath -e "$4")
    camera_lock=$(realpath -e "${5:-$repo/config/camera-layer.lock.json}")
fi
test "$(id -u)" -eq 0
# Keep build-only proc/sys mounts private to this process and its children.
if [[ ${Y700_PRIVATE_MOUNTS:-0} != 1 ]]; then
    exec unshare --mount --propagation private env Y700_PRIVATE_MOUNTS=1 bash "$0" "$@"
fi
test "$root" != /
test -f "$root/.y700-disposable-build-root"
test ! -L "$root/.y700-disposable-build-root"
test ! -d "$root/run/systemd/system"
test "$(chroot "$root" dpkg --print-architecture)" = arm64
test ! -e "$root/usr/sbin/policy-rc.d"
uv_python=("${UV_BIN:-uv}" run --python "${UV_PYTHON:-3.13}" --no-project python)
"${uv_python[@]}" "$repo/scripts/repair-inputs.py" verify "$debs" "$repo/config/desktop-repair.lock.json"
if [[ -n $camera_debs ]]; then
    "${uv_python[@]}" "$repo/scripts/repair-inputs.py" verify "$camera_debs" "$camera_lock" --camera-layer
elif [[ -e $root/var/lib/y700/build/camera-layer.lock.json ||
        -L $root/var/lib/y700/build/camera-layer.lock.json ]]; then
    echo 'The supplied root already has a camera layer. Use a separate base for a camera-free build.' >&2
    exit 1
fi
# Work entirely in this disposable directory. Service starts are prohibited.
stage=''
cleanup() {
    rm -f -- "$root/usr/sbin/policy-rc.d"
    [[ -z "$stage" ]] || rm -rf -- "$stage"
    umount "$root/sys" 2>/dev/null || true
    umount "$root/proc" 2>/dev/null || true
}
trap cleanup EXIT
mount -t proc proc "$root/proc"
mount --bind /sys "$root/sys"
mount -o remount,bind,ro "$root/sys"
printf '#!/bin/sh\nexit 101\n' > "$root/usr/sbin/policy-rc.d"
chmod 755 "$root/usr/sbin/policy-rc.d"
test -d "$root/tmp" && test ! -L "$root/tmp"
stage=$(mktemp -d "$root/tmp/y700-packages.XXXXXXXX")
cp "$debs/"*.deb "$stage/"
mkdir "$stage/platform"
cp -- "$package" "$stage/platform/"
"${uv_python[@]}" "$repo/scripts/repair-inputs.py" verify "$stage/platform" "$repo/config/platform.lock.json"
# Install only this verified invocation's archives, never old cache leftovers.
archives=()
for archive in "$stage/"*.deb "$stage/platform/"*.deb; do archives+=("${archive#"$root"}"); done
if [[ -n $camera_debs ]]; then
    mkdir "$stage/camera"
    cp "$camera_debs/"*.deb "$stage/camera/"
    cp "$camera_lock" "$stage/camera-layer.lock.json"
    "${uv_python[@]}" "$repo/scripts/repair-inputs.py" verify "$stage/camera" "$stage/camera-layer.lock.json" --camera-layer
    for archive in "$stage/camera/"*.deb; do archives+=("${archive#"$root"}"); done
fi
chroot "$root" env DEBIAN_FRONTEND=noninteractive dpkg -i "${archives[@]}"
chroot "$root" apt-get check
audit=$(chroot "$root" dpkg --audit)
test -z "$audit" || { printf '%s\n' "$audit"; exit 1; }
# Dedicated daemon has explicit listener/authentication rules; prevent distro
# socket activation or inherited USB services from opening another listener.
for unit in ssh.service ssh.socket asphalt-usb-status.service asphalt-usb-maintenance.service; do
    systemctl --root="$root" disable "$unit" 2>/dev/null || true
    # --force is limited to service symlinks in this explicitly disposable tree.
    ln -sfn /dev/null "$root/etc/systemd/system/$unit"
done
systemctl --root="$root" enable y700-usb-maintenance.service y700-maintenance-sshd.service systemd-timesyncd.service
systemctl --root="$root" enable y700-bluetooth-identity.service
systemctl --root="$root" enable y700-speaker-calibration.service
# Seed early boot time from the deterministic build epoch; network NTP still
# performs the actual synchronization. Never move an existing newer seed back.
epoch=$(cat "$root/usr/lib/y700/build-epoch")
[[ "$epoch" =~ ^[0-9]+$ ]]
clock="$root/var/lib/systemd/timesync/clock"
install -d -m755 "${clock%/*}"
if [[ ! -e "$clock" ]] || (( $(stat -c %Y "$clock") < epoch )); then
    touch -d "@$epoch" "$clock"
fi
# An inherited home overrides system-wide Xfce defaults. Require safe existing
# profile before handing a candidate to a display manager.
while IFS= read -r -d '' file; do
    sed -i 's/name="use_compositing" type="bool" value="true"/name="use_compositing" type="bool" value="false"/g' "$file"
done < <(find "$root/home" -path '*/xfce-perchannel-xml/xfwm4.xml' -type f -print0)
install -d "$root/var/lib/y700/build"
install -m644 "$repo/config/platform.lock.json" "$root/var/lib/y700/build/platform.lock.json"
chroot "$root" dpkg-query -W '-f=${binary:Package}\t${Version}\t${Architecture}\n' > "$root/var/lib/y700/build/packages.tsv"
cp "$repo/config/desktop-repair.lock.json" "$root/var/lib/y700/build/"
if [[ -n $camera_debs ]]; then
    install -m644 "$stage/camera-layer.lock.json" "$root/var/lib/y700/build/camera-layer.lock.json"
    "${uv_python[@]}" "$repo/scripts/verify-image-packages.py" "$root" --camera-lock "$stage/camera-layer.lock.json"
fi
echo 'Candidate integration complete; identity finalization and boot/hardware gates remain.'
