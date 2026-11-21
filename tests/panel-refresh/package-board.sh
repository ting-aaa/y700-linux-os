#!/bin/bash
# Create the counted panel entry package with explicit Linux permissions.
set -euo pipefail
umask 077
[[ $# == 2 ]] || { echo 'Usage: package-board.sh PANEL_ENTRY NEW_TAR' >&2; exit 2; }
entry=$(realpath -e "$1")
output=$(realpath -ms "$2")
[[ ! -e $output && ! -L $output ]]
repo=$(realpath -e "$(dirname "$0")/../..")
work=$(mktemp -d /tmp/y700-panel-package.XXXXXXXX)
archive=$(mktemp "${output%/*}/.panel-board.XXXXXXXX")
trap 'rm -rf -- "$work"; rm -f -- "$archive"' EXIT
name=y700-panel60-12-11
cd "$work"
mkdir -p "entry/EFI/$name" entry/loader/entries
for file in "EFI/$name/kernel.efi" "EFI/$name/board.dtb" "loader/entries/$name.conf" SHA256SUMS; do
    install -m600 "$entry/$file" "entry/$file"
done
printf '%s  entry/SHA256SUMS\n' 1f208f3a5f4713a69987e62820d811d7886e801f7931ece5cfb4780cda7e4223 | sha256sum --strict -c -
(cd entry; sha256sum --strict -c SHA256SUMS)
install -m700 "$repo/scripts/arm-installed-trial.sh" "$repo/scripts/manage-file-trial-entry.sh" "$repo/tests/panel-refresh/board-entry.sh" .
sha256sum arm-installed-trial.sh manage-file-trial-entry.sh board-entry.sh entry/SHA256SUMS >SHA256SUMS
chmod 600 SHA256SUMS
# Only named members belong in the TAR. Including "." lets tar reset the receiving directory.
tar --format=ustar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    --mode='u+rwX,go-rwx' -cf "$archive" SHA256SUMS arm-installed-trial.sh board-entry.sh entry manage-file-trial-entry.sh
mv -nT -- "$archive" "$output"
[[ ! -e $archive ]]
sha256sum "$output"
