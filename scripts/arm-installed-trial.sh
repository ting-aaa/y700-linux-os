#!/usr/bin/env bash
# Stage one counted dev12.10 file-root boot, verify it, and choose the durable default.
set -euo pipefail
umask 077
export LC_ALL=C
outer_uuid=ef306764-2315-4235-8796-69e2c9b61946
inner_uuid=171a4adb-916b-4763-9e6f-722b4a99988f
entry=y700-file-12-10.conf
release_lock=39cd516bc47679ba3c7980dc3ed43a43c1bac80e40fba690c85d33d9794fd5eb
timer=y700-installed-trial-deadline.timer
die() { printf 'Installed trial: %s\n' "$*" >&2; exit 1; }
sha() { sha256sum -- "$1" | cut -c1-64; }
regular() { [[ -f $1 && ! -L $1 ]] || die "expected a regular file: $1"; }
match() { cmp -s -- "$1" "$2" || die "unexpected contents: $2"; }
release() {
    local lock=$1/var/lib/y700/build/video-player-update.lock.json
    regular "$lock"
    [[ $(sha "$lock") == "$release_lock" ]] || die 'candidate release receipt differs'
}
timer_unit() {
    cat <<'EOF'
[Unit]
Description=Return an unconfirmed Y700 installed trial to its original default
DefaultDependencies=no
ConditionKernelCommandLine=y700.installed_trial
Conflicts=shutdown.target
Before=shutdown.target

[Timer]
OnBootSec=4min
AccuracySec=1s
EOF
}
reboot_unit() {
    cat <<'EOF'
[Unit]
Description=Reboot an unconfirmed Y700 installed trial
ConditionKernelCommandLine=y700.installed_trial

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl --no-block reboot
EOF
}
prepare_candidate() {
    local root units src dst unit
    root=$(realpath -e "$1")
    [[ $root != / && $(findmnt -nro FSTYPE -M "$root") == ext4 &&
       $(findmnt -nro SOURCE -M "$root") =~ ^/dev/(loop[0-9]+|nbd[0-9]+)$ &&
       $(findmnt -nro UUID -M "$root") == "$inner_uuid" ]] || die 'expected separately mounted candidate image'
    release "$root"
    units=$root/etc/systemd/system
    [[ $(realpath -e "$units") == "$units" ]] || die 'unexpected candidate unit directory'
    for unit in "$timer" "${timer%.timer}.service"; do
        src=$scratch/$unit; dst=$units/$unit
        if [[ $unit == "$timer" ]]; then timer_unit > "$src"; else reboot_unit > "$src"; fi
        if [[ -e $dst || -L $dst ]]; then regular "$dst"; match "$src" "$dst"; continue; fi
        local staged
        staged=$(mktemp "$units/.installed-trial.XXXXXXXX")
        install -m644 -- "$src" "$staged"
        ln -T -- "$staged" "$dst"
        rm -- "$staged"
    done
    sync -f "$units"
    echo 'INSTALLED_TRIAL_PREPARED deadline_seconds=240'
}
check_prepared_image() {
    local dir=$store/dev12.10 img=$store/dev12.10/root.ext4 marker=$store/dev12.10/installed.ok
    [[ $(realpath -e "$dir") == "$dir" && $(stat -c '%u:%g:%a' "$dir") == 0:0:700 ]] || die 'unsafe image directory'
    regular "$marker"
    [[ $(stat -c '%u:%g:%a:%h' "$marker") == 0:0:600:1 ]] || die 'unsafe personalization receipt'
    match <(printf '%s\n' 'dev12.10 personal files verified, USB identity retained') "$marker"
    [[ $(realpath -e "$img") == "$img" && $(stat -c '%u:%g:%a:%h' "$img") == 0:0:600:1 &&
       $(stat -c %s "$img") == 34359738368 && $(blkid -p -s UUID -o value "$img") == "$inner_uuid" ]] ||
        die 'expected private 32 GiB candidate root'
    debugfs -R "cat /etc/systemd/system/$timer" "$img" 2>/dev/null | cmp - <(timer_unit) || die 'candidate timer differs'
    debugfs -R "cat /etc/systemd/system/${timer%.timer}.service" "$img" 2>/dev/null | cmp - <(reboot_unit) ||
        die 'candidate deadline service differs'
    [[ $(debugfs -R 'cat /var/lib/y700/build/video-player-update.lock.json' "$img" 2>/dev/null | sha256sum | cut -c1-64) == "$release_lock" ]] ||
        die 'staged image release identity differs'
}
verify_board() {
    grep -azFxq lenovo,asphalt /proc/device-tree/compatible &&
        [[ $(tr -d '\0' < /proc/device-tree/region_country) == PRC ]] || die 'expected TB320FC PRC'
    [[ $(uname -r) == 7.3.4-asphalt-prc ]] || die 'unexpected running kernel'
}
check_loop() {
    local target=$1 file=$2 loop
    loop=$(findmnt -nro SOURCE -M "$target")
    [[ $loop =~ ^/dev/loop[0-9]+$ && -f $file && ! -L $file &&
       $(stat -c '%u:%g:%a:%h' "$file") == 0:0:600:1 &&
       $(losetup --raw -nO BACK-INO "$loop") == "$(stat -c %i "$file")" &&
       $(losetup --raw -nO BACK-MAJ:MIN "$loop") == "$(findmnt -nro MAJ:MIN -M "$backing")" &&
       $(losetup --raw -nO OFFSET "$loop") == 0 ]] || die 'loop backing does not match the installed image'
}
locate_boot() {
    local ufs
    ufs=$(realpath -e /dev/disk/by-partlabel/linux)
    if [[ $(findmnt -nro SOURCE -M /) == "$ufs" ]]; then
        backing=/; baseline=1
    else
        backing=/run/initramfs/backing; baseline=0
        [[ $(findmnt -nro SOURCE -M "$backing") == "$ufs" ]] || die 'unexpected outer filesystem'
        [[ $(findmnt -nro UUID -M /) == "$inner_uuid" &&
           $(findmnt -nro UUID -M /boot) == 171A-4ADB ]] || die 'unexpected candidate volumes'
        grep -Fqw y700.release=dev12.10 /proc/cmdline && grep -Fqw y700.media=file /proc/cmdline ||
            die 'missing file-root release options'
        release ''
        check_loop / "$backing/var/lib/y700-trial/dev12.10/root.ext4"
        check_loop /boot "$backing/var/lib/y700-trial/dev12.10/linux-boot.fat"
    fi
    [[ $(findmnt -nro UUID -M "$backing") == "$outer_uuid" &&
       $(findmnt -nro FSTYPE -M "$backing") == ext4 ]] || die 'unexpected outer UFS identity'
    store=${backing%/}/var/lib/y700-trial
    [[ $(realpath -e "$store") == "$store" && $(stat -c '%u:%g:%a' "$store") == 0:0:700 ]] ||
        die 'unsafe control directory'
    state=$store/control-$id
}
check_efi_variables() {
    local vars=/sys/firmware/efi/efivars
    [[ $(findmnt -nro FSTYPE -M "$vars") == efivarfs ]] || die 'EFI variables unavailable for inspection'
    ! compgen -G "$vars/LoaderEntryDefault-*" >/dev/null &&
        ! compgen -G "$vars/LoaderEntryOneShot-*" >/dev/null || die 'EFI default overrides file selection'
}
payloads() {
    local conf=$1 sub=$2 key value
    for key in linux initrd devicetree; do
        value=$(awk -v k="$key" '$1==k {if(NF!=2)exit 1; print $2; n++} END{if(n!=1)exit 1}' "$conf") ||
            die 'invalid BLS payload declaration'
        [[ $value =~ ^/EFI/$sub/[a-zA-Z0-9_.-]+$ && ${value##*/} != . && ${value##*/} != .. ]] ||
            die 'unexpected BLS payload path'
        regular "$esp$value"
        (cd "$esp" && sha256sum -- "${value#/}")
    done
}
write_loader() {
    local previous=$1 desired=$2 tmp
    match "$previous" "$conf"
    tmp=$(mktemp "$esp/loader/.y700-installed.XXXXXXXX")
    cat "$desired" > "$tmp"; match "$desired" "$tmp"; sync -f "$tmp"
    match "$previous" "$conf"
    mv -T -- "$tmp" "$conf"; sync -f "$esp"; match "$desired" "$conf"
}
put_entry() {
    local src=$1 dst=$2 tmp
    if [[ -e $dst ]]; then match "$src" "$dst"; return; fi
    tmp=$(mktemp "$entries/.y700-installed.XXXXXXXX")
    cat "$src" > "$tmp"; match "$src" "$tmp"; sync -f "$tmp"
    mv -nT -- "$tmp" "$dst"; [[ ! -e $tmp ]] || die 'entry appeared during installation'
}
check_state() {
    [[ -d $state && ! -L $state && $(stat -c '%u:%g:%a' "$state") == 0:0:700 ]] || die 'unknown trial run'
    (cd "$state" && sha256sum --quiet --strict -c state.sha256) || die 'saved trial state changed'
    [[ $(sha "$state/source.conf") == "$entry_sha" ]] || die 'wrong candidate digest for this run'
}
initialize() {
    local new file
    [[ ! -e $state && ! -L $state ]] || die 'run state already exists'
    ! compgen -G "$entries/y700-installed-*.conf" >/dev/null || die 'another installed trial exists'
    [[ $(awk 'tolower($1)=="default" {print $2}' "$conf") == debian.conf &&
       $(grep -Fxc 'default debian.conf' "$conf") == 1 ]] || die 'original default is not debian.conf'
    new=$(mktemp -d "$store/.installed-control.XXXXXXXX")
    cp "$conf" "$new/original.conf"
    cp "$entries/debian.conf" "$new/baseline.conf"
    cp "$entries/$entry" "$new/source.conf"
    [[ $(sha "$new/source.conf") == "$entry_sha" ]] || die 'deployed candidate entry digest differs'
    grep -Eq '^options .*y700\.release=dev12\.10( |$)' "$new/source.conf" &&
        grep -Eq '^options .*y700\.media=file( |$)' "$new/source.conf" || die 'candidate release or media option missing'
    for file in baseline source; do
        [[ $(grep -c '^options ' "$new/$file.conf") == 1 && $(grep -c '^sort-key ' "$new/$file.conf") == 1 ]] ||
            die 'invalid baseline or candidate BLS entry'
    done
    payloads "$new/baseline.conf" debian > "$new/payload.sha256"
    payloads "$new/source.conf" y700-file-12-10 >> "$new/payload.sha256"
    (cd "$esp" && sha256sum EFI/BOOT/BOOTAA64.EFI) >> "$new/payload.sha256"
    sed "s|^default debian\.conf$|default $prefix-*.conf|" "$conf" > "$new/armed.conf"
    sed "s|^default debian\.conf$|default $entry|" "$conf" > "$new/promoted.conf"
    sed 's/^sort-key .*/sort-key 99-y700/' "$new/baseline.conf" > "$new/fallback.conf"
    sed -e 's/^sort-key .*/sort-key 00-y700/' \
        -e "/^options /s|$| y700.installed_trial=$id systemd.wants=$timer systemd.mask=systemd-bless-boot.service|" \
        "$new/source.conf" > "$new/trial.conf"
    (cd "$new" && sha256sum *.conf payload.sha256 > state.sha256)
    sync -f "$new"; mv -nT -- "$new" "$state"; [[ ! -e $new ]] || die 'run directory appeared concurrently'
    sync -f "$store"
}
menu() {
    local action=$1 file next previous
    entries=$esp/loader/entries; conf=$esp/loader/loader.conf; prefix=y700-installed-$id
    local pending=$entries/$prefix-trial+1.conf used=$entries/$prefix-trial+0-1.conf fallback=$entries/$prefix-base.conf
    if [[ $action == arm && ! -e $state ]]; then initialize; fi
    check_state
    match "$state/baseline.conf" "$entries/debian.conf"; match "$state/source.conf" "$entries/$entry"
    (cd "$esp" && sha256sum --quiet --strict -c "$state/payload.sha256") || die 'installed firmware payload changed'
    for file in "$entries"/y700-installed-*.conf; do
        [[ -e $file ]] || continue
        case "$file" in
            "$pending"|"$used") match "$state/trial.conf" "$file";;
            "$fallback") match "$state/fallback.conf" "$file";;
            *) die 'unrecognized installed-trial menu entry';;
        esac
    done
    [[ ! -e $pending || ! -e $used ]] || die 'inconsistent boot counter'
    if [[ $action == arm ]]; then
        [[ ! -e $used && ! -e $state/closed && ! -e $state/confirmed ]] || die 'trial already consumed or closed'
        if cmp -s "$state/armed.conf" "$conf"; then
            [[ -e $pending && -e $fallback ]] || die 'armed menu incomplete'
        else
            match "$state/original.conf" "$conf"
            put_entry "$state/fallback.conf" "$fallback"; put_entry "$state/trial.conf" "$pending"
            sync -f "$esp"; write_loader "$state/original.conf" "$state/armed.conf"
        fi
    else
        next=$state/original.conf
        if [[ $action == promote ]]; then
            promotable_boot
            [[ -e $used || -e $state/promoting ]] || die 'no consumed firmware boot count'
            [[ -e $fallback || -e $state/promoting ]] || die 'fallback entry missing'
            [[ ! -e $state/closed || $(cat "$state/closed") == promote ]] || die 'trial already restored'
            next=$state/promoted.conf
        fi
        if ! cmp -s "$next" "$conf"; then
            previous=$state/armed.conf
            if [[ $action == restore ]] && cmp -s "$state/promoted.conf" "$conf"; then previous=$state/promoted.conf; fi
            match "$previous" "$conf"
            if [[ $action == promote ]]; then touch "$state/promoting"; sync -f "$state"; fi
            if [[ $action == promote ]]; then promotable_boot; fi
            write_loader "$previous" "$next"
        fi
        for file in "$pending" "$used" "$fallback"; do
            if [[ -e $file ]]; then
                if [[ $file == "$fallback" ]]; then match "$state/fallback.conf" "$file"; else match "$state/trial.conf" "$file"; fi
                rm -- "$file"
            fi
        done
        sync -f "$esp"
        echo "$action" > "$state/closed"; sync -f "$state"
    fi
    printf 'INSTALLED_TRIAL_MENU action=%s default=%s\n' "$action" "$(awk '$1=="default"{print $2}' "$conf")"
}
valid_confirmation() {
    regular "$state/confirmed"
    grep -Exq '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' "$state/confirmed" || die 'missing confirmed candidate boot identity'
}
current_trial() {
    [[ $baseline == 0 ]] && grep -Fqw "y700.installed_trial=$id" /proc/cmdline || die 'wrong running trial'
}
current_boot() { cat /proc/sys/kernel/random/boot_id; }
no_reboot_pending() {
    local jobs preparing service_state
    [[ ! -e /run/systemd/shutdown/scheduled ]] || die 'system shutdown is scheduled'
    preparing=$(busctl --system --timeout=5 get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager PreparingForShutdown) || die 'cannot inspect logind shutdown state'
    [[ $preparing == 'b false' ]] || die 'logind is preparing to shut down'
    service_state=$(systemctl show -p ActiveState --value "${timer%.timer}.service") || die 'cannot inspect reboot service'
    [[ $service_state == inactive ]] || die 'deadline reboot service is already running'
    jobs=$(systemctl list-jobs --no-legend --plain --no-pager) || die 'cannot inspect queued system jobs'
    if awk '$3=="start" && ($2 ~ /^(shutdown|reboot|poweroff|halt|kexec|soft-reboot|final)\.target$/ ||
            $2 ~ /^systemd-(reboot|poweroff|halt|kexec|soft-reboot)\.service$/ ||
            $2=="y700-installed-trial-deadline.service") {found=1} END{exit !found}' <<< "$jobs"; then
        die 'a reboot or shutdown job is queued'
    fi
}
promotable_boot() {
    current_trial
    valid_confirmation
    match <(current_boot) "$state/confirmed"
    [[ $(systemctl show -p ActiveState --value "$timer") == inactive ]] || die 'deadline is not stopped'
    no_reboot_pending
}
main() {
    [[ $EUID == 0 ]] || die 'root required'
    if [[ $# == 3 && $1 =~ ^(promote|restore)$ && $(findmnt -nro SOURCE -M /) =~ ^/dev/loop[0-9]+$ ]] &&
       [[ $(readlink /proc/self/ns/mnt) == "$(readlink /proc/1/ns/mnt)" || $(findmnt -nro PROPAGATION -T /) != private ]]; then
        exec unshare --mount --propagation private bash "$(realpath -e "$0")" "$@"
    fi
    scratch=$(mktemp -d /run/y700-installed-trial.XXXXXXXX)
    cleanup_scratch() {
        exec 8<&-
        if mountpoint -q "$scratch/esp"; then umount "$scratch/esp" || return 1; fi
        if [[ -d $scratch/esp ]]; then rmdir "$scratch/esp"; fi
        rm -f -- "$scratch/$timer" "$scratch/${timer%.timer}.service"
        rmdir "$scratch"
    }
    trap cleanup_scratch EXIT
    if [[ $# == 2 && $1 == prepare-candidate ]]; then prepare_candidate "$2"; return; fi
    [[ $# == 3 && $1 =~ ^(arm|confirm|restore|promote)$ && $2 =~ ^[a-z0-9][a-z0-9-]{0,23}$ &&
       $3 =~ ^[0-9a-f]{64}$ ]] || die 'usage: prepare-candidate MOUNT | arm|confirm|restore|promote RUN_ID ENTRY_SHA256'
    local action=$1 boot device
    id=$2; entry_sha=$3
    verify_board; locate_boot
    exec 9<"$store"; flock -w 10 9 || die 'another trial change is active'
    if [[ $action == confirm ]]; then
        current_trial; no_reboot_pending
        check_state; [[ ! -e $state/closed ]] || die 'trial already closed'
        systemctl is-active --quiet ssh && systemctl is-active --quiet lightdm || die 'candidate desktop or USB SSH service unavailable'
        boot=$(current_boot)
        if [[ -e $state/confirmed ]]; then
            [[ $(cat "$state/confirmed") == "$boot" ]] || die 'another boot already confirmed'
        else
            systemctl is-active --quiet "$timer" || die 'deadline was not active'
            printf '%s\n' "$boot" > "$state/confirmation.new"; mv -T "$state/confirmation.new" "$state/confirmed"
            sync -f "$state"
        fi
        systemctl stop "$timer"; promotable_boot
        printf 'INSTALLED_TRIAL_CONFIRMED boot=%s deadline=stopped\n' "$boot"; return
    fi
    check_efi_variables
    if [[ $baseline == 0 ]]; then
        [[ $action != arm ]] || die 'arm from original UFS desktop only'
        # Keep the physical outer ESP private; the running candidate owns its inner /boot.
        [[ $(readlink /proc/self/ns/mnt) != "$(readlink /proc/1/ns/mnt)" &&
           $(findmnt -nro PROPAGATION -T /) == private ]] || die 'use unshare --mount --propagation private for candidate promote/restore'
        esp=$scratch/esp; mkdir "$esp"; device=$(realpath -e /dev/disk/by-partlabel/linux-boot)
        [[ $(blkid -s UUID -o value "$device") == B6D4-FA81 ]] || die 'wrong outer ESP'
        [[ -z $(findmnt -nro TARGET -S "$device") ]] || die 'outer ESP already mounted'
        mount -t vfat -o nodev,nosuid,noexec,umask=0077 "$device" "$esp"
    else
        esp=/boot
    fi
    if [[ $action == promote && $baseline == 1 ]]; then die 'promote from the currently confirmed candidate boot'; fi
    [[ $(findmnt -nro UUID -M "$esp") == B6D4-FA81 && $(findmnt -nro FSTYPE -M "$esp") == vfat &&
       $(findmnt -nro SOURCE -M "$esp") == "$(realpath -e /dev/disk/by-partlabel/linux-boot)" ]] || die 'unexpected boot mount'
    exec 8<"$esp"; flock -w 10 8 || die 'another ESP change is active'
    if [[ $action == arm ]]; then check_prepared_image; fi
    menu "$action"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
