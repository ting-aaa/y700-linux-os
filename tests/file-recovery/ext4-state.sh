#!/bin/bash
# Use the released ext4 superblock; write only to a 4 KiB temporary copy.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: ext4-state.sh SEALED_ROOT' >&2; exit 2; }
source "$(dirname "$0")/../../src/boot/file-recovery-ext4"
uuid=171a4adb916b47639e6f722b4a99988f
hex() { od -An -v -tx1 -j "$2" -N "$3" -- "$1" | tr -d ' \n'; }
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
dd if="$1" of="$work/original" bs=4096 count=1 status=none
img=$work/probe
put() { printf '%b' "$2" | dd of="$img" bs=1 seek="$1" conv=notrunc status=none; }
reset() { cp "$work/original" "$img"; }
reject() { if ext4_state "$img" "$uuid" >/dev/null; then exit 1; fi; }
reset
[[ $(ext4_state "$img" "$uuid") == clean ]]
if ext4_state "$img" 00000000000000000000000000000000 >/dev/null; then exit 1; fi
put 1120 "$(printf '\\x%02x' "$((16#$(hex "$img" 1120 1) | 4))")"
[[ $(ext4_state "$img" "$uuid") == replay ]]
put 1082 '\003\000'; reject
reset; put 1082 '\000\000'; reject
reset; put 1248 '\000\000\000\000'; reject
reset; put 1252 '\001\000\000\000'; reject
reset; put 1232 '\001'; reject
reset; put 1256 '\001\000\000\000'
[[ $(ext4_state "$img" "$uuid") == replay ]]
reset; put 1126 '\001'
[[ $(ext4_state "$img" "$uuid") == replay ]]
truncate -s 1257 "$img"; reject
echo 'EXT4_STATE_PASS clean journal orphan_file orphan_chain error_state wrong_uuid external_journal short_read'
