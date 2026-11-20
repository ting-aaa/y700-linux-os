#!/usr/bin/env bash
# Synthetic ranges exercise both endpoints, each table kind and incomplete logs.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/log" <<'LOG'
GICv3: using LPI property table @0x30000
GICv3: CPU0: using allocated LPI pending table @0x50000
GICv3: CPU1: using reserved LPI pending table @0x70000
kexec_file: nr_segments = 3
kexec_file: segment[0]: buf=x bufsz=x mem=0x20000 memsz=0x10000
kexec_file: segment[1]: buf=x bufsz=x mem=0x40000 memsz=0x10000
kexec_file: segment[2]: buf=x bufsz=x mem=0x80000 memsz=0x1000
LOG
check() { awk -v cpus=2 -f "$here/check-irq-placement.awk"; }
check < "$work/log" | grep -Fx 'RAM_QA_KEXEC_LAYOUT_OK segments=3 tables=3'
for mutation in 's/mem=0x20000/mem=0x20001/' 's/mem=0x40000/mem=0x4ffff/' \
    's/mem=0x80000/mem=0x7ffff/' '/CPU1:/d' '/property table/d' \
    '/segment\[0\]/d' 's/nr_segments = 3/nr_segments = 4/' 's/0x70000/0x50000/'; do
    sed "$mutation" "$work/log" > "$work/case"
    if check < "$work/case" > "$work/result"; then exit 1; fi
    grep -q '^RAM_QA_KEXEC_LAYOUT_REJECT ' "$work/result"
done
echo RAM_TRIAL_PLACEMENT_GUARD_PASS
