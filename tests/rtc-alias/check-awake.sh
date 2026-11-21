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
    /guest-probe "${1:---awake-alarm}" >/watch.log 2>&1 &
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

read_saved() {
    /guest-probe --read-alarm | $b grep '^RTC_SAVED_ALARM '
}
before=$(read_saved)
case "$before" in
  'RTC_SAVED_ALARM enabled=0 pending=0 rtc_seconds=0') exit 1;;
  'RTC_SAVED_ALARM enabled=0 pending=0 rtc_seconds='*) ;;
  *) exit 1;;
esac
if /board-probe --reserve-wake-alarm; then exit 1; fi
/guest-probe --reserve-wake-alarm > /reserve.log
$b cat /reserve.log
$b grep -q 'outcome=awake_event' /reserve.log
test "$(read_saved)" = "$before"
start_probe --reserve-wake-alarm
kill -TERM "$pid"
if wait "$pid"; then exit 1; fi
$b grep 'original_disabled_time_restored=1 result=incomplete' /watch.log
test "$(read_saved)" = "$before"
start_probe --reserve-wake-alarm
echo 0 >"$alarm"
echo +90 >"$alarm"
foreign=$($b cat "$alarm")
kill -TERM "$pid"
if wait "$pid"; then exit 1; fi
$b grep 'RTC_ALARM_FOREIGN left_untouched=1' /watch.log
if /guest-probe --reserve-wake-alarm; then exit 1; fi
test "$(read_saved)" = "RTC_SAVED_ALARM enabled=1 pending=0 rtc_seconds=$foreign"
test "$($b cat "$alarm")" = "$foreign"
echo 'RTC_RESERVE_QA_PASS virtual=PL031 delay_s=20 awake_event=1 disabled_nonzero_restored=1 interrupted_restored=1 foreign_preserved=1 existing_enabled_preserved=1'
