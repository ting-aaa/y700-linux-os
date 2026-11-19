#!/bin/bash
# Run on the device with the reviewed companion device script as the argument.
set -euo pipefail
src=${1:?device-side lab script}
[[ $(id -u) == 0 ]]
grep -azFxq 'lenovo,asphalt' /proc/device-tree/compatible
[[ ! -e /var/lib/y700-lab/active ]]
work=$(mktemp -d)
trap 'rm -f "$work"/*; rmdir "$work"' EXIT
cat > "$work/y700-lab-deadline.timer" <<'UNIT'
[Unit]
Description=Time limit for the current Y700 trial boot
DefaultDependencies=no
ConditionKernelCommandLine=y700.lab_trial
Conflicts=shutdown.target
Before=shutdown.target

[Timer]
OnBootSec=100s
AccuracySec=1s
UNIT
for action in deadline return; do
    condition=y700.lab_trial
    if [[ $action == return ]]; then condition=y700.lab_return; fi
    cat > "$work/y700-lab-$action.service" <<UNIT
[Unit]
Description=Y700 trial $action
ConditionKernelCommandLine=$condition
RequiresMountsFor=/boot /var/lib/y700-lab

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/y700-lab-device $action
UNIT
done
mkdir -p /usr/local/libexec
copy_owned() {
    local src=$1 dst=$2 mode=$3
    if [[ -e $dst ]]; then cmp "$src" "$dst"; return; fi
    install -m "$mode" "$src" "$dst"
}
copy_owned "$src" /usr/local/libexec/y700-lab-device 0755
for unit in "$work"/y700-lab-*; do copy_owned "$unit" "/etc/systemd/system/${unit##*/}" 0644; done
systemctl daemon-reload
systemd-analyze verify y700-lab-deadline.timer y700-lab-deadline.service y700-lab-return.service
