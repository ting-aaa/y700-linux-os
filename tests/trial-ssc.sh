#!/usr/bin/env bash
# Exercise ownership logic using local files. No real device or sysfs path is used.
set -euo pipefail
repo=$(cd "$(dirname -- "$0")/.." && pwd)
source "$repo/scripts/trial-ssc.sh"

if [[ ${1:-} == --survey-qrtr-fixture ]]; then
    grep -qw y700.ssc_fixture=1 /proc/cmdline
    [[ ! -e /dev/fastrpc-sdsp ]]
    cd /opt/ssc-test
    export PYTHONPATH=$PWD:$PWD/ssc_server:$PWD/python PYTHONUNBUFFERED=1
    uv=$PWD/uv
    export UV_CACHE_DIR=/run/ssc-survey-uv
    run=$(mktemp -d /run/ssc-survey-trust.XXXXXXXX)
    if stage_survey_tools "$PWD/ssc-sample.arm64" "$PWD/ssc-sample.arm64" > "$run/rejected" 2>&1; then exit 1; fi
    grep -Fxq 'ssc-sample: OK' "$run/rejected"
    grep -Fxq 'ssc-hall: FAILED' "$run/rejected"
    server=
    stop_server() {
        if [[ -n $server ]]; then
            kill -TERM -- "-$server" 2>/dev/null || :
            wait "$server" 2>/dev/null || :
            server=
        fi
    }
    trap stop_server EXIT
    check_running() { :; }
    sdsp_present() { :; }
    for scenario in normal mixed transport-loss; do
        run=$(mktemp -d /run/ssc-survey.XXXXXXXX)
        : > "$run/survey-requested"
        stage_survey_tools "$PWD/ssc-sample.arm64" "$PWD/ssc-hall"
        (qrtr_lookup baseline 2)
        setsid "$uv" run --offline --no-project --python /usr/bin/python3 python -B - "$scenario" > "$run/mock" 2>&1 <<'PY' &
import multiprocessing
import os
import runpy
import signal
import sys
from ssc_server.ssc import SSC

scenario = sys.argv[1]
sample = runpy.run_path("mock.py")
hall = runpy.run_path("hall-mock.py")
if scenario == "mixed":
    original = SSC._read_data
    SSC._read_data = staticmethod(lambda: [row for row in original() if row["sensor"]["data_type"] != "mag"])
    sys.argv[1] = "silent-light"

class Combined(sample["Server"]):
    send_event = hall["HallServer"].send_event

    def _sensor_measurement(self, high, low, *args):
        if scenario == "transport-loss" and (high, low) == sample["GYRO_UID"]:
            # The mock owns a dedicated process group, including report workers.
            os.killpg(os.getpgrp(), signal.SIGTERM)
        elif (high, low) == hall["HALL_UID"]:
            hall["HallServer"]._sensor_measurement(self, high, low, *args)
        else:
            super()._sensor_measurement(high, low, *args)

multiprocessing.set_start_method("fork")
Combined().start()
PY
        server=$!
        status=0
        discover_and_survey > "$run/result" 2>&1 || status=$?
        cat "$run/result"
        case $scenario in
            normal)
                [[ $status == 0 ]]
                for name in "${survey_channels[@]}"; do grep -Fxq "SSC survey-$name exit=0" "$run/result"; done
                grep -Fxq 'Hall sensor measurement: NEAR' "$run/result"
                [[ $(grep -c '^SSC_SAMPLE ' "$run/result") == 6 ]] ;;
            mixed)
                [[ $status != 0 ]]
                grep -Fxq 'SSC survey-magnetometer exit=3' "$run/result"
                grep -Fxq 'SSC survey-light exit=4' "$run/result"
                grep -Fq 'sensor=light status=no-data' "$run/result"
                for name in accelerometer gyroscope proximity compass hall; do grep -Fxq "SSC survey-$name exit=0" "$run/result"; done ;;
            transport-loss)
                [[ $status != 0 ]]
                grep -Fq 'registered service 400 endpoint changed or disappeared' "$run/result"
                grep -Fxq 'SSC survey-accelerometer exit=0' "$run/result"
                grep -Fxq 'SSC survey-gyroscope output begins' "$run/result"
                grep -Fxq 'SSC survey-hall not run' "$run/result"
                [[ ! -e $run/survey-magnetometer ]] ;;
        esac
        stop_server
        echo "SSC_SURVEY_QRTR_CASE=$scenario"
    done
    echo SSC_TRIAL_SURVEY_QRTR_PASS
    exit 0
fi

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

(
    run=$scratch/rejected-tools
    mkdir "$run"
    printf 'unreviewed helper\n' > "$scratch/wrong-tool"
    worker_context() { :; }; board() { :; }; locate() { :; }
    check_baseline() { :; }; firmware_baseline() { :; }
    verify_assets() { touch "$scratch/staged-assets"; }
    start_once() { touch "$scratch/requested-start"; }
    export Y700_TRIAL_UV=/bin/true
    if (worker fake-firmware fake-state unused "$scratch/wrong-tool" "$scratch/wrong-tool") > "$run/rejected" 2>&1; then exit 1; fi
    grep -Fq 'Survey tool verification failed before SLPI startup' "$run/rejected"
    [[ ! -e $scratch/requested-start && ! -e $scratch/staged-assets && ! -e $run/firmware ]]
    report_survey > "$run/skipped"
    [[ $(grep -c ' not run$' "$run/skipped") == 7 ]]
)

(
    run=$scratch/survey-fault
    mkdir -p "$run/survey-tools"
    : > "$run/survey-requested"
    cat > "$run/survey-tools/ssc-sample" <<'COLLECT'
#!/bin/bash
set -eu
echo "collector entered $1"
if [[ $1 == accelerometer ]]; then exit 0; fi
touch "$SURVEY_FAULT"
exec sleep 12
COLLECT
    chmod 700 "$run/survey-tools/ssc-sample"
    export SURVEY_FAULT=$run/first-fault
    check_running() { [[ ! -e $SURVEY_FAULT ]]; }
    sdsp_present() { :; }
    qrtr_lookup() { echo 'SSC QRTR ready: service=400 instance=1 node=3 port=9'; exec sleep 30; }
    if discover_and_survey > "$run/result" 2>&1; then exit 1; fi
    grep -Fxq 'SSC survey-accelerometer exit=0' "$run/result"
    grep -Fxq 'SSC survey interrupted during gyroscope' "$run/result"
    grep -Fxq 'collector entered gyroscope' "$run/result"
    [[ $(grep -c ' not run$' "$run/result") == 5 && ! -e $run/survey-magnetometer ]]
    [[ -z $(report_survey) ]]
)

(
    run=$scratch/survey-canceled
    mkdir "$run"
    : > "$run/survey-requested"
    echo 'partial collector output' > "$run/survey-accelerometer"
    worker_context() { :; }; mountpoint() { return 1; }
    cleanup > "$run/result"
    grep -Fxq 'SSC survey-accelerometer exit=unavailable' "$run/result"
    grep -Fxq 'partial collector output' "$run/result"
    [[ $(grep -c ' not run$' "$run/result") == 6 ]]
    [[ -z $(report_survey) ]]
)

if (( EUID == 0 )); then
(
    board() { :; }; locate() { :; }; check_baseline() { :; }; firmware_baseline() { :; }
    systemd-run() { printf '%s\n' "$@" > "$scratch/worker-arguments"; }
    run=$scratch/absent
    touch "$scratch/firmware" "$scratch/one" "$scratch/two"
    mkdir "$scratch/state" "$scratch/bin"
    ln -s /bin/true "$scratch/bin/uv"
    export PATH=$scratch/bin:$PATH
    printf -v digest '%064d' 0
    inputs=("$scratch/firmware" "$scratch/state" "$digest")
    main --trial "${inputs[@]}"
    grep -Fxq 'RuntimeMaxSec=38s' "$scratch/worker-arguments"
    [[ $(tail -n1 "$scratch/worker-arguments") == "$digest" ]]
    if (main --survey "${inputs[@]}") >/dev/null 2>&1; then exit 1; fi
    if (main --trial "${inputs[@]}" "$scratch/one" "$scratch/two") >/dev/null 2>&1; then exit 1; fi
    main --survey "${inputs[@]}" "$scratch/one" "$scratch/two"
    grep -Fxq 'RuntimeMaxSec=75s' "$scratch/worker-arguments"
    [[ $(tail -n2 "$scratch/worker-arguments") == "$scratch/one"$'\n'"$scratch/two" ]]
)
fi
echo 'PASS: survey opt-in, helper rejection, first health fault, partial output and skipped channels'
