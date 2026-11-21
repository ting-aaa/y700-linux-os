#!/usr/bin/env bash
# Source from a build so the open flock survives the checks, through publication.
# /var/tmp's directory inode is shared by normal and sudo builders in this distro.
y700_storage_check() {
    local profile=$1 target=$2 mode=${3:-reserve} growth mount_at host host_growth source fs
    local floor=${Y700_STORAGE_FLOOR_MIB:-2048} host_floor=${Y700_STORAGE_HOST_FLOOR_MIB:-8192}
    [[ $mode == check || $mode == reserve ]] || { echo 'Expected check or reserve' >&2; return 2; }
    case $profile in
        board|card) growth=16384 ;;
        root) growth=8192 ;;
        release|ram|export) growth=4096 ;;
        esp|receiver) growth=2048 ;;
        status) growth=0 ;;
        archive) growth=${4:?archive budget in MiB} ;;
        *) echo "Unknown storage profile $profile" >&2; return 2 ;;
    esac
    local n
    for n in "$floor" "$host_floor" "$growth"; do
        [[ $n =~ ^(0|[1-9][0-9]{0,8})$ ]] || { echo 'Invalid MiB capacity setting' >&2; return 2; }
    done
    if [[ $mode == reserve ]]; then
        if [[ ! ${Y700_STORAGE_FD:-} =~ ^[0-9]{1,6}$ || ! /proc/self/fd/${Y700_STORAGE_FD:-0} -ef /var/tmp ]]; then
            exec {Y700_STORAGE_FD}</var/tmp || return 1
            export Y700_STORAGE_FD
        fi
        flock -xn "$Y700_STORAGE_FD" || { echo 'Storage busy: another image build holds the capacity lock' >&2; return 1; }
    fi
    mount_at=$(realpath -e -- "$target") || return 1
    local available report=0
    y700_storage_free_mib() {
        local blocks size
        read -r blocks size < <(stat -f -c '%a %S' -- "$1") || return 1
        printf '%d\n' "$((blocks * size / 1048576))"
    }
    available=$(y700_storage_free_mib "$mount_at") || return 1
    printf 'storage profile=%s scope=destination available_mib=%d growth_mib=%d floor_mib=%d\n' "$profile" "$available" "$growth" "$floor" >&2
    (( available >= growth + floor )) || report=1
    if grep -iq microsoft /proc/sys/kernel/osrelease; then
        host=${Y700_WSL_HOST_VOLUME:-/mnt/c}
        # A plain /mnt/c directory in a detached namespace measures the VHD itself.
        source=$(findmnt -nro SOURCE -M "$host") || { echo 'WSL backing Windows volume is not mounted' >&2; return 1; }
        fs=$(findmnt -nro FSTYPE -M "$host") || return 1
        [[ $fs == drvfs || $fs == 9p ]] && [[ $source =~ ^[A-Za-z]: ]] ||
            { echo 'WSL backing path must be a mounted Windows drive' >&2; return 1; }
        host_growth=$growth
        fs=$(findmnt -nro FSTYPE -T "$mount_at") || return 1
        source=$(findmnt -nro SOURCE -T "$mount_at") || return 1
        if [[ $fs == tmpfs || $fs == ramfs || ( ( $fs == drvfs || $fs == 9p ) && $source != "$(findmnt -nro SOURCE -M "$host")" ) ]]; then
            host_growth=0
        fi
        available=$(y700_storage_free_mib "$host") || return 1
        printf 'storage profile=%s scope=wsl-host available_mib=%d growth_mib=%d floor_mib=%d\n' "$profile" "$available" "$host_growth" "$host_floor" >&2
        (( available >= host_growth + host_floor )) || report=1
    fi
    if (( report )); then echo 'Insufficient free space for the configured build budget' >&2; fi
    return "$report"
}
y700_storage_check "$@"
