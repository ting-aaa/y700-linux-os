#!/usr/bin/env bash
# Arm the production return units on QEMU's dummy machine in the temporary QA initrd.
set -euo pipefail
[[ $# == 3 && $2 =~ ^(ack|deadline)$ && ! -e $3 ]]
src=$(realpath -e "$1"); mode=$2; out=$(realpath -m "$3")
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cd "$work"
# This offset is the end of the sealed dev12.13 receiver's first-stage archive.
tail -c +11842149 "$src" | cpio --quiet -i --to-stdout y700-af-acm-init > original
printf '%s  original\n' ffb1811ce476aa938030069a7fc5b423611e8f642bf10b73ecf9ec7f37fd3769 | sha256sum --strict --quiet -c -
awk -v mode="$mode" '
    /^unit=\/newroot\/etc\/systemd\/system\/y700-ram-af-acm.service$/ { attached=1 }
    attached && /^if printf .*grep -Fxq lenovo,asphalt; then$/ {
        print "if [ \"$compat\" = linux,dummy-virt ] && grep -qw y700.ram_af_virtual=1 /proc/cmdline; then"
        ++changed; next
    }
    /^for fs in dev proc sys run; do$/ && mode=="deadline" {
        print "d=/newroot/etc/systemd/system/y700-ram-af-return.timer.d"
        print "mkdir -m 0755 \"$d\" || exit 1"
        print "printf '\''[Timer]\\nOnActiveSec=\\nOnActiveSec=80s\\n'\'' >\"$d/vm-time.conf\" || exit 1"
    }
    { print }
    END { if (changed!=1) exit 1 }
' original > y700-af-acm-init
chmod 755 y700-af-acm-init
sh -n y700-af-acm-init
cp -- "$src" "$out"
printf 'y700-af-acm-init\n' | cpio --quiet -o -H newc --owner=0:0 >> "$out"
