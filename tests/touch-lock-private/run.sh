#!/bin/bash
# Verify an extracted lock candidate against private display/PAM on a running tablet.
set -euo pipefail
if (( $# != 3 && $# != 5 )) || [[ $# == 5 && $4 != --rotation-package ]]; then
    echo 'Usage: run.sh PINNED_USB_SSH ARCHIVE_DIRECTORY DEVICE_XVFB_USR [--rotation-package PLATFORM.deb]' >&2
    exit 2
fi
ssh=$(realpath -e "$1")
archives=$(realpath -e "$2")
helper=$3
[[ $helper =~ ^/var/tmp/[A-Za-z0-9._/-]+/usr$ ]]
here=$(cd "$(dirname "$0")" && pwd)
local_stage=$(mktemp -d)
remote=
cleanup() {
    if [[ $remote =~ ^/run/y700-private-lock\.[[:alnum:]]{8}$ ]]; then
        bash "$ssh" "cd / && test ! -e '$remote/root/etc/y700-private-lock-fixture' && rm -rf --one-file-system -- '$remote'"
    fi
    rm -rf -- "$local_stage"
}
trap cleanup EXIT
bash "$here/stage.sh" "$archives" "$local_stage" "${@:4}"
cd "$local_stage"
remote=$(bash "$ssh" 'set -eu; umask 077; test "$(findmnt -nro FSTYPE -T /run)" = tmpfs; mktemp -d /run/y700-private-lock.XXXXXXXX')
[[ $remote =~ ^/run/y700-private-lock\.[[:alnum:]]{8}$ ]]
inputs=(*.deb namespace.sh session.sh exercise.py SHA256SUMS)
if [[ -d rotation ]]; then inputs+=(rotation retry-in-place); fi
tar -cf - -- "${inputs[@]}" | bash "$ssh" "umask 077; tar -xf - -C '$remote'"
bash "$ssh" bash -s -- "$remote" "$helper" <<'DEVICE'
set -euo pipefail
cd "$1"
sha256sum --strict -c SHA256SUMS
mkdir root
for ns in pid mnt net ipc; do readlink "/proc/self/ns/$ns" > "host-$ns"; done
snapshot() {
    local active
    active=$(loginctl show-seat seat0 -p ActiveSession --value)
    [[ -n $active ]]
    printf 'boot=%s seat=%s\n' "$(cat /proc/sys/kernel/random/boot_id)" "$active"
    loginctl show-session "$active" -p Active -p LockedHint
    systemctl show lightdm.service ssh.service NetworkManager.service bluetooth.service -p Id -p InvocationID
    for pkg in libxss1 xfce4-screensaver y700-touch-lock libdbus-glib-1-2 y700-platform; do
        dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev} ${Version}\n' "$pkg" 2>/dev/null || true
    done
}
snapshot >before
rc=0
PRIVATE_LOCK_UV=$(command -v uv) timeout --kill-after=3s 85s unshare --mount --pid --fork --kill-child --ipc --net --propagation private \
    bash "$1/namespace.sh" "$1" / "$2" || rc=$?
snapshot >after
cmp before after
test ! -e "$1/root/etc/y700-private-lock-fixture"
if grep -Fq "$1/" /proc/self/mountinfo; then exit 1; fi
cat after
echo 'PRIVATE_LOCK host_boot_seat_hint_services_packages=same mount_leaks=0'
exit "$rc"
DEVICE
