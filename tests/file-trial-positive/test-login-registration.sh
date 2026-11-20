#!/usr/bin/env bash
# Simulate the logind registration gap and a failing observer subprocess.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
work=$(mktemp -d)
cleanup() {
    rm -f -- "$work"/{augment.awk,observer.sh,trap.sh,pam.sh,poweroff}
    rmdir -- "$work"
}
trap cleanup EXIT
awk '/^awk \047$/ {p=1; next} p && /^\047 / {exit} p{print}' "$here/run.sh" > "$work/augment.awk"
awk -f "$work/augment.awk" "$here/../combined-efi/observe.sh" > "$work/observer.sh"
sed -n '/^observer_pid=/,+1p' "$work/observer.sh" | sed 's|/dev/kmsg|/dev/null|' > "$work/trap.sh"
sed -n '1,/^login_timeout()/p' "$here/check-login-stage.sh" | sed '$d;s/^uid=.*/uid=1000/' > "$work/pam.sh"

bash -s -- "$work" <<'MOCK'
set -Eeuo pipefail
work=$1
systemctl() { echo called >> "$work/poweroff"; }
source "$work/trap.sh"
source "$work/pam.sh"
registered=0
loginctl() {
    if [[ $1 == show-user ]]; then
        if (( registered )); then echo 2; else return 1; fi
    else
        printf '%s\n' User=1000 Name=y700 Service=lightdm Class=user Seat=seat0 Remote=no Type=x11
    fi
}
inherited_failure() { for unused in $(false); do :; done; return 1; }
if inherited_failure; then exit 2; fi
if pam_started; then exit 3; fi
registered=1
pam_started
[[ $pam_session == 2 && ! -e $work/poweroff ]]
MOCK

# A failure in the main observer must still request the mock power-off.
if bash -s -- "$work" <<'MOCK'; then exit 1; fi
set -Eeuo pipefail
work=$1
systemctl() { echo called >> "$work/poweroff"; }
source "$work/trap.sh"
false
MOCK
[[ $(cat "$work/poweroff") == called ]]
echo FILE_TRIAL_LOGIND_REGISTRATION_RACE_PASS
