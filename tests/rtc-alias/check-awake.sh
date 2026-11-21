#!/bin/sh
# Only used inside a diskless QEMU guest with the synthetic PL031.
set -eu
b=/bin/busybox
alarm=/sys/class/rtc/rtc1/wakealarm
/guest-probe
if /board-probe --awake-alarm; then exit 1; fi
(exec 5</dev/rtc1; if /guest-probe --awake-alarm; then exit 1; fi)
for i in 1 2; do /guest-probe --awake-alarm; done
start_probe() {
    /guest-probe --awake-alarm >/watch.log 2>&1 &
    pid=$!
    for i in $($b seq 20); do
        if $b grep -q RTC_ALARM_ARMED /watch.log; then return; fi
        $b sleep 0.05
    done
    return 1
}
start_probe
kill -TERM "$pid"
if wait "$pid"; then exit 1; fi
$b grep 'original_disabled_time_restored=1 result=incomplete' /watch.log
test -z "$($b cat "$alarm")"
start_probe
# A privileged foreign sysfs writer can replace the running probe's alarm.
# The probe must preserve its replacement even when interrupted.
echo 0 >"$alarm"
echo +60 >"$alarm"
reserved=$($b cat "$alarm")
kill -TERM "$pid"
if wait "$pid"; then exit 1; fi
$b grep 'RTC_ALARM_FOREIGN left_untouched=1' /watch.log
test -n "$reserved" && test "$($b cat "$alarm")" = "$reserved"
if /guest-probe --awake-alarm; then exit 1; fi
test -n "$reserved" && test "$($b cat "$alarm")" = "$reserved"
echo 0 >"$alarm"
# Linux now retains a disabled, nonzero AIE time in the kernel.
if /guest-probe --awake-alarm; then exit 1; fi
test -z "$($b cat "$alarm")"
echo 'RTC_AWAKE_QA_PASS virtual=PL031 events=2 wrong_board=refused occupied_fd=refused enabled=preserved disabled_reservation=refused interruption=restored foreign_replacement=preserved'
