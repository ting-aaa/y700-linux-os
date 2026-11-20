#!/usr/bin/env bash
# Observe a synthetic file-trial desktop. All bus calls target the bus daemon;
# none activates Onboard or changes the live session.
set -u
export LC_ALL=C
[[ $(id -u) == 0 ]] && grep -qw y700.file_probe=1 /proc/cmdline &&
    grep -zFxq linux,dummy-virt /proc/device-tree/compatible || exit 2

uid=$(id -u y700) || exit 1
home=$(getent passwd y700 | cut -d: -f6)
runtime=/run/user/$uid
canonical=unix:path=$runtime/bus

env_of() {
    local pid=$1 key=$2
    tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n "s/^$key=//p" | head -n1
}
observe_bus() {
    local label=$1 addr=$2 class=other method reply
    if [[ -z $addr ]]; then echo "ONBOARD_DIAG_BUS observer=$label absent=1"; return; fi
    [[ $addr != "$canonical" && $addr != "$canonical,"* ]] || class=runtime
    # Do not let an unset address fall through to X11 autolaunch.
    case "$addr" in unix:*) ;; *) echo "ONBOARD_DIAG_BUS observer=$label address_type=other"; return;; esac
    for method in GetId NameHasOwner GetConnectionUnixProcessID; do
        args=()
        [[ $method == GetId ]] || args=(org.onboard.Onboard)
        if reply=$(timeout 4 setpriv --reuid="$uid" --regid="$(id -g y700)" --init-groups env \
            XDG_RUNTIME_DIR="$runtime" HOME="$home" gdbus call --address "$addr" --timeout 2 \
            --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
            --method "org.freedesktop.DBus.$method" "${args[@]}" 2>/dev/null); then
            printf 'ONBOARD_DIAG_BUS observer=%s address=%s method=%s result=%s\n' "$label" "$class" "$method" "$reply"
        else
            echo "ONBOARD_DIAG_BUS observer=$label address=$class method=$method failed=1"
        fi
    done
}

echo 'ONBOARD_DIAG_BEGIN'
observe_bus canonical "$canonical"
for name in xfce4-session xfce4-panel onboard; do
    while read -r pid; do
        [[ -n $pid && -r /proc/$pid/status ]] || continue
        printf 'ONBOARD_DIAG_PROCESS name=%s pid=%s state=%s display=%s desktop=%s\n' \
            "$name" "$pid" "$(awk '$1=="State:"{print $2}' "/proc/$pid/status")" \
            "$(env_of "$pid" DISPLAY)" "$(env_of "$pid" XDG_CURRENT_DESKTOP)"
        observe_bus "$name-$pid" "$(env_of "$pid" DBUS_SESSION_BUS_ADDRESS)"
    done < <(pgrep -u "$uid" -x "$name")
done
printf 'ONBOARD_DIAG_COUNTS user=%d greeter=%d\n' \
    "$(pgrep -cu "$uid" -x onboard)" "$(pgrep -cu lightdm -x onboard)"
for item in /etc/xdg/autostart/{onboard-autostart,y700-onboard}.desktop \
                 "$home/.config/autostart/"{onboard-autostart,y700-onboard}.desktop; do
    [[ -f $item ]] || continue
    echo "ONBOARD_DIAG_AUTOSTART $item"
    grep -E '^(Type|Exec|OnlyShowIn|NotShowIn|Hidden|AutostartCondition)=' "$item"
done
messages='[Oo]nboard|Traceback|[[:alnum:]]Error:|Segmentation fault|Gdk-CRITICAL|Gtk-WARNING|D-Bus session bus unavailable|not the primary instance'
if [[ -r $home/.xsession-errors ]]; then
    echo 'ONBOARD_DIAG_XSESSION'
    grep -aEi "$messages" "$home/.xsession-errors" | tail -n 30
fi
echo 'ONBOARD_DIAG_USER_JOURNAL'
journalctl -b -q --no-pager -o cat "_UID=$uid" | grep -aEi "$messages" | tail -n 30
echo 'ONBOARD_DIAG_COREDUMP'
printf 'handler=%s systemd_collector=%s\n' "$(cat /proc/sys/kernel/core_pattern)" \
    "$([[ -x /usr/lib/systemd/systemd-coredump ]] && echo installed || echo absent)"
find "$home" -maxdepth 2 -type f \( -name core -o -name 'core.*' \) -printf 'core_file=%P size=%s\n'
journalctl -b -q --no-pager -o short-monotonic "COREDUMP_UID=$uid" | grep -aEi 'onboard|python' | head -c 2200
echo 'ONBOARD_DIAG_END'
