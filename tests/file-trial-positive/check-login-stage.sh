# Sourced by the guest observer after the greeter. The private host port sends
# only a phase marker after the password's touchscreen submit was acknowledged.
uid=$(id -u y700)
pam_session=
pam_started() {
    local id data sessions
    sessions=$(loginctl show-user "$uid" -p Sessions --value 2>/dev/null) || return 1
    for id in $sessions; do
        data=$(loginctl show-session "$id" -p User -p Name -p Service -p Class -p Seat -p Remote -p Type 2>/dev/null) || continue
        if grep -Fxq "User=$uid" <<<"$data" && grep -Fxq 'Name=y700' <<<"$data" &&
           grep -Fxq 'Service=lightdm' <<<"$data" && grep -Fxq 'Class=user' <<<"$data" &&
           grep -Fxq 'Seat=seat0' <<<"$data" && grep -Fxq 'Remote=no' <<<"$data" && grep -Fxq 'Type=x11' <<<"$data"; then
            pam_session=$id
            return 0
        fi
    done
    return 1
}

login_timeout() {
    local stage=$1 name present lightdm pam=0 active=0 state
    lightdm=$(systemctl is-active lightdm || :)
    if pam_started; then
        pam=1
        if [[ $(loginctl show-session "$pam_session" -p Active --value) == yes ]]; then active=1; fi
    fi
    printf -v state 'FILE_TRIAL_STAGE_TIMEOUT stage=%s lightdm=%s ordinary_pam=%s active=%s' "$stage" "$lightdm" "$pam" "$active"
    printf '%s\n' "$state"
    printf '<5>%s\n' "$state" > /dev/kmsg || :
    for name in xfce4-session xfwm4 xfce4-panel xfdesktop; do
        present=0
        if pgrep -u "$uid" -x "$name" >/dev/null; then present=1; fi
        printf 'FILE_TRIAL_STAGE_PROCESS name=%s present=%s\n' "$name" "$present"
    done
    echo "COMBINED_FAIL timeout=$stage"
    return 1
}

wait_for 25 login-phase-port test -c /dev/virtio-ports/org.y700.login-phase
exec 9<>/dev/virtio-ports/org.y700.login-phase
if ! IFS= read -r -t 670 submitted <&9 || [[ $submitted != LOGIN_SUBMITTED ]]; then
    login_timeout touch-submit
fi
exec 9>&-
submit_time=$SECONDS
echo 'FILE_TRIAL_TOUCH_SUBMITTED acknowledged=1'
if ! wait_for 120 ordinary-pam pam_started >/dev/null; then login_timeout ordinary-pam; fi
printf 'FILE_TRIAL_PAM_SESSION ordinary=1 service=lightdm seat=seat0 type=x11 elapsed=%ss\n' "$((SECONDS - submit_time))"
pam_time=$SECONDS
