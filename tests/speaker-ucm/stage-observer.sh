#!/bin/bash
# Observe the UCM command boundary, then run the unchanged product helper.
set -euo pipefail
test "$#" = 1
test "$1" = stage
test "$(id -un)" = y700
grep -qw y700.speaker_fixture=1 /proc/cmdline
exec >> /run/speaker-observer.log 2>&1
fixture=/opt/speaker-test
read -r scenario < /run/speaker-scenario

read_control() {
    amixer -c LenovoY700 cget "name='$1'" | sed -n 's/^  : values=//p'
}

assert_stopped() {
    for speaker in SPK1 SPK2; do
        for switch in "AMP Enable Switch" "DSP1 Preload Switch"; do
            case "$(read_control "$speaker $switch")" in
                0|off) ;;
                *) echo "Not stopped at UCM command boundary: $speaker $switch" >&2; exit 1 ;;
            esac
        done
    done
}

assert_stopped
for speaker in SPK1 SPK2; do
    test "$(read_control "$speaker DSP1 Firmware")" = 1
    test "$(read_control "$speaker Digital PCM Volume")" = 249
    test "$(read_control "$speaker DACPCM Source")" = 3
done
printf 'SPEAKER_STAGE_ENTER case=%s actor=y700 amp=off preload=off gain=249 routing=ready\n' "$scenario"

result=0
"$fixture/uv" run --offline --no-project --python /usr/bin/python3 python "$fixture/speaker-calibration.py" stage || result=$?
assert_stopped
case "$scenario" in
    generic) expected=249; test "$result" = 0 ;;
    calibrated) expected=361; test "$result" = 0 ;;
    invalid) expected=249; test "$result" != 0 ;;
    *) exit 1 ;;
esac
for speaker in SPK1 SPK2; do
    test "$(read_control "$speaker Digital PCM Volume")" = "$expected"
done
printf 'SPEAKER_STAGE_RETURN case=%s rc=%s amp=off preload=off gain=%s\n' "$scenario" "$result" "$expected"
exit "$result"
