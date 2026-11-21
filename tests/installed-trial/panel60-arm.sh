#!/bin/bash
# Run the real one-boot menu transaction on a private copy of a dev12.11 test FAT.
set -euo pipefail
if [[ ${PANEL60_FAT_NS:-0} != 1 ]]; then
    exec unshare --mount --propagation private env PANEL60_FAT_NS=1 bash "$0" "$@"
fi
[[ $EUID == 0 && $# == 4 ]]
repo=$(realpath -e "$(dirname "$0")/../..")
base_fat=$(realpath -e "$1"); released=$(realpath -e "$2"); probe=$(realpath -e "$3")
work=$(realpath -m "$4"); [[ $work == /var/tmp/y700-panel60.*/* && ! -e $work ]]
mkdir -m700 "$work"; esp=$work/esp; store=$work/control; mkdir -m700 "$esp" "$store"
cp --sparse=always "$base_fat" "$work/menu.fat"
mount -o loop,nodev,nosuid,noexec "$work/menu.fat" "$esp"
trap 'umount "$esp"' EXIT
printf 'default y700-recovery-12-10.conf\ntimeout 3\n' > "$esp/loader/loader.conf"
bash "$repo/scripts/manage-file-trial-entry.sh" --dev12.11 add "$released" "$esp"
printf 'default y700-file-12-11.conf\ntimeout 3\n' > "$esp/loader/loader.conf"
source "$repo/scripts/arm-installed-trial.sh"
dt_probe_mode panel60
id=qapanel; state=$store/${trial_role}control-$id; entry_sha=$recovery_sha
running_edition=dev12.11; baseline=0
manage() { bash "$repo/scripts/manage-file-trial-entry.sh" --dev12.11-panel60 "$1" "$probe" "$esp"; }
refused() { if ("$@") >/dev/null 2>&1; then echo "unexpected success: $1 $2" >&2; exit 1; fi; }
inventory() (cd "$esp"; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
inventory > "$work/before"
manage add; manage add
[[ ! -e $esp/loader/entries/$entry ]]
for f in "$esp/EFI/$source_sub/"{kernel.efi,board.dtb,source.conf} "$esp/EFI/$baseline_sub/initrd"; do
    cp "$f" "$work/original"; printf x >>"$f"; refused menu arm; [[ ! -e $state ]]; cp "$work/original" "$f"
done
menu arm; menu arm
pending=$entries/$prefix-trial+1.conf; used=$entries/$prefix-trial+0-1.conf
grep -Fxq "initrd /EFI/$baseline_sub/initrd" "$pending"
grep -Fq 'systemd.wants=y700-installed-trial-deadline.timer systemd.mask=systemd-bless-boot.service' "$pending"
grep -Fq 'y700.panel_probe=60hz' "$pending"
refused manage remove; refused menu promote; refused menu check-confirm
cp -r "$esp/loader" "$work/armed-loader"
cp -r "$esp/EFI/$source_sub" "$work/armed-probe"
mv "$pending" "$used"; menu check-confirm
choice=$prefix-trial.conf
selected_entry() { echo "$choice"; }
qa_args="y700.media=file y700.release=dev12.11 y700.recovery=journal y700.panel_probe=60hz y700.installed_trial=$id"
current_cmdline() { echo "$qa_args"; }
current_trial
(qa_args=${qa_args/y700.panel_probe=60hz/y700.panel_probe=30hz}; refused current_trial token)
refused verify_dev1211_restore candidate
choice=$prefix-base.conf; verify_dev1211_restore
menu restore; menu restore
manage remove; manage remove
inventory | cmp - "$work/before"
echo PANEL60_FAT_PASS limited=1 restored=dev12.11 permanent_files_unchanged=1 promote_refused=1
