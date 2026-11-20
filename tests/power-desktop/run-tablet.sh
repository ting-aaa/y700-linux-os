#!/bin/bash
set -euo pipefail
[[ $# == 2 || ( $# == 3 && $3 == --stock-control ) ]] || { echo 'Usage: run-tablet.sh PINNED_USB_SSH DEVICE_XVFB_USR [--stock-control]' >&2; exit 2; }
primary=visible
[[ ${3:-} != --stock-control ]] || primary=absent
ssh=$(realpath -e "$1")
helper=$2
[[ $helper =~ ^/var/tmp/[A-Za-z0-9._/-]+/usr$ && $helper != */../* ]]
here=$(cd "$(dirname "$0")" && pwd)
stage=$(bash "$ssh" 'set -eu; grep -zFxq lenovo,asphalt /proc/device-tree/compatible; test "$(findmnt -nro FSTYPE -T /run)" = tmpfs; umask 077; mktemp -d /run/y700-power-ui.XXXXXXXX')
[[ $stage =~ ^/run/y700-power-ui\.[[:alnum:]]{8}$ ]]
trap 'bash "$ssh" "cd / && ! grep -Fq \"$stage/\" /proc/self/mountinfo && rm -r --one-file-system -- $stage" || exit 1' EXIT
tar -cf - -C "$here" tablet-session.sh session.sh board-readings.sh panel.xml -C "$here/../upower" tray.sh |
    bash "$ssh" "tar -C '$stage' -xf -"
bash "$ssh" bash -s -- "$stage" "$helper" "$primary" <<'BOARD'
set -euo pipefail
cd "$1"
snapshot() {
    cat /proc/sys/kernel/random/boot_id
    loginctl show-seat seat0 -p ActiveSession
    loginctl show-session "$(loginctl show-seat seat0 -p ActiveSession --value)" -p Active -p LockedHint
    systemctl show lightdm ssh bluetooth NetworkManager upower -p Id -p InvocationID
    cat /sys/class/backlight/ktz8866-backlight/brightness
}
snapshot >before
rc=0
timeout --kill-after=5s 140s unshare --mount --propagation private --pid --fork --kill-child --ipc --net \
    bash "$1/tablet-session.sh" "$1" "$2" "$3" || rc=$?
snapshot >after
cmp before after
echo 'POWER_UI owner_boot_seat_services_brightness=same'
exit "$rc"
BOARD
