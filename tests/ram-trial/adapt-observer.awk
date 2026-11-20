# Use the sealed desktop gates with RAM-root topology and a private QA payload.
/^trap .*COMBINED_FAIL line=.* ERR$/ {
    print "observer_pid=$BASHPID"
    print "trap 'if [[ $BASHPID == \"$observer_pid\" ]]; then echo \"COMBINED_FAIL line=$LINENO\"; printf \"<5>RAM_TRIAL_OBSERVER_ERROR line=%s\\n\" \"$LINENO\" > /dev/kmsg || :; systemctl --no-block poweroff; fi' ERR"
    trap_count++
    next
}
/^    \[\[ \$\(uname -r\)/ {
    print "    [[ $(uname -r) == 7.3.4-asphalt-prc && $(cat /proc/1/comm) == systemd ]]"
    kernel_count++
    next
}
/^    \[\[ \$\(findmnt -nro SOURCE,FSTYPE \/\)/ {
    print "    /bin/bash /run/y700-ram-qa/check-root.sh"
    root_count++
    next
}
/^    \[\[ \$\(findmnt -nro UUID \/\)/ { next }
/^    echo "COMBINED_EFI / {
    print "    echo \"RAM_TRIAL_PACKAGES count=$count digest=${digest%% *} account=$account\""
    next
}
/^greeter\(\) / { print "greeter() { systemctl is-active --quiet lightdm; }"; next }
/^desktop\(\) / { print "source /run/y700-ram-qa/check-login-stage.sh"; stage_count++ }
/^wait_for 300 desktop desktop$/ {
    print "if ! wait_for 300 desktop desktop >/dev/null; then login_timeout xfce-ready; fi"
    next
}
/^\[\[ -n \$sid && \$uid != 0 \]\]$/ {
    print "[[ -n $sid && $uid != 0 && $sid == \"$pam_session\" ]]"
    next
}
/^echo .*COMBINED_PAM_XFCE / {
    print "printf 'RAM_TRIAL_XFCE_READY same_pam_session=1 elapsed=%ss\\n' \"$((SECONDS - pam_time))\""
}
/^asuser\(\) / {
    print "if [[ -f /run/y700-ram-qa/platform-tested.lock ]]; then bash /run/y700-ram-qa/check-volatile-desktop.sh; fi"
    print "if [[ -f /run/y700-ram-qa/check-sleep.sh ]]; then"
    print "    exec >/dev/ttyAMA0 2>&1"
    print "    bash /run/y700-ram-qa/check-sleep.sh"
    print "fi"
    print "echo RAM_TRIAL_PASS"
    print "systemctl --no-block poweroff"
    desktop_count++
    exit
}
{
    gsub("/boot/blueman-tested.lock", "/run/y700-ram-qa/blueman-tested.lock")
    gsub("/boot/platform-tested.lock", "/run/y700-ram-qa/platform-tested.lock")
    gsub("/boot/media-tested.lock", "/run/y700-ram-qa/media-tested.lock")
    gsub("/boot/lock-mode", "/run/y700-ram-qa/lock-mode")
    gsub("/boot/combined-", "/run/y700-ram-qa/combined-")
    print
}
END {
    if (trap_count != 1 || kernel_count != 1 || root_count != 1 || stage_count != 1 || desktop_count != 1)
        exit 1
}
