#!/bin/bash
# Run the installed desktop on the physical CPU with a private display and simulated backlight.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: run-ambient-tablet.sh PINNED_USB_SSH DEVICE_XVFB_USR' >&2; exit 2; }
ssh=$(realpath -e "$1")
helpers=$2
[[ $helpers =~ ^/var/tmp/[A-Za-z0-9._/-]+/usr$ && $helpers != */../* ]]
repo=$(cd "$(dirname "$0")/../.." && pwd)
stage=$(bash "$ssh" 'set -eu; grep -zFxq lenovo,asphalt /proc/device-tree/compatible; test "$(findmnt -nro FSTYPE -T /run)" = tmpfs; umask 077; mktemp -d /run/y700-ambient-ui.XXXXXXXX')
[[ $stage =~ ^/run/y700-ambient-ui\.[[:alnum:]]{8}$ ]]
trap 'bash "$ssh" "cd / && ! grep -Fq \"$stage/\" /proc/self/mountinfo && rm -r --one-file-system -- $stage"' EXIT
tar -C "$repo" -cf - tests/brightness/{ambient-namespace.sh,ambient-ui.py,probe.py} \
    tests/ambient-backlight/check.py tests/rotation-session.py | bash "$ssh" "tar -xf - -C '$stage'"
bash "$ssh" bash -s -- "$stage" "$helpers" <<'BOARD'
set -euo pipefail
cd "$1"
snapshot() {
    cat /proc/sys/kernel/random/boot_id
    loginctl show-seat seat0 -p ActiveSession
    systemctl show lightdm ssh bluetooth NetworkManager upower -p Id -p InvocationID
    cat /sys/class/backlight/ktz8866-backlight/brightness
    for p in /sys/class/remoteproc/remoteproc*; do
        if [[ $(cat "$p/name") == slpi ]]; then cat "$p/state"; fi
    done
}
snapshot >before
rc=0
timeout -k 5 130 unshare --mount --propagation private --pid --fork --kill-child --ipc --net \
    bash "$1/tests/brightness/ambient-namespace.sh" "$1" "$2" || rc=$?
snapshot >after
cmp before after
echo 'AMBIENT_UI owner_boot_seat_services_requested_backlight_slpi=same'
exit "$rc"
BOARD
