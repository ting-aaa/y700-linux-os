#!/usr/bin/env bash
# Read-only by default. The physical trial requires an attended, explicit invocation.
set -euo pipefail
export LC_ALL=C

unit=y700-ssc-first-trial.service
listener=y700-ssc-first-trial-listener.service
run=/run/y700-ssc-first-trial
relative_fw=qcom/sm8475/lenovo/tb320fc
target=/usr/lib/firmware/$relative_fw
dt=/sys/firmware/devicetree/base
script=$(realpath -e -- "${BASH_SOURCE[0]}")
assets=${script%/*}/trial-ssc-assets.py

die() { echo "SSC trial: $*" >&2; exit 1; }

board() {
    [[ $(uname -m) == aarch64 && $(uname -r) == 7.3.4-asphalt-prc ]] || die 'Expected the original Asphalt PRC ARM64 kernel'
    [[ $(stat -f -c %T /sys) == sysfs && $(cat /proc/1/comm) == systemd ]] || die 'Expected physical sysfs and systemd as PID 1'
    [[ $(tr -d '\0' < "$dt/model") == 'Lenovo Legion Y700 2nd gen' && $(tr -d '\0' < "$dt/region_country") == PRC ]] || die 'Expected the PRC Y700 device tree'
    [[ $(tr '\0' '\n' < "$dt/compatible") == $'lenovo,asphalt\nqcom,sm8475' ]] || die 'Unexpected board compatible'
    [[ $(od -An -v -tx1 "$dt/qcom,board-id" | tr -d ' \n') == 0001000800000000 ]] || die 'Unexpected PRC board ID'
    [[ $(od -An -v -tx1 "$dt/qcom,msm-id" | tr -d ' \n') == 0000021300010000 ]] || die 'Unexpected PRC SoC ID'
}

locate() {
    local path name
    slpi= adsp=
    for path in /sys/class/remoteproc/remoteproc*; do
        [[ -r $path/name ]] || continue
        name=$(<"$path/name")
        case $name in
            slpi) [[ -z $slpi ]] || die 'Multiple SLPI remote processors'; slpi=$path ;;
            adsp) [[ -z $adsp ]] || die 'Multiple ADSP remote processors'; adsp=$path ;;
        esac
    done
    [[ -n $slpi && -n $adsp ]] || die 'Expected both SLPI and ADSP'
    slpi_device=$(realpath -e "$slpi/device")
    slpi_node=$(realpath -e "$slpi/device/of_node")
    [[ $slpi_device == /sys/devices/platform/*/2400000.remoteproc && $slpi_node == "$dt"/*/remoteproc@2400000 ]] || die 'Unexpected SLPI platform device'
    [[ $(tr -d '\0' < "$slpi_node/compatible") == qcom,sm8450-slpi-pas && $(<"$slpi/firmware") == "$relative_fw/slpi.mdt" ]] || die 'Unexpected SLPI PAS or firmware name'
    [[ $(tr '\0' '\n' < "$slpi_node/glink-edge/fastrpc/qcom,protection-domain") == $'tms/servreg\nmsm/slpi/sensor_pd' ]] || die 'Missing board SLPI protection-domain binding'
    [[ $(tr -d '\0' < "$slpi_node/glink-edge/fastrpc/label") == sdsp && -f $slpi_node/glink-edge/fastrpc/qcom,non-secure-domain ]] || die 'Unexpected FastRPC device domain'
}

read_state() { cat "$slpi/state"; }
identity() {
    local endpoint
    endpoint=$(stat -Lc '%d:%i' "${1:-$slpi/state}") || return 1
    printf '%s %s %s\n' "$(</proc/sys/kernel/random/boot_id)" "$slpi" "$endpoint"
}

write_state() {
    local fd rc=0 owner=$BASHPID
    exec {fd}<> "$slpi/state" || return 1
    # Compare the actual open endpoint. A rebind can reuse a class path.
    if [[ $(identity "/proc/$owner/fd/$fd") == "$(<"$run/identity")" ]]; then
        printf '%s\n' "$1" >&"$fd" || rc=$?
    else
        rc=1
    fi
    exec {fd}>&-
    return "$rc"
}

check_baseline() {
    [[ $(read_state) == offline ]] || die 'SLPI must already be offline, leave the existing owner alone'
    [[ $(<"$adsp/state") == running ]] || die 'Expected the original ADSP to remain running'
    [[ ! -e /dev/fastrpc-sdsp ]] || die 'SDSP node already exists'
    local service state
    for service in y700-ssc.service iio-sensor-proxy.service "$listener"; do
        state=$(systemctl show "$service" --property=ActiveState --value)
        [[ $state == inactive ]] || die "$service is $state"
    done
    [[ -x /usr/libexec/y700-ssc/sdsprpcd && -r /usr/share/y700/ssc/etc/sensors/sns_reg_config &&
       -r /usr/share/y700/ssc/dsp/fastrpc_shell_2 ]] || die 'Expected the installed SSC listener and board sensor data'
    command -v ssccli >/dev/null || die 'Expected the installed ssccli'
    [[ -d /sys/module/qcom_pd_mapper ]] || modinfo -n qcom_pd_mapper >/dev/null || die 'Missing Qualcomm PD mapper'
}

verify_assets() {
    UV_CACHE_DIR=$run/uv-cache "$uv" run --offline --no-project --python /usr/bin/python3 python -B \
        "$assets" "$2" --package "$1" --state-sha256 "$3" --dt-node "$slpi_node" --output "$run"
}

stash_phase() {
    printf '%s\n' "$1" > "$run/phase.new" || return 1
    mv -T -- "$run/phase.new" "$run/phase"
}

phase() { if [[ -r $run/phase ]]; then cat "$run/phase"; fi; }

start_once() {
    [[ -z $(phase) && $(read_state) == offline ]] || return 1
    stash_phase starting || return 1
    if write_state start; then
        stash_phase owned
    else
        stash_phase failed
        return 1
    fi
}

release_once() {
    local state
    case $(phase) in
        owned)
            [[ -s $run/identity && $(identity) == "$(<"$run/identity")" ]] || { echo 'SSC trial: SLPI endpoint changed, ownership cannot be released' >&2; return 1; }
            state=$(read_state) || return 1
            case $state in
                running|crashed) ;;
                offline) stash_phase released; return 0 ;;
                *) echo "SSC trial: unexpected SLPI state $state, no stop attempted" >&2; return 1 ;;
            esac
            stash_phase releasing || return 1
            if write_state stop; then
                stash_phase released || return 1
                [[ $(read_state) == offline ]] || { echo 'SSC trial: own reference released, SLPI still has another owner or is recovering' >&2; return 1; }
            else
                echo 'SSC trial: owned stop failed, no repeat attempted' >&2
                return 1
            fi ;;
        starting|releasing)
            echo 'SSC trial: sysfs completion is unconfirmed, no further stop attempted' >&2
            return 1 ;;
    esac
}

firmware_baseline() {
    [[ $(realpath -e /lib/firmware) == /usr/lib/firmware && -d $target && $(realpath -e "$target") == "$target" ]] || die 'Expected the existing usr-merged board firmware directory'
    mountpoint -q "$target" && die 'Board firmware directory is already a mountpoint'
    [[ -z $(tr -d '\0\n' </sys/module/firmware_class/parameters/path) ]] || die 'Custom kernel firmware search path is active'
    local dir found
    for dir in /usr/lib/firmware{,/updates,/updates/"$(uname -r)",/"$(uname -r)"}; do
        [[ -d $dir/$relative_fw ]] || continue
        found=$(find -H "$dir/$relative_fw" -maxdepth 1 -name 'slpi*' -print -quit)
        [[ -z $found ]] || die 'Persistent SLPI firmware already resolves in the kernel search tree'
    done
}

check_fault() {
    [[ -s $run/cursor ]] || return 0
    local fault
    fault=$(journalctl -k --no-pager -o cat --after-cursor="$(<"$run/cursor")" |
        awk -v r="${slpi##*/}:" -v dev="${slpi_device##*/}:" -v adsp="${adsp##*/}:" '
            (index($0, " " r) || index($0, " " dev) || index($0, "msm/slpi/sensor_pd") ||
             index($0, "fastrpc-sdsp") || index($0, " " adsp)) &&
            tolower($0) ~ /fail|fault|fatal|crash|timeout|timed out|watchdog|recovering/ && !printed {print; printed=1}')
    if [[ -n $fault && ! -e $run/first-fault ]]; then
        printf '%s\n' "$fault" > "$run/first-fault"
        printf 'SSC first fault: %s\n' "$fault" >&2
    fi
    [[ ! -e $run/first-fault ]]
}

worker_context() {
    [[ $EUID == 0 && -d $run && ! -L $run && $(stat -c '%u:%a' "$run") == 0:700 ]] || die 'Missing PID 1 trial runtime directory'
    [[ ${INVOCATION_ID:-} =~ ^[0-9a-f]{32}$ && $(systemctl show "$unit" -p InvocationID --value) == "$INVOCATION_ID" ]] || die 'Worker is outside the dedicated PID 1 unit'
    [[ $(readlink /proc/self/ns/mnt) == "$(readlink /proc/1/ns/mnt)" ]] || die 'Worker must share the PID 1 mount namespace'
}

arm_listener() {
    # Unique invocation marker lets cleanup identify a unit even if the D-Bus reply was lost.
    local description="Y700 SSC trial listener $INVOCATION_ID"
    # Build mount destinations inside /run so the host need not acquire Android paths.
    local listener_root=$run/listener-root
    mkdir -p "$listener_root"/{usr,etc,dev,proc,sys,tmp,run,vendor/etc/sensors,system/vendor/etc/sensors,vendor/dsp,persist/sensors,mnt/vendor/persist/sensors}
    ln -s usr/lib "$listener_root/lib"
    ln -s usr/bin "$listener_root/bin"
    printf '%s\n' "$description" > "$run/listener-description"
    systemd-run --quiet --collect --unit="$listener" --service-type=exec --description="$description" \
        -p "Requisite=$unit" -p "PartOf=$unit" \
        -p "RootDirectory=$listener_root" -p MountAPIVFS=yes \
        -p Restart=no -p RuntimeMaxSec=38s -p TimeoutStopSec=4s \
        -p 'BindReadOnlyPaths=/usr:/usr /etc:/etc /usr/share/y700/ssc/etc/sensors:/vendor/etc/sensors /usr/share/y700/ssc/etc/sensors:/system/vendor/etc/sensors /usr/share/y700/ssc/dsp:/vendor/dsp' \
        -p "BindPaths=/dev:/dev $run/state:/persist/sensors $run/state:/mnt/vendor/persist/sensors" \
        --setenv=LD_LIBRARY_PATH=/usr/lib/y700/ssc \
        '--setenv=ADSP_LIBRARY_PATH=;/vendor/etc/sensors;/vendor/dsp;/usr/lib/firmware' \
        /bin/bash -ec 'for i in {1..80}; do if [[ -c /dev/fastrpc-sdsp ]]; then exec /usr/libexec/y700-ssc/sdsprpcd sensorspd; fi; sleep 0.25; done; exit 1'
}

cleanup() {
    worker_context
    local rc=0 description
    if [[ -r $run/listener-description ]]; then
        description=$(systemctl show "$listener" --property=Description --value)
        if [[ $description == "$(<"$run/listener-description")" ]]; then
            systemctl stop "$listener" || rc=1
        fi
    fi
    if [[ -s $run/identity ]]; then
        if (board; locate; check_fault || :; release_once); then :; else rc=1; fi
    fi
    if mountpoint -q "$target"; then
        if [[ $target -ef $run/firmware ]]; then
            umount -- "$target" || rc=1
        else
            echo 'SSC trial: an unexpected mount is at the firmware path, left untouched' >&2
            rc=1
        fi
    fi
    if [[ $rc == 0 ]]; then echo 'SSC trial: cleanup completed'; fi
    return "$rc"
}

worker() {
    worker_context
    uv=${Y700_TRIAL_UV:-}
    [[ $uv == /* && -x $uv ]] || die 'The reviewed uv executable is unavailable to the trial unit'
    board
    locate
    check_baseline
    firmware_baseline
    mkdir -m700 "$run/firmware"
    cp -a --reflink=auto "$target/." "$run/firmware/"
    verify_assets "$1" "$2" "$3"
    identity > "$run/identity"
    journalctl -k -n 1 --show-cursor -q --no-pager | sed -n 's/^-- cursor: //p' > "$run/cursor"
    [[ -s $run/cursor ]] || die 'Cannot capture a kernel journal cursor'
    check_baseline
    firmware_baseline
    mount --bind -- "$run/firmware" "$target"
    mount -o remount,bind,ro -- "$target"
    arm_listener
    start_once || die 'SLPI start was refused or failed'
    local attempt sample_pid
    for attempt in {1..40}; do
        check_fault || die 'SLPI fault observed'
        [[ $(read_state) == running ]] || die 'SLPI did not stay running'
        [[ $(<"$adsp/state") == running ]] || die 'ADSP is no longer running'
        if [[ -c /dev/fastrpc-sdsp ]]; then break; fi
        sleep 0.25
    done
    [[ -c /dev/fastrpc-sdsp ]] || die 'FastRPC device did not appear'
    timeout -k 1 8 ssccli --sensor accelerometer --timeout 1 > "$run/sample" 2>&1 &
    sample_pid=$!
    while kill -0 "$sample_pid" 2>/dev/null; do
        check_fault || die 'SLPI fault observed during sample'
        [[ $(read_state) == running ]] || die 'SLPI did not stay running during sample'
        [[ $(<"$adsp/state") == running ]] || die 'ADSP is no longer running'
        sleep 0.25
    done
    if wait "$sample_pid" &&
        grep -q '^Accelerometer sensor measurement:' "$run/sample"; then
        check_fault || die 'SLPI fault observed during sample'
        echo 'SSC trial: one real accelerometer sample received'
    else
        check_fault || :
        die 'No verified accelerometer sample, inspect listener and kernel journal'
    fi
}

main() {
    local mode=${1:---preflight}
    if (( $# )); then shift; fi
    if [[ $mode == --help ]]; then
        echo 'Usage: trial-ssc.sh [--preflight | --trial FIRMWARE.deb STATE STATE_SHA256]'
        return
    fi
    if [[ $mode == --_cleanup && $# == 0 ]]; then cleanup; return; fi
    board
    locate
    if (( $# )); then
        [[ $# == 3 && $3 =~ ^[0-9a-f]{64}$ ]] || die 'Expected firmware archive, state directory and reviewed state digest'
    fi
    case $mode in
        --preflight)
            [[ $# == 0 ]] || die 'Read-only preflight takes no arguments'
            printf 'SLPI %s state=%s firmware=%s recovery=%s\n' "${slpi##*/}" "$(read_state)" "$(<"$slpi/firmware")" "$(<"$slpi/recovery")"
            printf 'ADSP %s state=%s\n' "${adsp##*/}" "$(<"$adsp/state")"
            check_baseline
            firmware_baseline
            echo 'SSC preflight passed. No trial was started.' ;;
        --trial)
            [[ $# == 3 && $EUID == 0 ]] || die 'An explicit root trial requires all three reviewed inputs'
            uv=$(command -v uv) || die 'Put uv on the invoking root shell PATH'
            uv=$(realpath -e -- "$uv")
            [[ -x $uv ]] || die 'uv is required to validate the private assets'
            check_baseline
            firmware_baseline
            [[ $script =~ ^/[a-zA-Z0-9/_.-]+$ && -f $assets ]] || die 'Install the trial scripts together in a trusted absolute path'
            [[ ! -e $run ]] || die 'A trial runtime directory already exists'
            systemd-run --wait --collect --unit="$unit" --service-type=exec \
                -p RuntimeDirectory=y700-ssc-first-trial -p RuntimeDirectoryMode=0700 \
                -p RuntimeMaxSec=38s -p TimeoutStopSec=14s \
                -p "ExecStopPost=/bin/bash $script --_cleanup" \
                --setenv=PATH=/usr/sbin:/usr/bin:/sbin:/bin --setenv="Y700_TRIAL_UV=$uv" \
                /bin/bash "$script" --_worker "$(realpath -e -- "$1")" "$(realpath -e -- "$2")" "$3" ;;
        --_worker) [[ $# == 3 ]] || die 'Invalid worker invocation'; worker "$@" ;;
        *) die 'Unknown mode, see --help' ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
