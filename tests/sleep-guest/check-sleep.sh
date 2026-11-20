#!/bin/bash
# Run exclusively in an enrolled, disposable QEMU virt RAM desktop.
set -Eeuo pipefail
trap 'echo "SLEEP_GUEST_FAIL line=$LINENO" >&2' ERR
export LC_ALL=C
echo SLEEP_GUEST_START
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
grep -qw y700.ram_probe=1 /proc/cmdline
qa=/run/y700-ram-qa
cd "$qa"
test "$(uname -m)" = aarch64
test "$(uname -r)" = 7.3.4-asphalt-prc
test "$(cat /proc/1/comm)" = systemd
[[ -z $(ls -A /sys/class/rtc) ]]
./awake-clocks missing-rtc
insmod ./rtc-pl031.ko
udevadm settle --timeout=15
rtc=/sys/class/rtc/rtc1
[[ $(cat "$rtc/hctosys") == 0 && ! -e /dev/rtc0 ]]
[[ $(cat "$rtc/name") == *pl031* ]]
[[ $(cat "$rtc/device/power/wakeup") == enabled && -z $(cat "$rtc/wakealarm") ]]
./awake-clocks ready
irq=$(awk '/rtc-pl031$/ { sub(/:$/, "", $1); print $1 }' /proc/interrupts)
[[ $irq =~ ^[0-9]+$ ]]
irq_total() {
    awk -v irq="$irq:" '$1 == irq { total=0; for (i=2; $i ~ /^[0-9]+$/; i++) total+=$i; print total }' /proc/interrupts
}
initial=$(irq_total)
timeout 15 rtcwake -u -d rtc1 -m on -s 4
final=$(irq_total)
(( final > initial ))
[[ -z $(cat "$rtc/wakealarm") ]]
echo "SLEEP_GUEST_AWAKE rtc=pl031 irq=$irq before=$initial after=$final"

uid=$(id -u y700)
xfce=$(pgrep -ou "$uid" -x xfce4-session)
session=$(tr '\0' '\n' < "/proc/$xfce/environ" | sed -n 's/^XDG_SESSION_ID=//p')
[[ -n $session ]]
asuser=(setpriv --reuid="$uid" --regid="$(id -g y700)" --init-groups env
        HOME=/home/y700 XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus")
while IFS= read -r -d '' setting; do
    case "$setting" in DISPLAY=*|XAUTHORITY=*) asuser+=("$setting");; esac
done < "/proc/$xfce/environ"
display_state() {
    timeout 12 "${asuser[@]}" xrandr --current | awk '$2 == "connected" { print $1, $2, $3, $4 }'
}
screen_lock() {
    timeout 12 "${asuser[@]}" busctl --user call org.xfce.ScreenSaver /org/xfce/ScreenSaver \
        org.xfce.ScreenSaver GetActive
}
identity() {
    cat /proc/sys/kernel/random/boot_id
    awk '{print $1, $22}' "/proc/$xfce/stat"
    loginctl show-session "$session" -p User -p Leader -p Seat -p Type
    "${asuser[@]}" busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus GetNameOwner s org.xfce.SessionManager
}
before=$(identity)
display_before=$(display_state)
[[ -n $display_before ]]
lock_before=$(screen_lock)
[[ $lock_before == 'b false' ]]
echo "SLEEP_GUEST_X11 before=same_display screensaver=${lock_before#b }"
[[ $(cat /sys/power/mem_sleep) == *'[s2idle]'* ]]
[[ $(busctl --system call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspend) == 's "yes"' ]]
trace=/sys/kernel/tracing
[[ $(findmnt -nro FSTYPE --mountpoint "$trace") == tracefs ]]
# The product kernel omits CONFIG_PM_SLEEP_DEBUG and its pm_wakeup_irq file.
# Trace the IRQ supplied to the same underlying kernel wakeup accounting.
echo 'p:y700_test/sleep_irq pm_system_irq_wakeup irq=%x0:u32' >> "$trace/kprobe_events"
echo 1 > "$trace/events/y700_test/sleep_irq/enable"
trap 'echo 0 > "$trace/events/y700_test/sleep_irq/enable"; echo "-:y700_test/sleep_irq" >> "$trace/kprobe_events"' EXIT
for pass in 1 2; do
    start=$(cat /sys/power/suspend_stats/success)
    fail=$(cat /sys/power/suspend_stats/fail)
    irq_before=$(irq_total)
    : > "$trace/trace"
    [[ -z $(cat "$rtc/wakealarm") ]]
    rtcwake -u -d rtc1 -m no -s 15
    [[ $(cat "$rtc/wakealarm") =~ ^[0-9]+$ ]]
    systemctl suspend
    for _ in {1..80}; do
        [[ $(cat /sys/power/suspend_stats/success) != "$start" ]] && break
        sleep .25
    done
    total=$(cat /sys/power/suspend_stats/success)
    wakeirq=$(sed -n 's/.*sleep_irq: .* irq=\([0-9]\+\)$/\1/p' "$trace/trace" | sort -u)
    irq_after=$(irq_total)
    echo "SLEEP_GUEST_KERNEL cycle=$pass before=$start after=$total wake_irq=$wakeirq rtc_irq=$irq"
    (( total == start + 1 && irq_after > irq_before ))
    [[ $(cat /sys/power/suspend_stats/fail) == "$fail" && $wakeirq == "$irq" ]]
    [[ -z $(cat "$rtc/wakealarm") ]]
    # Wait for logind to thaw user.slice before calling the user bus.
    for _ in {1..60}; do
        [[ $(busctl --system get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager PreparingForSleep) == 'b false' ]] && break
        sleep .2
    done
    [[ $(identity) == "$before" && $(loginctl show-session "$session" -p Active --value) == yes ]]
    [[ $(display_state) == "$display_before" ]]
    lock_after=$(screen_lock)
    [[ $lock_after == 'b true' ]]
    echo "SLEEP_GUEST_X11 cycle=$pass randr=same screensaver=${lock_after#b }"
    cmp /proc/sys/kernel/random/boot_id /home/y700/ram-trial-user-file.txt
    printf 'SLEEP_GUEST_RESUMED cycle=%d success=%d fail=%d irq=%s delta=%d session_and_owner=same\n' \
        "$pass" "$total" "$fail" "$wakeirq" "$((irq_after-irq_before))"
done
entries=$(journalctl -b -k -q -o cat --grep '^PM: suspend entry \(s2idle\)$' | wc -l)
exits=$(journalctl -b -k -q -o cat --grep '^PM: suspend exit$' | wc -l)
[[ $entries == 2 && $exits == 2 ]]
echo 'SLEEP_GUEST_PASS s2idle_entries=2 kernel_exits=2'
