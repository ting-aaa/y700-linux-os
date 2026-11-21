#!/bin/bash
# Record the read-only FAT32 BPB status and the two FAT[1] entries, plus fsck's complete diagnosis.
set -euo pipefail
export LC_ALL=C
image=$1
out=$2
[[ -f $image ]]
byte() { od -An --endian=little -j "$2" -N "$1" "-tu$1" "$image" | xargs; }
bps=$(byte 2 11)
reserved=$(byte 2 14)
copies=$(byte 1 16)
fatsecs=$(byte 4 36)
backup=$(byte 2 50)
[[ $(dd if="$image" bs=1 skip=82 count=8 status=none) == 'FAT32   ' && $copies == 2 && $backup -gt 0 && $backup -lt $reserved ]]
status=0
fsck.fat -vn "$image" >"$out.fsck" 2>&1 || status=$?
printf 'bpb65=0x%02x backup65=0x%02x fat1_entry1=0x%08x fat2_entry1=0x%08x fsck_status=%d\n' \
    "$(byte 1 65)" "$(byte 1 "$((backup*bps+65))")" \
    "$(byte 4 "$((reserved*bps+4))")" "$(byte 4 "$(((reserved+fatsecs)*bps+4))")" "$status" | tee "$out.state"
