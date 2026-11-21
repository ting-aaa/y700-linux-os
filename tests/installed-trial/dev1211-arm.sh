#!/bin/bash
# Exercise the installed-release controller on disposable ext4 and FAT files.
set -euo pipefail
if [[ ${Y700_MENU_NS:-0} != 1 ]]; then exec unshare --mount --propagation private env Y700_MENU_NS=1 bash "$0" "$@"; fi
[[ $# == 3 && $EUID == 0 ]] || { echo 'Usage: dev1211-arm.sh DEV1210_RECOVERY_FAT DEV1211_ENTRY NEW_WORK' >&2; exit 2; }
prior=$(realpath -e "$1"); candidate=$(realpath -e "$2"); work=$(realpath -m "$3")
[[ -f $prior && $work == /var/tmp/y700-recovery-menu.* && ! -e $work ]]
repo=$(realpath -e "$(dirname "$0")/../..")
source "$repo/scripts/arm-installed-trial.sh"
dev1211_mode
mkdir -m700 "$work"
esp=$work/esp; store=$work/store; scratch=$work/scratch
mkdir -m700 "$esp" "$store" "$scratch" "$work/root" "$store/$candidate_edition"
trap 'if mountpoint -q "$work/root"; then umount "$work/root"; fi; if mountpoint -q "$esp"; then umount "$esp"; fi' EXIT
refused() { if ("$@") >/dev/null 2>&1; then echo "Unexpected acceptance: $*" >&2; exit 1; fi; }
img=$store/$candidate_edition/root.ext4
truncate -s 32G "$img"; chmod 600 "$img"
mkfs.ext4 -q -F -U "$inner_uuid" -E nodiscard,lazy_itable_init=1,lazy_journal_init=1 "$img"
mount -o loop,nodev,nosuid "$img" "$work/root"
mkdir -p "$work/root"/{etc/systemd/system,etc/y700,var/lib/y700/build}
printf 'y700-prc-%s\n' "$inner_uuid" > "$work/root/etc/y700/image-id"
refused bash "$repo/scripts/arm-installed-trial.sh" --dev12.11 prepare-candidate "$work/root"
install -m644 "$repo/config/camera-autofocus.lock.json" "$work/root/var/lib/y700/build/$receipt"
bash "$repo/scripts/arm-installed-trial.sh" --dev12.11 prepare-candidate "$work/root"
bash "$repo/scripts/arm-installed-trial.sh" --dev12.11 prepare-candidate "$work/root"
umount "$work/root"
refused check_prepared_image
printf '%s personal files verified, USB identity retained\n' "$candidate_edition" > "$store/$candidate_edition/installed.ok"
chmod 600 "$store/$candidate_edition/installed.ok"
check_prepared_image
cp --sparse=always "$prior" "$work/menu.fat"
# The previous recovery fixture is 400 MiB. A fourth full payload needs room.
truncate -s 600M "$work/dev1211.fat"
mkfs.fat -F32 -i B6D4FA81 "$work/dev1211.fat" >/dev/null
mkdir "$work/original"
mcopy -s -i "$work/menu.fat" '::*' "$work/original"
mcopy -s -i "$work/dev1211.fat" "$work/original/"* ::/
mount -o loop,nodev,nosuid,noexec "$work/dev1211.fat" "$esp"
printf 'default %s\ntimeout 3\n' "$baseline_entry" > "$esp/loader/loader.conf"
inventory() (cd "$esp"; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
inventory > "$work/before.sha256"
manage() { bash "$repo/scripts/manage-file-trial-entry.sh" --dev12.11 "$1" "$candidate" "$esp"; }
manage add; manage add
baseline=0; entry_sha=$recovery_sha
efi_choice=$baseline_entry; running_edition=dev12.10; timer_state=inactive
base_args='y700.media=file y700.release=dev12.10 y700.recovery=journal'
qa_args=$base_args
boot_id=00000000-0000-4000-8000-000000000042
current_cmdline() { echo "$qa_args"; }
selected_entry() { echo "$efi_choice"; }
current_boot() { echo "$boot_id"; }
systemctl() {
    case "$1:$2:${*: -1}" in
        stop:*:"$timer") timer_state=inactive ;;
        is-active:*:ssh|is-active:*:lightdm) return 0 ;;
        is-active:*:"$timer") [[ $timer_state == active ]] ;;
        show:*:"$timer") echo "$timer_state" ;;
        show:*:"${timer%.timer}.service") echo inactive ;;
        list-jobs:*:*) : ;;
        *) return 1 ;;
    esac
}
busctl() { echo 'b false'; }
run() {
    id=$1; state=$store/${trial_role}control-$id
    running_edition=dev12.10; qa_args=$base_args; efi_choice=$baseline_entry
    check_recovery_origin
    menu arm; menu arm
    pending=$entries/$prefix-trial+1.conf; used=$entries/$prefix-trial+0-1.conf
    match "$state/armed.conf" "$conf"
    match "$state/fallback.conf" "$entries/$prefix-base.conf"
    refused manage remove
    if [[ $id == qafallback ]]; then
        cp -r "$esp/loader" "$work/armed-loader"
        cp -r "$esp/EFI/$source_sub" "$work/armed-dev1211"
    fi
    mv "$pending" "$used"
    menu check-confirm
}
id=qatamper; state=$store/${trial_role}control-$id
for f in kernel.efi board.dtb initrd; do
    file=$esp/EFI/$source_sub/$f
    cp "$file" "$work/clean"; printf X >>"$file"
    refused menu arm; [[ ! -e $state ]]
    cp "$work/clean" "$file"
done
run qafallback
efi_choice=$prefix-base.conf; verify_dev1211_restore
refused confirm_boot; refused menu promote
menu restore; menu restore
run qapromote
qa_args="y700.media=file y700.release=dev12.11 y700.recovery=journal y700.installed_trial=$id"
running_edition=dev12.11; efi_choice=$prefix-trial.conf; timer_state=active
refused menu promote
(efi_choice=$baseline_entry; refused confirm_boot)
(running_edition=dev12.10; refused confirm_boot)
confirm_boot; confirm_boot
[[ $timer_state == inactive ]]
(boot_id=00000000-0000-4000-8000-000000000043; refused menu promote)
menu promote; menu promote
grep -Fxq "default $entry" "$conf"
refused manage remove
efi_choice=$entry; verify_dev1211_restore
(efi_choice=$baseline_entry; refused verify_dev1211_restore)
menu restore; menu restore
grep -Fxq "default $baseline_entry" "$conf"
manage remove; manage remove
inventory | cmp - "$work/before.sha256"
echo 'DEV1211_TRANSACTION_PASS ext4_prepare=1 files_guarded=1 count_consumed=1 fallback_alias_restored=1 same_boot_promotion=1 original_menu_restored=1'
