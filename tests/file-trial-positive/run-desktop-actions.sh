# Sourced by the guest observer after Xfce and the ordinary seat0 session match.
unset DISPLAY XAUTHORITY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
while IFS= read -r -d '' entry; do
    case "$entry" in
        DISPLAY=*|XAUTHORITY=*|XDG_RUNTIME_DIR=*|DBUS_SESSION_BUS_ADDRESS=*) export "$entry" ;;
    esac
done < "/proc/$pid/environ"
export Y700_QA_SESSION_PID=$pid Y700_QA_SESSION_ID=$sid Y700_QA_UID=$uid

if [[ ! -v XAUTHORITY ]]; then
    user_home=$(getent passwd "$uid" | cut -d: -f6)
    authority=$user_home/.Xauthority
    if [[ -n $user_home && -f $authority && $(stat -c %u "$authority") == "$uid" ]]; then
        # The user would otherwise resolve this same file implicitly via HOME.
        export XAUTHORITY=$authority
    fi
fi
echo 'FILE_TRIAL_DESKTOP_ACTIONS status=started'
result=1
if [[ -n ${DISPLAY:-} && -d ${XDG_RUNTIME_DIR:-} && ${DBUS_SESSION_BUS_ADDRESS:-} == unix:* ]]; then
    if timeout -k 8 850 /bin/bash /run/y700-file-qa/desktop-actions.sh; then
        result=0
    else
        result=$?
    fi
else
    echo 'FILE_TRIAL_DESKTOP_ACTIONS_DETAIL reason=session-environment-unavailable'
fi
if (( result == 0 )); then
    echo 'FILE_TRIAL_DESKTOP_ACTIONS status=passed exit=0'
else
    printf 'FILE_TRIAL_DESKTOP_ACTIONS status=failed exit=%d\n' "$result"
fi
