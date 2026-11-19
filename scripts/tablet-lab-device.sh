#!/bin/bash
# Device side of a counted systemd-boot trial. Called as root over pinned USB SSH.
set -euo pipefail
umask 077
store=/var/lib/y700-lab
entries=/boot/loader/entries
conf=/boot/loader/loader.conf
mkdir -p "$store/runs"
exec 9>"$store/lock"
flock -w 15 9
boot=$(cat /proc/sys/kernel/random/boot_id)
notes=$(sha256sum /sys/kernel/notes | cut -d' ' -f1)
active=$(cat "$store/active" 2>/dev/null || true)
valid_id() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; }
if [[ -n $active ]]; then
    valid_id "$active"
    run="$store/runs/$active"
fi
event() {
    printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$boot" "$*" >> "$run/events"
}
install_conf() {
    local tmp
    tmp=$(mktemp /boot/loader/.lab-conf-XXXXXX)
    cat "$1" > "$tmp"
    sync -f "$tmp"
    mv -T "$tmp" "$conf"
    sync -f /boot
    cmp -s "$1" "$conf"
}
restore() {
    if cmp -s "$run/original.conf" "$conf"; then return; fi
    cmp -s "$run/armed.conf" "$conf" || { echo 'loader.conf changed externally' >&2; return 1; }
    install_conf "$run/original.conf"
}
reboot_trial() {
    event "$1"
    journalctl -k -b -o short-monotonic --no-pager > "$run/kernel-$boot.log"
    sync
    systemctl --no-block reboot
}
on_trial() { grep -Fqw "y700.lab_trial=$active" /proc/cmdline; }
baseline() { [[ $notes == "$(cat "$run/baseline-notes")" ]]; }
require_run() { [[ -n $active && $1 == "$active" ]]; }
check_graphics_journal() {
    local first
    first=$(journalctl -k -b -q --no-pager -o short-monotonic |
        awk '/hw recovery is not complete for ctl:|\[dpu error\]|vblank wait timed out|flip_done timed out|Timeout waiting for GMU OOB set GPU_SET|GX_BW_PERF_VOTE.*timed out|gpu fault|preemption timed out/ && !seen {print; seen=1}')
    if [[ -n $first ]]; then
        printf 'Graphics fault on the current boot: %s\n' "$first" >&2
        return 1
    fi
}
case ${1:-} in
preflight)
    check_graphics_journal
    ;;
arm)
    # arm RUN_ID ENTRY_STEM CANDIDATE_IMAGE_SHA CANDIDATE_ELF_NOTES_SHA
    id=$2; entry=$3; image=$4; expected=$5
    attempts=${6:-2}
    [[ $attempts == 1 || $attempts == 2 ]]
    valid_id "$id"; valid_id "$entry"
    [[ $image =~ ^[a-f0-9]{64}$ && $expected =~ ^[a-f0-9]{64}$ && $notes != "$expected" ]]
    [[ -z $active && ! -e "$store/runs/$id" ]]
    grep -azFxq 'lenovo,asphalt' /proc/device-tree/compatible
    [[ $(findmnt -nro FSTYPE -T /boot) == vfat ]]
    [[ $(findmnt -nro SOURCE -T /boot) == "$(readlink -f /dev/disk/by-partlabel/linux-boot)" ]]
    [[ $(findmnt -nro SOURCE -T /) == "$(readlink -f /dev/disk/by-partlabel/linux)" ]]
    grep -qx 'default debian.conf' "$conf"
    [[ $(grep -c '^default ' "$conf") == 1 ]]
    ! compgen -G '/sys/firmware/efi/efivars/LoaderEntryDefault-*' >/dev/null || exit 1
    ! compgen -G '/sys/firmware/efi/efivars/LoaderEntryOneShot-*' >/dev/null || exit 1
    ! compgen -G "$entries/y700-lab-*" >/dev/null || exit 1
    base="$entries/debian.conf"; candidate="$entries/$entry.conf"
    for key in linux options sort-key; do
        [[ $(grep -c "^$key " "$candidate") == 1 && $(grep -c "^$key " "$base") == 1 ]]
    done
    diff <(grep -E '^(options|initrd|devicetree) ' "$base") <(grep -E '^(options|initrd|devicetree) ' "$candidate")
    kernel=$(sed -n 's/^linux //p' "$candidate")
    [[ $kernel =~ ^/EFI/[[:alnum:]_-]+/kernel\.efi$ && $kernel != /EFI/debian/kernel.efi ]]
    echo "$image  /boot$kernel" | sha256sum -c -
    systemctl is-active --quiet ssh
    systemctl is-active --quiet lightdm
    check_graphics_journal
    systemctl cat y700-lab-deadline.timer y700-lab-deadline.service y700-lab-return.service >/dev/null
    run="$store/runs/$id"; mkdir "$run"
    cp "$conf" "$run/original.conf"
    sed 's/^default debian\.conf$/default y700-lab-*.conf/' "$conf" > "$run/armed.conf"
    printf '%s\n' "$notes" > "$run/baseline-notes"
    printf '%s\n' "$expected" > "$run/candidate-notes"
    sed -e 's/^sort-key .*/sort-key 00-y700/' \
        -e "/^options /s/$/ panic=15 oops=panic y700.lab_trial=$id systemd.wants=y700-lab-deadline.timer systemd.mask=systemd-bless-boot.service/" "$candidate" > "$run/trial.conf"
    sed -e 's/^sort-key .*/sort-key 99-y700/' \
        -e "/^options /s/$/ y700.lab_return=$id systemd.wants=y700-lab-return.service/" "$base" > "$run/base.conf"
    printf '%s\n' "$id" > "$store/active.new"; mv -T "$store/active.new" "$store/active"
    cp "$run/base.conf" "$entries/y700-lab-base.conf"
    cp "$run/trial.conf" "$entries/y700-lab-trial+$attempts.conf"
    cmp "$run/base.conf" "$entries/y700-lab-base.conf"
    cmp "$run/trial.conf" "$entries/y700-lab-trial+$attempts.conf"
    sync -f /boot
    install_conf "$run/armed.conf"
    event armed
    ;;
start)
    require_run "$2"; [[ $boot == "$3" ]]; baseline
    cmp -s "$conf" "$run/armed.conf"
    [[ -f "$entries/y700-lab-trial+2.conf" || -f "$entries/y700-lab-trial+1.conf" ]]
    reboot_trial start
    ;;
status)
    result=none
    if [[ -n $active ]]; then
        if on_trial; then result=trial
        elif baseline; then result=baseline
        else result=unknown; fi
    fi
    light=$(systemctl is-active lightdm || true)
    timer=$(systemctl is-active y700-lab-deadline.timer || true)
    fault=0
    if [[ $result == trial ]] && journalctl -k -b --no-pager -q -g 'GPU_SET.*tim(e|ed) ?out|Timeout waiting for GMU OOB set GPU_SET|GX_BW_PERF_VOTE.*timed out|gpu fault|hangcheck detected|preemption timed out' | grep . >/dev/null; then fault=1; fi
    printf '%s %s %s %s %s %s %s\n' "${active:-none}" "$boot" "$result" "$notes" "$light" "$timer" "$fault"
    ;;
retry|finish|deadline)
    [[ -n $active ]]; on_trial
    action=$1
    if [[ $action != deadline ]]; then require_run "$2"; [[ $boot == "$3" ]]; fi
    if [[ -f "$run/action-$boot" ]]; then systemctl --no-block reboot; exit 0; fi
    if [[ $action == deadline ]] && journalctl -k -b --no-pager -q -g 'GPU_SET.*tim(e|ed) ?out|Timeout waiting for GMU OOB set GPU_SET|GX_BW_PERF_VOTE.*timed out|gpu fault|hangcheck detected|preemption timed out' | grep . >/dev/null; then
        restore
    fi
    # Only permit another candidate after the firmware actually consumed one try.
    if [[ $action == finish || ! -f "$entries/y700-lab-trial+1-1.conf" || $notes != "$(cat "$run/candidate-notes")" ]]; then restore; fi
    touch "$run/action-$boot"
    reboot_trial "$action"
    ;;
return)
    [[ -n $active ]] && grep -Fqw "y700.lab_return=$active" /proc/cmdline
    baseline; restore; event fallback
    ;;
close)
    require_run "$2"; baseline; [[ $boot == "$3" ]]
    restore
    for file in "$entries"/y700-lab-trial*.conf "$entries/y700-lab-base.conf"; do
        [[ -e $file ]] || continue
        expected="$run/trial.conf"
        if [[ $file == "$entries/y700-lab-base.conf" ]]; then expected="$run/base.conf"; fi
        cmp -s "$file" "$expected" || exit 1
        rm -- "$file"
    done
    sync -f /boot
    event closed
    rm -- "$store/active"
    ;;
*) echo 'expected preflight, arm, start, status, retry, finish, deadline, return or close' >&2; exit 2;;
esac
