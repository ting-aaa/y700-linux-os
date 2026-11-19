#!/usr/bin/env bash
# Exercise ownership logic using local files. No real device or sysfs path is used.
set -euo pipefail
repo=$(cd "$(dirname -- "$0")/.." && pwd)
source "$repo/scripts/trial-ssc.sh"

if [[ ${1:-} == --qrtr-fixture ]]; then
    grep -qw y700.ssc_fixture=1 /proc/cmdline
    [[ ! -e /dev/fastrpc-sdsp ]]
    cd /opt/ssc-test
    export PYTHONPATH=$PWD:$PWD/ssc_server:$PWD/python PYTHONUNBUFFERED=1
    uv=$PWD/uv run=$(mktemp -d /run/ssc-trial-test.XXXXXXXX)
    export UV_CACHE_DIR=$run/uv-cache
    check_running() { :; }
    sdsp_present() { :; }
    (qrtr_lookup baseline 2)
    if (qrtr_lookup wait 1) > "$run/absent" 2>&1; then exit 1; fi
    grep -Fx 'SSC QRTR wait timeout: service 400 not announced' "$run/absent"
    server=
    trap 'if [[ -n $server ]]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi' EXIT
    (
        sleep 2
        exec "$uv" run --offline --no-project --python /usr/bin/python3 python -B ./mock.py normal
    ) > "$run/mock" 2>&1 &
    server=$!
    discover_and_sample | tee "$run/result"
    grep -F 'SSC QRTR ready: service=400 ' "$run/result"
    grep -Fx 'SSC sample exit=0' "$run/result"
    grep -F "registered 'ssc'" "$run/sample"
    grep -F 'Sensor enable request sent successfully' "$run/sample"
    grep -F 'Sensor disable request sent successfully' "$run/sample"
    grep -F 'SSC first sample row: Accelerometer sensor measurement:' "$run/result"
    if (qrtr_lookup baseline 2) > "$run/stale" 2>&1; then exit 1; fi
    grep -Fx 'SSC QRTR baseline: 1 existing service 400 endpoint(s)' "$run/stale"
    echo SSC_TRIAL_QRTR_PASS
    exit 0
fi

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
run=$scratch/session
mkdir "$run"
events=$scratch/events

(
    slpi=$scratch/file-backed-endpoint
    mkdir "$slpi"
    printf 'offline\n' > "$slpi/state"
    identity > "$run/identity"
    (write_state start)
    read -r line < "$slpi/state"
    [[ $line == start ]]
    mv "$slpi/state" "$slpi/previous"
    printf 'unrelated\n' > "$slpi/state"
    ! (write_state stop)
    [[ $(<"$slpi/state") == unrelated ]]
    printf 'running\n' > "$slpi/state"
    identity > "$run/identity"
    ! (write_state start)
    [[ $(<"$slpi/state") == running ]]
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

    systemctl() { return 1; }
    target=$run/firmware
    reset_fake
    start_once
    ! cleanup
    [[ $(<"$events") == $'start\nstop\nunmount' ]]
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

(
    run=$scratch/listener
    mkdir "$run"
    INVOCATION_ID=mock
    systemd-run() { printf '%s\n' "$@" > "$scratch/systemd-args"; }
    arm_listener
    [[ -d $run/armed && ! -e $run/armed/owned ]]
    grep -Fq "$run/armed:/run/trial-owner" "$scratch/systemd-args"
    grep -Fq '[[ -e /run/trial-owner/owned && -c /dev/fastrpc-sdsp ]]' "$scratch/systemd-args"
)

(
    check_running() { :; }
    qrtr_lookup() {
        [[ $* == 'wait 12' ]] || return 2
        sleep 0.3
        if [[ $discovery == absent ]]; then
            echo 'SSC QRTR wait timeout: service 400 not announced' >&2
            return 1
        fi
        touch "$scratch/ready"
        echo 'SSC QRTR ready: service=400 instance=0 node=2 port=12'
    }
    sdsp_present() { [[ -e $scratch/ready ]]; }
    cat > "$scratch/ssccli" <<'COLLECTOR'
#!/bin/sh
test "$*" = '--sensor accelerometer --timeout 1' || exit 20
test -f "$FIXTURE_READY" || exit 21
echo 'collect' >> "$FIXTURE_EVENTS"
echo 'diagnostic from collector' >&2
echo 'Accelerometer sensor measurement: X=nan Y=1.000000 Z=1.000000 m/s²'
if [ "$FIXTURE_MODE" = fail ]; then exit 254; fi
echo 'Accelerometer sensor measurement: X=-0.250000 Y=1.000000 Z=9.000000 m/s²'
echo 'Accelerometer sensor measurement: X=0.250000 Y=1.000000 Z=9.000000 m/s²'
COLLECTOR
    chmod +x "$scratch/ssccli"
    export PATH=$scratch:$PATH FIXTURE_READY=$scratch/ready FIXTURE_EVENTS=$events FIXTURE_MODE=ok
    discovery=absent
    : > "$events"
    ! discover_and_sample > "$scratch/missing"
    [[ ! -s $events && ! -e $run/sample ]]
    grep -Fxq 'SSC qrtr exit=1' "$scratch/missing"
    grep -Fxq 'SSC QRTR wait timeout: service 400 not announced' "$scratch/missing"

    discovery=delayed
    rm -f "$run/qrtr.reported"
    discover_and_sample > "$scratch/success"
    [[ $(<"$events") == collect ]]
    grep -Fxq 'SSC sample exit=0' "$scratch/success"
    grep -Fxq 'diagnostic from collector' "$scratch/success"
    grep -Fxq 'SSC first sample row: Accelerometer sensor measurement: X=-0.250000 Y=1.000000 Z=9.000000 m/s²' "$scratch/success"

    : > "$events"
    export FIXTURE_MODE=fail
    rm -f "$run/qrtr.reported" "$run/sample.reported" "$scratch/ready"
    ! discover_and_sample > "$scratch/failure"
    [[ $(<"$events") == collect ]]
    grep -Fxq 'SSC sample exit=254' "$scratch/failure"
    grep -Fxq 'diagnostic from collector' "$scratch/failure"
    ! grep -q 'SSC first sample row:' "$scratch/failure"

    rm -f "$run/sample.reported" "$run/sample.exit"
    report_job sample > "$scratch/external-stop"
    grep -Fxq 'SSC sample exit=unavailable' "$scratch/external-stop"
    grep -Fxq 'diagnostic from collector' "$scratch/external-stop"
    [[ -z $(report_job sample) ]]
)

echo 'PASS: delayed and absent service, finite first sample, exact collector failure and external-stop output'
