#!/bin/sh
# Controls for the production kernel on QEMU virt with a virtual PL031.
set -eu
b=/bin/busybox
base=/sys/kernel/tracing
$b mount -t tracefs tracefs "$base"
t=$base/instances/rtcqa
$b mkdir "$t"
echo psci_system_suspend_enter >"$t/set_ftrace_filter"
echo function >"$t/current_tracer"
echo 1 >"$t/events/power/suspend_resume/enable"
echo 1 >"$t/tracing_on"
test "$($b cat /sys/power/mem_sleep)" = '[s2idle]'
if echo deep >/sys/power/mem_sleep; then exit 1; fi
saved=$(/guest-probe --read-alarm | $b grep '^RTC_SAVED_ALARM ')
success=$($b cat /sys/power/suspend_stats/success)
/guest-probe --reserve-wake-alarm >/alarm.log 2>&1 &
pid=$!
for n in $($b seq 50); do $b grep -q RTC_ALARM_ARMED /alarm.log && break; $b sleep .1; done
$b grep -q RTC_ALARM_ARMED /alarm.log
echo mem >/sys/power/state
wait "$pid"
$b cat /alarm.log
test "$($b cat /sys/power/suspend_stats/success)" -eq "$((success+1))"
test "$(/guest-probe --read-alarm | $b grep '^RTC_SAVED_ALARM ')" = "$saved"
echo 0 >"$t/tracing_on"
$b grep 'machine_suspend\[' "$t/trace" >/machine.trace
$b grep -F 'machine_suspend[1] begin' /machine.trace
$b grep -F 'machine_suspend[1] end' /machine.trace
if $b grep -q psci_system_suspend_enter "$t/trace"; then exit 1; fi
$b rmdir "$t"
echo 'S2IDLE_CONTROL_PASS deep_unavailable=1 filter_accepted=1 platform_callback_absent=1 complete_s2idle=1 alarm_restored=1'
