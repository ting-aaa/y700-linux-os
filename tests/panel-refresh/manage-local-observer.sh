#!/bin/bash
# Install an observer only for the named future panel trial, or remove its exact unit.
set -euo pipefail
umask 077
[[ $EUID == 0 && $# == 2 && ( $1 == install || $1 == remove ) && $2 =~ ^[a-z0-9][a-z0-9-]{0,23}$ ]]
action=$1; id=$2
base=/var/tmp/y700-panel60-run-a
here=$(cd "$(dirname "$0")" && pwd)
unit=y700-panel-observe-$id.service
dst=/etc/systemd/system/$unit
program=$base/local-observer-$id.sh
[[ $(findmnt -nro UUID -M /) == c0e447e4-82db-59ee-91d6-0e1ec9d5f45e &&
   $(realpath -e "$base") == "$base" && $(stat -c %u "$base") == 0 &&
   -z $(find "$base" -maxdepth 0 -perm /022) ]]
scratch=$(mktemp -d); trap 'rm -f "$scratch/$unit"; rmdir "$scratch"' EXIT
cat >"$scratch/$unit" <<EOF
[Unit]
Description=Observe one Y700 panel trial locally
After=local-fs.target systemd-logind.service
ConditionKernelCommandLine=y700.installed_trial=$id
ConditionKernelCommandLine=y700.panel_probe=60hz

[Service]
Type=exec
ExecStart=/bin/bash $program $id
RuntimeMaxSec=160s
TimeoutStopSec=8s
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=$base
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
matches() { [[ -f $1 && ! -L $1 && $(stat -c %u "$1") == 0 ]] && cmp -s -- "$1" "$2"; }
for file in "$dst" "$program"; do
    [[ ! -L $file ]]
    if [[ -e $file ]]; then
        if [[ $file == "$dst" ]]; then matches "$dst" "$scratch/$unit"; else matches "$program" "$here/local-observer.sh"; fi
    fi
done
if [[ $action == install ]]; then
    [[ $(sha256sum /sys/kernel/notes | cut -d' ' -f1) == 35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6 ]]
    ! grep -Fq 'y700.installed_trial=' /proc/cmdline || exit 1
    (cd "$base"; sha256sum -c --strict <<'HASHES'
3aeabafe22c33d9811dbddbd586b5bde7367ff2c04e0b1a979bc04b71ed9b481  board-scanout.sh
042955b2afc3709b00236c2addfc201e242be4eb3881a4204d19479db3623a81  dpu-vblank
HASHES
    )
    if [[ ! -e $program ]]; then install -m700 "$here/local-observer.sh" "$program"; fi
    if [[ ! -e $dst ]]; then install -m644 "$scratch/$unit" "$dst"; fi
    systemd-analyze verify "$dst"
    systemctl daemon-reload
    systemctl enable "$unit"
    [[ $(systemctl is-enabled "$unit") == enabled && $(systemctl show -p ActiveState --value "$unit") == inactive ]]
else
    [[ $(systemctl show -p ActiveState --value "$unit") != active ]]
    if [[ -e $dst ]]; then systemctl disable "$unit"; rm -- "$dst"; fi
    if [[ -e $program ]]; then rm -- "$program"; fi
    systemctl daemon-reload
fi
printf 'PANEL_LOCAL_UNIT action=%s id=%s\n' "$action" "$id"
