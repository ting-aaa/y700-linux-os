#!/bin/bash
# Exercise board-cycle in a temporary filesystem with simulated logind, RTC and tracefs.
# All /proc and /sys paths in the copy are redirected before it is executed.
set -euo pipefail
repo=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
export fixture=$work
sed -E -e "s@([[:space:]=\"<])/(sys|proc)/@\1$work/\2/@g" \
    -e 's/\$EUID == 0/1 == 1/' "$repo/board-cycle.sh" >"$work/run.sh"
mkdir -p "$work"/{sys/kernel/tracing/instances,sys/class/rtc/rtc1/device/power,sys/power/suspend_stats,proc/device-tree,proc/sys/kernel/random}
printf 'lenovo,asphalt\0' >"$work/proc/device-tree/compatible"
echo y700.release=dev12.11 >"$work/proc/cmdline"
echo boot1 >"$work/proc/sys/kernel/random/boot_id"
echo '247: 0 pm8xxx_rtc_alarm' >"$work/proc/interrupts"
echo enabled >"$work/sys/class/rtc/rtc1/device/power/wakeup"
findmnt() { echo c0e447e4-82db-59ee-91d6-0e1ec9d5f45e; }
busctl() {
    case ${!#} in
        PreparingForSleep) echo 'b false';; InhibitDelayMaxUSec) echo 't 5000000';;
        CanSuspend) echo 's "yes"';; *) return 1;;
    esac
}
timeout() { [[ $1 == -k && $2 == 2 && $3 == 12 && $4 == systemctl && $5 == suspend ]] && systemctl suspend; }
mkdir() {
    command mkdir "$@" || return
    if [[ $1 == "$fixture/sys/kernel/tracing/instances/"y700_* ]]; then
        command mkdir -p "$1/events/power/suspend_resume" "$1/events/y700_board/${1##*/}"
    fi
}
rmdir() {
    [[ $# == 1 && $1 == "$fixture/sys/kernel/tracing/instances/"y700_* ]] || return 1
    command rm -r -- "$1"
}
cat() {
    if [[ ${1:-} == "$fixture/sys/power/mem_sleep" ]]; then
        case "$(command cat "$1")" in
            s2idle) echo '[s2idle] deep';; deep) echo 's2idle [deep]';; *) return 1;;
        esac
    else command cat "$@"; fi
}
systemctl() {
    [[ $* == suspend ]] || return 1
    local t event value=3 irq=247
    t=("$fixture"/sys/kernel/tracing/instances/y700_*)
    event=${t##*/}
    if [[ $scenario == wrong-state || $scenario == baseline ]]; then value=1; fi
    printf 'task: suspend_resume: machine_suspend[%d] begin\n' "$value" >"$t/trace"
    if [[ $value == 3 && $scenario != missing-psci ]]; then echo 'task: psci_system_suspend_enter <-suspend_devices_and_enter' >>"$t/trace"; fi
    printf 'task: suspend_resume: machine_suspend[%d] end\n' "$value" >>"$t/trace"
    [[ $scenario != other-wake ]] || irq=238
    echo "task: $event: (pm_system_irq_wakeup) irq=$irq" >>"$t/trace"
    if [[ $scenario == platform-error ]]; then echo 1 >"$fixture/sys/power/suspend_stats/fail"
    else echo 1 >"$fixture/sys/power/suspend_stats/success"; fi
    if [[ $scenario == interrupted ]]; then kill -TERM "$$"; fi
    touch "$fixture/returned"
}
export -f findmnt busctl mkdir rmdir cat systemctl timeout
cat >"$work/rtc" <<'ALARM'
#!/bin/bash
set -eu
if [[ $1 == --read-alarm ]]; then
    echo "RTC_SAVED_ALARM enabled=$([[ $scenario == occupied ]] && echo 1 || echo 0) pending=0 rtc_seconds=81"
    exit
fi
[[ $1 == --reserve-wake-alarm && $scenario != occupied ]]
trap 'echo restored >"$fixture/cleanup"; exit 1' TERM
echo 'RTC_ALARM_ARMED irq=247 delay_s=20'
for i in {1..100}; do [[ -e $fixture/returned ]] && break; sleep .05; done
[[ -e $fixture/returned ]]
gap=19012; [[ $scenario != awake ]] || gap=0
echo "RTC_RESERVE_OBSERVATION suspend_gap_ms=$gap"
ALARM
chmod +x "$work/rtc"
for scenario in baseline pass occupied stale-alarm missing-psci wrong-state platform-error other-wake awake interrupted; do
    export scenario
    out=$work/$scenario
    rm -f "$work/returned" "$work/cleanup"
    echo s2idle >"$work/sys/power/mem_sleep"
    echo 100 >"$work/sys/class/rtc/rtc1/since_epoch"
    end=120; [[ $scenario != stale-alarm ]] || end=102
    echo "$end" >"$work/sys/class/rtc/rtc1/wakealarm"
    printf '0\n' >"$work/sys/power/suspend_stats/success"
    printf '0\n' >"$work/sys/power/suspend_stats/fail"
    args=(--deep); [[ $scenario != baseline ]] || args=()
    rc=0; bash "$work/run.sh" "$out" "$work/rtc" "${args[@]}" >"$out.log" 2>&1 || rc=$?
    if [[ $scenario == pass || $scenario == baseline ]]; then
        [[ $rc == 0 ]] && grep -q '^SUSPEND_BOARD_PASS ' "$out.log" || { command cat "$out.log"; exit 1; }
    else
        [[ $rc != 0 ]] && ! grep -q '^SUSPEND_BOARD_PASS ' "$out.log" || exit 1
    fi
    [[ $(command cat "$work/sys/power/mem_sleep") == s2idle ]]
    [[ -z $(ls -A "$work/sys/kernel/tracing/instances") ]]
    if [[ $scenario == stale-alarm ]]; then [[ -e $work/cleanup && ! -e $work/returned ]]; fi
    if [[ $scenario == occupied ]]; then [[ ! -e $work/returned && ! -e $work/cleanup ]]; fi
    echo "SUSPEND_FIXTURE_PASS case=$scenario controller_exit=$rc"
done
