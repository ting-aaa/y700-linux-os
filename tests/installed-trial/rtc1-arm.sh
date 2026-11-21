#!/bin/bash
# Continue from the private FAT fixture produced by recovery-arm.sh.
set -euo pipefail
[[ $# == 3 && $EUID == 0 ]] || { echo 'Usage: rtc1-arm.sh RECOVERY_MENU_QA_DIR RTC1_ENTRY NEW_WORK' >&2; exit 2; }
if [[ ${Y700_MENU_NS:-0} != 1 ]]; then exec unshare --mount --propagation private env Y700_MENU_NS=1 bash "$0" "$@"; fi
repo=$(realpath -e "$(dirname "$0")/../..")
previous=$(realpath -e "$1"); candidate=$(realpath -e "$2"); work=$(realpath -m "$3")
[[ $work == /var/tmp/y700-recovery-menu.* && $previous == /var/tmp/y700-recovery-menu.* ]]
mkdir -m700 "$work"
source "$repo/scripts/arm-installed-trial.sh"
rtc1_mode
id=qartc; entry_sha=$recovery_sha; baseline=0
esp=$work/esp; store=$work/outer-control; state=$store/rtc1-control-$id
mkdir -m700 "$store" "$esp"
cp --sparse=always "$previous/menu.fat" "$work/menu.fat"
mount -o loop,nodev,nosuid,noexec "$work/menu.fat" "$esp"
trap 'umount "$esp"' EXIT
conf=$esp/loader/loader.conf
printf 'default y700-recovery-12-10.conf\ntimeout 3\n' > "$conf"
manage() { bash "$repo/scripts/manage-file-trial-entry.sh" --dev12.10-rtc1 "$1" "$candidate" "$esp"; }
refused() { if ("$@") >/dev/null 2>&1; then echo "unexpected acceptance ($1)" >&2; exit 1; fi; }
(cd "$esp"; sha256sum EFI/{BOOT/BOOTAA64.EFI,{debian,y700-{file,recovery}-12-10}/{initrd,board.dtb,kernel.efi}} loader/{loader.conf,entries/{debian,y700-{file,recovery}-12-10}.conf}) >"$work/prior.sha256"
manage add
manage add
[[ ! -e $esp/loader/entries/$entry ]]
test "$(find "$esp/EFI/$source_sub" -mindepth 1 -maxdepth 1 | wc -l)" == 2
for file in "$esp/EFI/$source_sub/board.dtb" "$esp/EFI/$source_sub/source.conf" "$esp/EFI/$baseline_sub/initrd"; do
    cp "$file" "$work/before"; printf X >>"$file"
    refused menu arm
    [[ ! -e $state ]]; cp "$work/before" "$file"
done
efi_choice=$baseline_entry; qa_args='y700.media=file y700.release=dev12.10 y700.recovery=journal'
current_cmdline() { printf '%s\n' "$qa_args"; }
selected_entry() { printf '%s\n' "$efi_choice"; }
current_boot() { echo 00000000-0000-4000-8000-000000000038; }
verify_rtc1_tree() { [[ $tree == rtc1 ]] || die 'model tree mismatch'; }
tree=rtc1; qa_timer=active
systemctl() {
    case "$1:$2:${*: -1}" in
        stop:*) die 'RTC trial tried to disarm timer';;
        is-active:*:ssh|is-active:*:lightdm) return 0 ;;
        is-active:*:"$timer") [[ $qa_timer == active ]];;
        show:*:"$timer") echo "$qa_timer";;
        show:*:"${timer%.timer}.service") echo inactive;;
        list-jobs:*:*) : ;;
        *) return 1;;
    esac
}
busctl() { echo 'b false'; }
check_recovery_origin
(efi_choice=y700-file-12-10.conf; refused check_recovery_origin)
(qa_args='y700.media=file y700.release=dev12.10'; refused check_recovery_origin)
(qa_args+=' y700.rtc_probe=rtc1'; refused check_recovery_origin)
menu arm; menu arm
trial=$entries/$prefix-trial+1.conf; consumed=$entries/$prefix-trial+0-1.conf
grep -Fxq "devicetree /EFI/$source_sub/board.dtb" "$trial"
for opt in 'linux kernel.efi' 'initrd initrd'; do read -r key file <<<"$opt"; grep -Fxq "$key /EFI/$baseline_sub/$file" "$trial"; done
grep -Fxq "devicetree /EFI/$baseline_sub/board.dtb" "$entries/$prefix-base.conf"
refused menu promote
refused menu check-confirm
refused manage remove
cp -r "$esp/loader" "$work/armed-loader"
mv "$trial" "$consumed"
menu check-confirm
efi_choice=$prefix-trial.conf
parent_args=$qa_args
qa_args+=' y700.rtc_probe=rtc1 y700.installed_trial=qartc'
(efi_choice=$baseline_entry; refused current_trial)
(qa_args="$parent_args y700.installed_trial=qartc"; refused current_trial)
(tree=other; refused current_trial)
confirm_boot; confirm_boot
[[ $qa_timer == active ]]
refused menu promote
menu restore; menu restore
grep -Fxq 'default y700-recovery-12-10.conf' "$conf"
manage remove; manage remove
(cd "$esp"; sha256sum --quiet --strict -c "$work/prior.sha256")
echo 'RTC1_TRANSACTION_PASS staged_files=2 no_uncounted_entry=1 counted_attempt=1 wrong_selection_refused=1 timer_retained=1 promote_refused=1 retained_files_exact=1'
