#!/usr/bin/env bash
# Offline disposable rootfs only. Never invoke against a live/mounted tablet.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
root=$(realpath -e "${1:?disposable ARM64 rootfs directory}")
debs=$(realpath -e "${2:?locked repair archive directory}")
package=$(realpath -e "${3:?y700-platform deb}")
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
"${UV_BIN:-uv}" run --python "${UV_PYTHON:-3.13}" --no-project python "$repo/scripts/repair-inputs.py" verify "$debs" "$repo/config/desktop-repair.lock.json"
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
cp "$debs/"*.deb "$package" "$stage/"
# Install only this verified invocation's archives, never old cache leftovers.
archives=()
for archive in "$stage/"*.deb; do archives+=("${archive#"$root"}"); done
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
chroot "$root" dpkg-query -W '-f=${binary:Package}\t${Version}\t${Architecture}\n' > "$root/var/lib/y700/build/packages.tsv"
cp "$repo/config/desktop-repair.lock.json" "$root/var/lib/y700/build/"
echo 'Candidate integration complete; identity finalization and boot/hardware gates remain.'
