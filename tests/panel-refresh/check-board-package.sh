#!/bin/bash
# Exercise a DrvFS-style 0777 input tree on a native Linux filesystem.
set -euo pipefail
umask 077
[[ $# == 1 ]]
here=$(realpath -e "$(dirname "$0")")
entry=$(realpath -e "$1")
work=$(mktemp -d /tmp/y700-panel-perms.XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
cd "$work"
cp -R "$entry" wide
chmod -R 0777 wide
bash "$here/package-board.sh" "$entry" "$work/original.tar"
bash "$here/package-board.sh" wide "$work/wide.tar"
cmp original.tar wide.tar
# The root extraction defaults mirror a device operator unpacking as root.
mkdir -m700 unpacked
tar xf wide.tar -C unpacked
[[ $(stat -c %a unpacked) == 700 ]]
tar --numeric-owner -tvf wide.tar | awk '
    $2 != "0/0" || $NF ~ /^\.\// {exit 1}
    /^d/ {if ($1 != "drwx------") exit 1; d++; next}
    /^-/ {want = ($NF ~ /\.sh$/) ? "-rwx------" : "-rw-------"; if ($1 != want) exit 1; f++; next}
    {exit 1}
    END {if (d != 5 || f != 8) exit 1}'
[[ -z $(find unpacked -perm /077) ]]
(cd unpacked; sha256sum --strict -c SHA256SUMS; cd entry; sha256sum --strict -c SHA256SUMS)
printf x >>wide/SHA256SUMS
if bash "$here/package-board.sh" wide "$work/bad.tar" >/dev/null 2>&1; then exit 1; fi
[[ ! -e bad.tar ]]
echo 'PANEL_BOARD_PACKAGE_PASS private_root=1 owner=0:0 dirs=0700 scripts=0700 data=0600 reproducible=1 modified_manifest_refused=1'
