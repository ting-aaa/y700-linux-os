#!/bin/bash
# Stage and arm, or restore and remove, only the counted panel probe.
set -euo pipefail
[[ $EUID == 0 && $# == 3 && ( $1 == arm || $1 == restore ) &&
   $3 =~ ^[a-z0-9][a-z0-9-]{0,23}$ ]]
if [[ $(readlink /proc/self/ns/mnt) == "$(readlink /proc/1/ns/mnt)" || $(findmnt -nro PROPAGATION -T /) != private ]]; then
    exec unshare --mount --propagation private bash "$0" "$@"
fi
action=$1; source_dir=$(realpath -e "$2"); run_id=$3
here=$(cd "$(dirname "$0")" && pwd)
scripts=$here
[[ -f $scripts/arm-installed-trial.sh ]] || scripts=$(realpath -e "$here/../../scripts")
source "$scripts/arm-installed-trial.sh"
dt_probe_mode panel60; id=$run_id; verify_board; locate_boot
[[ $running_edition == dev12.11 ]]
verify_running_kernel "$action"
if [[ $action == arm ]]; then check_recovery_origin; else
    bash "$scripts/arm-installed-trial.sh" --panel60 restore "$run_id"
fi
dev=$(realpath -e /dev/disk/by-partlabel/linux-boot)
[[ $(blkid -s UUID -o value "$dev") == B6D4-FA81 && -z $(findmnt -nro TARGET -S "$dev") ]]
mnt=$(mktemp -d /run/y700-panel60-esp.XXXXXXXX)
cleanup() { if mountpoint -q "$mnt"; then umount "$mnt"; fi; rmdir "$mnt"; }
trap cleanup EXIT
mount -t vfat -o rw,nodev,nosuid,noexec,umask=0077 "$dev" "$mnt"
operation=add; if [[ $action == restore ]]; then operation=remove; fi
bash "$scripts/manage-file-trial-entry.sh" --dev12.11-panel60 "$operation" "$source_dir" "$mnt"
cleanup; trap - EXIT
if [[ $action == arm ]]; then
    bash "$scripts/arm-installed-trial.sh" --panel60 arm "$run_id"
fi
