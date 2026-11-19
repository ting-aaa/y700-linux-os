#!/bin/bash
# Run in a private local WSL terminal while the device's own Windows dialog is open.
# This only compares the independently displayed Windows value at the tablet.
set -euo pipefail
wrapper=${1:?expected the host-key-checked USB SSH wrapper}
read -r -s -p 'Six digits displayed by Windows: ' windows_code </dev/tty
echo >&2
[[ $windows_code =~ ^[0-9]{6}$ ]] || exit 2
# Only stdin carries the transient value. Neither the remote command line nor
# the transcript contains it. Refuse an ambiguous or inactive comparison.
printf '%s\n' "$windows_code" | bash "$wrapper" 'set -eu
set -- /run/y700-pair-*/linux-code
[ "$#" = 1 ] && [ -f "$1" ] || exit 3
run=${1%/*}
[ "$(stat -c %u:%a "$run")" = 0:700 ] && [ "$(stat -c %u:%a "$1")" = 0:600 ] || exit 4
umask 077
tmp=$(mktemp "$run/relay.XXXXXXXX")
trap '\''rm -f -- "$tmp"'\'' EXIT
cat > "$tmp"
exec 9<"$run"
flock -x 9
[ -f "$1" ] && [ ! -e "$run/windows-code" ] || exit 5
if cmp -s "$1" "$tmp"; then match=yes; else match=no; fi
mv -T -- "$tmp" "$run/windows-code"
if [ "$match" = yes ]; then echo MATCH; else echo MISMATCH; exit 1; fi'
