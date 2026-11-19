#!/usr/bin/env bash
# Exercise ownership logic using local files. No real device or sysfs path is used.
set -euo pipefail
repo=$(cd "$(dirname -- "$0")/.." && pwd)
source "$repo/scripts/trial-ssc.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
run=$scratch/session
mkdir "$run"
events=$scratch/events

(
    slpi=$scratch/file-backed-endpoint
    mkdir "$slpi"
    printf 'dummy\n' > "$slpi/state"
    identity > "$run/identity"
    (write_state start)
    [[ $(<"$slpi/state") == start ]]
    mv "$slpi/state" "$slpi/previous"
    printf 'unrelated\n' > "$slpi/state"
    ! (write_state stop)
    [[ $(<"$slpi/state") == unrelated ]]
)

read_state() { printf '%s\n' "$fake_state"; }
identity() { printf '%s\n' "$fake_id"; }
write_state() {
    printf '%s\n' "$1" >> "$events"
    case $1 in
        start)
            [[ ${fail_start:-0} == 0 ]] || return 1
            refs=$((refs + 1))
            fake_state=running ;;
        stop)
            [[ ${fail_stop:-0} == 0 ]] || return 1
            refs=$((refs - 1))
            if (( refs == 0 )); then fake_state=offline; fi ;;
        *) return 2 ;;
    esac
}

reset_fake() {
    rm -f -- "$run/phase"
    : > "$events"
    fake_state=offline fake_id=first refs=0 fail_start=0 fail_stop=0
    identity > "$run/identity"
}

reset_fake
release_once
[[ ! -s $events ]]

(
    reset_fake
    stash_phase() { return 1; }
    ! start_once
    [[ ! -s $events ]]
)

reset_fake
fake_state=running refs=1
! start_once
release_once
[[ ! -s $events && $fake_state == running && $refs == 1 ]]

reset_fake
start_once
! start_once
release_once
release_once
[[ $(<"$events") == $'start\nstop' && $fake_state == offline && $refs == 0 ]]

reset_fake
fail_start=1
! start_once
release_once
[[ $(<"$events") == start && $(phase) == failed ]]

reset_fake
stash_phase starting
fake_state=running refs=1
! release_once
[[ ! -s $events && $fake_state == running ]]

reset_fake
start_once
fail_stop=1
! release_once
! release_once
[[ $(<"$events") == $'start\nstop' && $(phase) == releasing ]]

reset_fake
start_once
fake_id=replaced
! release_once
[[ $(<"$events") == start && $fake_state == running ]]

reset_fake
start_once
fake_state=crashed
release_once
[[ $(<"$events") == $'start\nstop' && $fake_state == offline ]]

reset_fake
start_once
refs=2
! release_once
release_once
[[ $(<"$events") == $'start\nstop' && $fake_state == running && $refs == 1 ]]

reset_fake
start_once
fake_state=offline refs=0
release_once
[[ $(<"$events") == start ]]

(
    worker_context() { :; }
    board() { :; }
    locate() { :; }
    check_fault() { return 1; }
    mountpoint() { return 0; }
    umount() { printf 'unmount\n' >> "$events"; }
    systemctl() {
        if [[ $1 == show ]]; then
            echo 'fixture listener'
        else
            printf 'listener-stop\n' >> "$events"
            return 1
        fi
    }

    mkdir "$run/firmware"
    printf 'fixture listener\n' > "$run/listener-description"
    target=$run/firmware
    reset_fake
    start_once
    ! cleanup
    [[ $(<"$events") == $'start\nlistener-stop\nstop\nunmount' ]]

    target=$scratch/another-mount
    mkdir "$target"
    reset_fake
    ! cleanup
    [[ $(<"$events") == listener-stop ]]
)

# Run the preflight dispatcher with local stand-ins. Any attempt to stage files,
# register a service or invoke the guarded writer fails the test.
(
    board() { :; }
    locate() { slpi=$scratch/dummy-slpi; adsp=$scratch/dummy-adsp; }
    check_baseline() { :; }
    firmware_baseline() { :; }
    systemd-run() { exit 99; }
    write_state() { exit 99; }
    verify_assets() { exit 99; }
    mkdir "$scratch/dummy-slpi" "$scratch/dummy-adsp"
    printf 'slpi.mdt\n' > "$scratch/dummy-slpi/firmware"
    printf 'enabled\n' > "$scratch/dummy-slpi/recovery"
    printf 'running\n' > "$scratch/dummy-adsp/state"
    main
) | grep -Fq 'SSC preflight passed. No trial was started.'

echo 'PASS: read-only dispatch, no duplicate start/stop, uncertain write, race, and changed-identity cleanup'
