#!/usr/bin/env bash
set -euo pipefail
mode=$1 sid=$2 desktop=$3
uid=$(id -u y700)
runtime=/run/user/$uid
user=(setpriv --reuid="$uid" --regid="$(id -g y700)" --init-groups
      env HOME=/home/y700 USER=y700 LOGNAME=y700 XDG_CURRENT_DESKTOP=XFCE
      XDG_SESSION_ID="$sid" XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus")
while IFS= read -r -d '' setting; do
    case "$setting" in DISPLAY=*|XAUTHORITY=*) user+=("$setting");; esac
done <"/proc/$desktop/environ"
if [[ $mode == baseline ]]; then
    rc=0
    timeout 20 "${user[@]}" xflock4 || rc=$?
    sleep 6
    active=$(loginctl show-session "$sid" -p Active --value)
    hint=$(loginctl show-session "$sid" -p LockedHint --value)
    greeter=no
    if pgrep -u lightdm -x arctica-greeter >/dev/null; then greeter=yes; fi
    printf 'SCREEN_LOCK_BASELINE xflock4_exit=%s active=%s locked_hint=%s greeter=%s\n' "$rc" "$active" "$hint" "$greeter"
    exit
fi
[[ $mode == candidate ]]
wait_for() {
    local max=$1 label=$2 end
    shift 2
    end=$((SECONDS + max))
    until "$@"; do
        if (( SECONDS > end )); then echo "Lock timeout: $label" >&2; return 1; fi
        sleep .4
    done
}
session_active() {
    "${user[@]}" gdbus call --session --dest org.xfce.ScreenSaver --object-path /org/xfce/ScreenSaver \
        --method org.xfce.ScreenSaver.GetActive | grep -Fxq "($1,)"
}
state=$(mktemp -d "$runtime/lock-proof.XXXXXXXX")
chown "$uid:$(id -g y700)" "$state"
probe=("${user[@]}" /run/y700-lock-test-uv run --offline --no-project --python /usr/bin/python3 \
       python /run/y700-lock-witness.py)
"${probe[@]}" draft "$state" >"$state/gtk.log" 2>&1 &
witness_job=$!
trap 'kill "$witness_job" 2>/dev/null || :' EXIT
wait_for 50 draft test -s "$state/draft"
wait_for 20 draft-position test -s "$state/point"
read -r draft window < "$state/draft"
kill -0 "$draft" "$desktop"
wait_for 30 locker session_active false
for value in enabled displayed; do
    [[ $("${user[@]}" xfconf-query -c xfce4-screensaver -p "/lock/embedded-keyboard/$value") == true ]]
done
echo SCREEN_LOCK_DRAFT_READY
echo "SCREEN_LOCK_DRAFT_POINT $(cat "$state/point")"
button=$("${probe[@]}" button)
echo "SCREEN_LOCK_PANEL_BUTTON $button"
row=$("${probe[@]}" menu)
echo "SCREEN_LOCK_PANEL_ROW $row"
wait_for 80 lock session_active true
printf 'SCREEN_LOCK_STATE screensaver_active=true logind_locked_hint=%s\n' \
    "$(loginctl show-session "$sid" -p LockedHint --value)"
echo SCREEN_LOCK_ACTIVE
embedded() { pgrep -u "$uid" -f '/onboard .*--xid' >/dev/null; }
wait_for 85 embedded-keyboard embedded
pgrep -u "$uid" -f '/xfce4-screensaver-dialog' >/dev/null
auth_rejected() {
    journalctl -b --no-pager -q -o cat | grep -F 'pam_unix(xfce4-screensaver:auth): authentication failure' >/dev/null
}
if auth_rejected; then echo 'Unexpected earlier locker PAM failure' >&2; exit 1; fi
dialog=$(pgrep -o -u "$uid" -f '/xfce4-screensaver-dialog')
echo 'SCREEN_LOCK_DIALOG keyboard=embedded'
wait_for 100 wrong-password auth_rejected
session_active true
kill -0 "$draft" "$desktop"
echo SCREEN_LOCK_BAD_PASSWORD_REJECTED
printf 'SCREEN_LOCK_AUTH_STATE screensaver_active=true logind_locked_hint=%s\n' \
    "$(loginctl show-session "$sid" -p LockedHint --value)"
closed() { ! kill -0 "$dialog" 2>/dev/null && ! embedded; }
wait_for 70 cancel-dialog closed
session_active true
echo SCREEN_LOCK_CANCEL_STILL_LOCKED
reopened() {
    local new_dialog
    new_dialog=$(pgrep -o -u "$uid" -f '/xfce4-screensaver-dialog') && [[ $new_dialog != "$dialog" ]] && embedded
}
wait_for 70 reopened-dialog reopened
echo SCREEN_LOCK_PROMPT_READY_FOR_RETRY
wait_for 95 unlock session_active false
printf 'SCREEN_LOCK_STATE screensaver_active=false logind_locked_hint=%s\n' \
    "$(loginctl show-session "$sid" -p LockedHint --value)"
[[ $(loginctl show-session "$sid" -p Active --value) == yes ]]
[[ $(pgrep -o -u "$uid" -x xfce4-session) == "$desktop" ]]
[[ $(tr '\0' '\n' <"/proc/$desktop/environ" | sed -n 's/^XDG_SESSION_ID=//p') == "$sid" ]]
kill -USR1 "$draft"
wait_for 12 preserved-draft test -s "$state/resumed"
cmp "$state/draft" "$state/resumed"
echo SCREEN_LOCK_SAME_SESSION_DRAFT_RESTORED
