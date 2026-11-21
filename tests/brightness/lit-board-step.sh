#!/bin/bash
# One 102 -> 122 -> 102 test on an already enabled internal display.
# The adjacent read-only lit-board.sh checks the chip after every transition.
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
[[ $EUID == 0 ]]
self=$(realpath -e "$0")
observer=${self%/*}/lit-board.sh
stage=${self%/*}
[[ $stage == /run/* && -f $observer && ! -L $observer ]]
# The transient restore service will reopen this script as root.
for path in "$self" "$observer"; do
    while [[ $path != /run ]]; do
        read -r owner_id mode < <(stat -c '%u %a' "$path")
        [[ $owner_id == 0 ]] && (( (8#$mode & 022) == 0 )) || exit 1
        path=${path%/*}
    done
done
bl=/sys/class/backlight/ktz8866-backlight
login=org.freedesktop.login1
boot=$(cat /proc/sys/kernel/random/boot_id)
sid=$(loginctl show-seat seat0 -p ActiveSession --value)
[[ $sid =~ ^[[:alnum:]]+$ ]]
property() { loginctl show-session "$sid" -p "$1" --value; }
[[ $(property Active) == yes && $(property Remote) == no && $(property Type) == x11 && $(property Seat) == seat0 ]]
owner=$(property Name)
class=$(property Class)
case "$class:$owner" in
    greeter:lightdm) ;;
    user:y700) [[ $(property LockedHint) == no ]] ;;
    *) echo 'Unexpected foreground session' >&2; exit 1 ;;
esac
uid=$(id -u "$owner"); gid=$(id -g "$owner")
[[ $uid != 0 && $uid == "$(property User)" ]]
reply=$(busctl --system call "$login" /org/freedesktop/login1 "$login.Manager" GetSession s "$sid")
[[ $reply =~ ^o\ \"(/org/freedesktop/login1/session/[A-Za-z0-9_]+)\"$ ]]
object=${BASH_REMATCH[1]}
same_seat() {
    [[ $boot == "$(cat /proc/sys/kernel/random/boot_id)" && $sid == "$(loginctl show-seat seat0 -p ActiveSession --value)" &&
       $owner == "$(property Name)" && $class == "$(property Class)" && $(property Active) == yes ]]
}
set_level() {
    same_seat || return 1
    setpriv --reuid="$uid" --regid="$gid" --init-groups --no-new-privs \
        busctl --system --timeout=4s --allow-interactive-authorization=no call \
        "$login" "$object" "$login.Session" SetBrightness ssu backlight ktz8866-backlight "$1"
}
restore() {
    case "$(cat "$bl/brightness")" in
        102) return 0 ;;
        122) set_level 102 && [[ $(cat "$bl/brightness") == 102 ]] ;;
        *) echo 'Another brightness request is present; leaving it intact.' >&2; return 1 ;;
    esac
}
if [[ ${1:-} == --restore ]]; then
    [[ $# == 4 && $2 == "$boot" && $3 == "$sid" && $4 == "$uid" ]]
    restore
    exit
fi
[[ $# == 1 && $1 == --step ]] || { echo 'Usage: lit-board-step.sh --step' >&2; exit 2; }
bash "$observer" --expect-lit 102
unit=y700-lit-backlight-$BASHPID
systemd-run --quiet --collect --on-active=25s --unit="$unit" -p RuntimeMaxSec=8s \
    /bin/bash "$self" --restore "$boot" "$sid" "$uid"
systemctl is-active --quiet "$unit.timer"
cleanup() {
    local rc=$?
    trap - EXIT HUP INT TERM
    if same_seat && restore; then systemctl stop "$unit.timer" || rc=1
    else rc=1; fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
printf 'KTZ_STEP_LOGIND seat=seat0 class=%s uid=%s starting=102 target=122 fallback=25s\n' "$class" "$uid"
set_level 122
bash "$observer" --expect-lit 122
restore
bash "$observer" --expect-lit 102
same_seat
echo 'KTZ_STEP_VERIFIED returned=102 programmed=102 write_via=logind'
