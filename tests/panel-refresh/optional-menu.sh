#!/bin/bash
# Exercise an optional permanent menu entry on a disposable copy of the real-format FAT.
set -euo pipefail
[[ $EUID == 0 && $# == 3 ]] || { echo 'Usage: optional-menu.sh BASELINE_FAT OPTION_DIR NEW_TEST_DIR' >&2; exit 2; }
if [[ $(readlink /proc/self/ns/mnt) == "$(readlink /proc/1/ns/mnt)" || $(findmnt -nro PROPAGATION -T /) != private ]]; then
    exec unshare --mount --propagation private bash "$0" "$@"
fi
manager=$(realpath -e "$(dirname "$0")/../../scripts/panel-refresh-option.sh")
fat=$(realpath -e "$1"); option=$(realpath -e "$2"); work=$(realpath -ms "$3")
umask 077
mkdir -m700 "$work"; cd "$work"; mkdir esp
cp --sparse=always "$fat" menu.fat
mount -o loop,nodev,nosuid,noexec menu.fat esp
trap 'umount esp' EXIT
menu=esp/loader/entries/y700-display-12-11.conf
[[ ! -e $menu && ! -e esp/EFI/y700-display-12-11.efi ]]
inventory() (cd esp; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
manage() { bash "$manager" "$1" "$option" esp; }
refuse_remove() { if manage remove >/dev/null 2>&1; then echo 'Removal unexpectedly succeeded' >&2; exit 1; fi; }
inventory > before
manage add; manage add
cmp "$menu" "$option/loader/entries/y700-display-12-11.conf"
active=esp/loader/entries/y700-installed-optional-qa.conf
touch "$active"; refuse_remove; rm -- "$active"
printf x >>"$menu"; refuse_remove
cp "$option/loader/entries/y700-display-12-11.conf" "$menu"
manage remove; manage remove
inventory | cmp - before
echo 'PANEL_OPTION_FAT_PASS added=2 idempotent=1 bad_bytes_refused=1 active_trial_refused=1 removed=2 original_hashes=identical'
