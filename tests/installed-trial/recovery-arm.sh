#!/bin/bash
set -euo pipefail
[[ $# == 4 && $EUID == 0 ]] || { echo 'Usage: recovery-arm.sh RELEASE_ENTRY RECOVERY_ENTRY GENERIC_ESP NEW_WORK' >&2; exit 2; }
if [[ ${Y700_MENU_NS:-0} != 1 ]]; then exec unshare --mount --propagation private env Y700_MENU_NS=1 bash "$0" "$@"; fi
repo=$(realpath -e "$(dirname "$0")/../..")
stable=$(realpath -e "$1"); candidate=$(realpath -e "$2"); sealed=$(realpath -e "$3"); work=$(realpath -m "$4")
[[ $work == /var/tmp/y700-recovery-menu.* ]]
mkdir -m700 "$work"
source "$repo/scripts/arm-installed-trial.sh"
recovery_mode
id=qarecovery; entry_sha=$recovery_sha; baseline=0
esp=$work/esp; store=$work/outer-control; state=$store/recovery-control-$id
mkdir -m700 "$store" "$esp"
truncate -s 400M "$work/menu.fat"; mkfs.fat -F32 -i B6D4FA81 "$work/menu.fat" >/dev/null
mount -o loop,nodev,nosuid,noexec "$work/menu.fat" "$esp"
trap 'umount "$esp"' EXIT
for d in EFI/BOOT EFI/debian loader/entries; do mkdir -p "$esp/$d"; done
mcopy -i "$sealed" '::/EFI/BOOT/BOOTAA64.EFI' "$esp/EFI/BOOT/"
mcopy -i "$sealed" '::/EFI/debian/*' "$esp/EFI/debian/"
mcopy -i "$sealed" '::/loader/entries/debian.conf' "$esp/loader/entries/"
cp -r "$stable/EFI/." "$esp/EFI/"; cp -r "$stable/loader/." "$esp/loader/"
printf 'default y700-file-12-10.conf\ntimeout 3\n' > "$esp/loader/loader.conf"
bash "$repo/scripts/manage-file-trial-entry.sh" --dev12.10-recovery add "$candidate" "$esp"
efi_choice=$baseline_entry; cmdline='y700.media=file y700.release=dev12.10'
current_cmdline() { printf '%s\n' "$cmdline"; }
selected_entry() { printf '%s\n' "$efi_choice"; }
current_boot() { echo 00000000-0000-4000-8000-000000000037; }
qa_timer=active
systemctl() {
    case "$1:$2:${*: -1}" in
        stop:*:"$timer") qa_timer=inactive ;;
        is-active:*:ssh|is-active:*:lightdm) return 0 ;;
        is-active:*:"$timer") [[ $qa_timer == active ]];;
        show:*:"$timer") echo "$qa_timer";;
        show:*:"${timer%.timer}.service") echo inactive;;
        list-jobs:*:*) : ;;
        *) return 1;;
    esac
}
busctl() { echo 'b false'; }
refused() { if ("$@") >/dev/null 2>&1; then echo "Unexpected acceptance: $1" >&2; exit 1; fi; }
check_recovery_origin
(efi_choice=debian.conf; refused check_recovery_origin)
(cmdline+=' y700.installed_trial=wrong'; refused check_recovery_origin)
(cd "$esp"; sha256sum EFI/{BOOT/BOOTAA64.EFI,debian/{initrd,kernel.efi,board.dtb}} loader/entries/debian.conf) > "$work/original.sha256"
stable_entry=$esp/loader/entries/$baseline_entry; active_entry=$esp/loader/entries/$entry
for target in "$stable_entry" "$active_entry" "$esp/EFI/$source_sub/initrd" "$esp/EFI/$baseline_sub/kernel.efi"; do
    cp "$target" "$work/untouched"; printf x >>"$target"
    refused menu arm
    [[ ! -e $state ]]; cp "$work/untouched" "$target"
done
menu arm; menu arm
trial=$entries/$prefix-trial+1.conf; consumed=$entries/$prefix-trial+0-1.conf
match "$state/armed.conf" "$conf"; match "$state/fallback.conf" "$entries/$prefix-base.conf"
grep -Fqx "linux /EFI/$baseline_sub/kernel.efi" "$entries/$prefix-base.conf"
refused menu check-confirm
# Keep an exact copy of the armed tree for the separate U-Boot boot-count measurement.
cp -r "$esp/loader" "$work/armed-loader"
mv "$trial" "$consumed"
menu check-confirm
cmdline+=' y700.recovery=journal y700.installed_trial=qarecovery'
efi_choice=$prefix-trial.conf
(efi_choice=$baseline_entry; refused current_trial)
(cmdline='y700.installed_trial=qarecovery'; refused current_trial)
(cmdline='y700.recovery=journal y700.installed_trial=other'; refused current_trial)
(cmdline+=' y700.installed_trial=other'; refused current_trial)
(cmdline='y700.recovery=journal-other y700.installed_trial=qarecovery'; refused current_trial)
refused menu promote
confirm_boot
menu promote; menu promote
grep -Fxq "default $entry" "$conf"
menu restore; menu restore
grep -Fxq "default $baseline_entry" "$conf"
refused menu arm
(cd "$esp"; sha256sum --strict -c "$work/original.sha256")
timer_unit | grep -Fx 'OnBootSec=4min'
echo 'RECOVERY_TRANSACTION_PASS actual_FAT=1 counter_model=1 effective_deadline=240 same_boot=1 restored_previous_default=1 original_debian_preserved=1'
