#!/bin/bash
# One logind cycle; deep is an explicit one-shot test on the permanent dev12.11 entry.
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
check_deep_trace() {
    awk '
      /: suspend_resume: machine_suspend\[/ {
        print "PM_TRACE", $(NF-1), $NF
        if ($(NF-1) != "machine_suspend[3]") bad=1
        if ($NF == "begin" && step == 0) step=1
        else if ($NF == "end" && step == 2) step=3
        else bad=1
      }
      /: psci_system_suspend_enter([[:space:]]|$)/ {
        print "PM_TRACE psci_system_suspend_enter"
        if (step == 1) step=2; else bad=1
      }
      END {exit (bad || step != 3)}
    ' "$1"
}
if [[ $# == 2 && $1 == --check-deep-trace ]]; then check_deep_trace "$2"; exit; fi
[[ $EUID == 0 && ( $# == 2 || ( $# == 3 && ( $3 == --power-key || $3 == --deep ) ) ) ]] ||
    { echo 'Usage: board-cycle.sh NEW_RESULTS RTC_HELPER [--power-key|--deep]' >&2; exit 2; }
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
mem_sleep=/sys/power/mem_sleep
exec 9<"$mem_sleep"
flock -n 9 || { echo 'Another board-cycle is running.' >&2; exit 1; }
original=$(cat "$mem_sleep")
[[ " $original " == *' [s2idle] '* ]]
mode=s2idle
if [[ ${3:-} == --deep ]]; then
    mode=deep
    [[ " $original " == *' deep '* ]]
    manager=(org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager)
    [[ $(busctl get-property "${manager[@]}" PreparingForSleep) == 'b false' ]]
    delay=$(busctl get-property "${manager[@]}" InhibitDelayMaxUSec)
    [[ $delay =~ ^t\ ([0-9]+)$ ]]
    delay_us=${BASH_REMATCH[1]}
fi
[[ $(cat /sys/class/rtc/rtc1/device/power/wakeup) == enabled ]]
[[ $(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspend) == 's "yes"' ]]
mkdir -m700 "$out"
exec > >(tee "$out/summary") 2>&1
trace=/sys/kernel/tracing
event=y700_${mode}_$$
instance=$trace/instances/$event
mkdir "$instance"
alarm_pid=
probe=0
changed_mode=0
cleanup() {
    local rc=$?
    trap - EXIT HUP INT TERM
    set +e
    if ((changed_mode)); then
        case " $(cat "$mem_sleep") " in
            *' [deep] '*) echo s2idle >"$mem_sleep" || rc=1 ;;
        esac
        if [[ $(cat "$mem_sleep") == "$original" ]]; then
            echo 'MEM_SLEEP_RESTORED mode=s2idle'
        else echo 'MEM_SLEEP_RESTORE_UNCONFIRMED' >&2; rc=1; fi
    fi
    if [[ -n $alarm_pid ]] && kill -0 "$alarm_pid" 2>/dev/null; then
        kill -TERM "$alarm_pid" || :
        wait "$alarm_pid" || :
    fi
    if ((probe)); then echo 0 > "$instance/events/y700_board/$event/enable" || rc=1; fi
    rmdir "$instance" || rc=1
    if ((probe)); then echo "-:y700_board/$event" >> "$trace/kprobe_events" || rc=1; fi
    if ((rc == 0)); then echo "SUSPEND_BOARD_PASS mode=$mode same_boot=1 wake_source=$wake_action"; fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
echo "p:y700_board/$event pm_system_irq_wakeup irq=%x0:u32" >> "$trace/kprobe_events"
probe=1
echo 1 > "$instance/events/y700_board/$event/enable"
if [[ $mode == deep ]]; then
    # Only the normal PSCI .enter wrapper is instrumented. Leave the low-level
    # finisher, firmware call and resume trampoline alone.
    echo psci_system_suspend_enter >"$instance/set_ftrace_filter"
    echo function >"$instance/current_tracer"
    echo 1 >"$instance/events/power/suspend_resume/enable"
fi
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
echo "SUSPEND_REQUEST mode=$mode boot=$boot success_before=$start fail_before=$fail"
sync -f "$out"
if [[ $mode == deep ]]; then
    [[ $(cat "$mem_sleep") == "$original" ]]
    changed_mode=1
    echo deep >"$mem_sleep"
    [[ " $(cat "$mem_sleep") " == *' [deep] '* ]]
    target=$(cat /sys/class/rtc/rtc1/wakealarm)
    now=$(cat /sys/class/rtc/rtc1/since_epoch)
    [[ $target =~ ^[0-9]+$ && $now =~ ^[0-9]+$ ]] &&
        ((target-now >= 10 && target-now <= 20 && (target-now-5)*1000000 >= delay_us)) ||
        { echo 'RTC reservation has insufficient headroom.' >&2; exit 1; }
fi
# Once logind can queue sleep, preserve the alarm if the caller disconnects.
# The helper has its own bounded poll. A userspace timer cannot recover hung firmware.
interrupted=0
trap 'interrupted=1' HUP INT TERM
suspend_rc=0
if [[ $mode == deep ]]; then
    timeout -k 2 12 systemctl suspend || suspend_rc=$?
else systemctl suspend || suspend_rc=$?; fi
alarm_rc=0
while :; do
    if wait "$alarm_pid"; then alarm_rc=0; break; else alarm_rc=$?; fi
    ((alarm_rc > 128)) && kill -0 "$alarm_pid" 2>/dev/null || break
done
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
if [[ $mode == deep ]]; then
    check_deep_trace "$instance/trace"
    awk '/^RTC_RESERVE_OBSERVATION / {
        for (i=2; i<=NF; i++) if ($i ~ /^suspend_gap_ms=[0-9]+$/) {
            split($i, a, "="); gap=a[2]+0; n++
        }
    } END {exit !(n==1 && gap>=1000)}' "$out/alarm"
fi
[[ $(cat /proc/sys/kernel/random/boot_id) == "$boot" && $rtc_irq =~ ^[0-9]+$ ]]
(( end == start+1 && last_fail == fail && alarm_rc == 0 && suspend_rc == 0 ))
[[ $expected_irq =~ ^[0-9]+$ && $irqs == "$expected_irq" ]]
((interrupted == 0))
