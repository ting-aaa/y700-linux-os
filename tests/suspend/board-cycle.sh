#!/bin/bash
# One attended s2idle cycle via logind with a separately guarded PMIC alarm.
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
[[ $EUID == 0 && ( $# == 2 || ( $# == 3 && $3 == --power-key ) ) ]] ||
    { echo 'Usage: board-cycle.sh NEW_RESULTS RTC_HELPER [--power-key]' >&2; exit 2; }
out=$(realpath -m "$1")
helper=$(realpath -e "$2")
[[ -x $helper && ! -e $out && ! -L $out ]]
grep -azFxq lenovo,asphalt /proc/device-tree/compatible
grep -qw y700.release=dev12.11 /proc/cmdline
if grep -qw y700.installed_trial /proc/cmdline; then
    echo 'Select the permanent dev12.11 entry before the sleep test' >&2
    exit 1
fi
[[ $(findmnt -nro UUID -M /) == c0e447e4-82db-59ee-91d6-0e1ec9d5f45e ]]
[[ $(cat /sys/power/mem_sleep) == *'[s2idle]'* ]]
[[ $(cat /sys/class/rtc/rtc1/device/power/wakeup) == enabled ]]
[[ $(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspend) == 's "yes"' ]]
mkdir -m700 "$out"
exec > >(tee "$out/summary") 2>&1
trace=/sys/kernel/tracing
event=y700_s2idle_$$
instance=$trace/instances/$event
mkdir "$instance"
alarm_pid=
probe=0
cleanup() {
    if [[ -n $alarm_pid ]] && kill -0 "$alarm_pid" 2>/dev/null; then
        kill -TERM "$alarm_pid" || :
        wait "$alarm_pid" || :
    fi
    if ((probe)); then echo 0 > "$instance/events/y700_board/$event/enable"; fi
    rmdir "$instance"
    if ((probe)); then echo "-:y700_board/$event" >> "$trace/kprobe_events"; fi
}
trap cleanup EXIT
echo "p:y700_board/$event pm_system_irq_wakeup irq=%x0:u32" >> "$trace/kprobe_events"
probe=1
echo 1 > "$instance/events/y700_board/$event/enable"
echo 1 > "$instance/tracing_on"
stats=/sys/power/suspend_stats
boot=$(cat /proc/sys/kernel/random/boot_id)
start=$(cat "$stats/success")
fail=$(cat "$stats/fail")
alarm_arg=--reserve-wake-alarm
wake_action=pm8xxx_rtc_alarm
if [[ ${3:-} == --power-key ]]; then
    alarm_arg=--key-wake-fallback
    wake_action=pmic_pwrkey
fi
"$helper" --read-alarm | grep '^RTC_SAVED_ALARM ' > "$out/alarm-before"
"$helper" "$alarm_arg" >"$out/alarm" 2>&1 &
alarm_pid=$!
for i in {1..50}; do
    grep -q '^RTC_ALARM_ARMED ' "$out/alarm" && break
    kill -0 "$alarm_pid" || { cat "$out/alarm"; exit 1; }
    sleep .1
done
grep -q '^RTC_ALARM_ARMED ' "$out/alarm"
echo "SUSPEND_REQUEST mode=s2idle boot=$boot success_before=$start fail_before=$fail"
sync -f "$out"
systemctl suspend
alarm_rc=0
wait "$alarm_pid" || alarm_rc=$?
alarm_pid=
for i in {1..40}; do
    if [[ $(cat "$stats/success") != "$start" || $(cat "$stats/fail") != "$fail" ]]; then break; fi
    sleep .2
done
echo 0 > "$instance/tracing_on"
irqs=$(sed -n "s/.*$event: .* irq=\([0-9]*\)$/\1/p" "$instance/trace" | sort -nu | paste -sd,)
rtc_irq=$(awk '/ pm8xxx_rtc_alarm$/ {gsub(/:/,"",$1); print $1}' /proc/interrupts)
expected_irq=$(awk -v action="$wake_action" '$NF==action {gsub(/:/,"",$1); print $1}' /proc/interrupts)
end=$(cat "$stats/success")
last_fail=$(cat "$stats/fail")
printf 'SUSPEND_RETURN success_after=%s fail_after=%s wake_irqs=%s rtc_irq=%s alarm_exit=%s\n' "$end" "$last_fail" "${irqs:-none}" "$rtc_irq" "$alarm_rc"
cat "$out/alarm"
"$helper" --read-alarm | grep '^RTC_SAVED_ALARM ' > "$out/alarm-after"
cmp "$out/alarm-before" "$out/alarm-after"
echo 'RTC_ALARM_RESTORED independent_readback=1'
[[ $(cat /proc/sys/kernel/random/boot_id) == "$boot" && $rtc_irq =~ ^[0-9]+$ ]]
(( end == start+1 && last_fail == fail && alarm_rc == 0 ))
[[ $expected_irq =~ ^[0-9]+$ && $irqs == "$expected_irq" ]]
echo "SUSPEND_BOARD_PASS mode=s2idle same_boot=1 wake_source=$wake_action"
