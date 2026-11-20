#!/usr/bin/env bash
set -euo pipefail
stage=${1:?private staging directory}
version=${2:?expected Blueman version}
[[ $stage =~ ^/var/tmp/y700-blueman-tablet\.[a-zA-Z0-9]{8}$ ]]
test "$(realpath -e "$stage")" = "$stage"
test "$(id -u)" = 0
test "$(dpkg-query -W -f='${Version}' blueman)" = "$version"
test -z "$(dpkg -V blueman)"

snapshot() {
    local session
    cat /proc/sys/kernel/random/boot_id
    for unit in bluetooth.service ssh.service lightdm.service; do
        test "$(systemctl is-active "$unit")" = active || return 1
        systemctl show "$unit" -p MainPID -p InvocationID
    done
    session=$(loginctl show-seat seat0 -p ActiveSession --value)
    test -n "$session" || return 1
    test "$(loginctl show-session "$session" -p Name --value)" = y700 || return 1
    test "$(loginctl show-session "$session" -p Active --value)" = yes || return 1
    loginctl show-session "$session" -p Id -p Name -p Active -p Leader -p Type -p State
    ps -u y700 -o pid=,comm=,args= | awk \
        '$2 ~ /^(xfce4-session|xfwm4|xfce4-panel|onboard|blueman-applet)$/ || ($2 ~ /^python/ && $0 ~ /\/usr\/bin\/blueman-applet/) {print $1, $2}' \
        | LC_ALL=C sort
    for dir in /tmp /run /sys /dev; do findmnt -rn -o TARGET,FSTYPE,OPTIONS --target "$dir"; done
}

if ps -e -o comm= | grep -Eq 'glmark|vkmark|vkcube|fd730|adreno|gpu-trial|freedreno'; then
    echo 'BLUEMAN_TABLET_GPU_BUSY'
    exit 3
fi
before=$(snapshot)
echo 'BLUEMAN_TABLET_PREFLIGHT gpu_workloads=0 seat0_active_y700=1 installed_files_verified=1'
for kind in mnt net pid; do readlink "/proc/self/ns/$kind" > "$stage/host.$kind"; done
status=0
timeout -k 5 130 unshare --mount --net --pid --fork --kill-child --mount-proc \
    bash "$stage/tablet-namespace.sh" "$stage" "$version" || status=$?
after=$(snapshot)
test "$after" = "$before"
for kind in mnt net pid; do
    test -s "$stage/test.$kind"
    target=$(cat "$stage/test.$kind")
    for handle in /proc/[0-9]*/ns/"$kind"; do
        [[ $(readlink "$handle" 2>/dev/null || true) != "$target" ]]
    done
done
echo 'BLUEMAN_TABLET_PRESERVED boot=1 bluetooth_service=1 ssh_service=1 lightdm_service=1 seat=1 desktop_processes=1 mount_table=1'
echo 'BLUEMAN_TABLET_NAMESPACE_CLEANUP isolated_processes=0'
exit "$status"
