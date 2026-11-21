#!/bin/bash
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
trap 'echo "MODULE_FAILURE line=$LINENO target=${name:-startup}"' ERR
grep -qw y700.module_test=1 /proc/cmdline
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
release=$(uname -r)
[[ $release == 7.3.4-asphalt-prc ]]
read -r mode image_hash expected_notes < /run/kernel.tsv
notes=$(sha256sum /sys/kernel/notes)
[[ ${notes%% *} == "$expected_notes" ]]
zcat /proc/config.gz > /run/running.config
grep -Fxq '# CONFIG_MODULE_SIG is not set' /run/running.config
grep -Fxq 'CONFIG_MODULE_UNLOAD=y' /run/running.config
[[ $(cat /proc/sys/kernel/tainted) == 0 ]]
printf 'MODULE_KERNEL mode=%s release=%s image_sha256=%s notes_sha256=%s module_sig=disabled kmod=%s\n' \
    "$mode" "$release" "$image_hash" "${notes%% *}" "$(dpkg-query -W -f='${Version}' kmod)"
targets=/run/modules.tsv
count=$(wc -l < "$targets")
[[ $count == 14 ]]
for round in 1 2; do
    while read -r name _; do test ! -d "/sys/module/$name"; done < "$targets"
    echo "<6>Y700_MODULE_LOAD_START_$round" > /dev/kmsg
    while read -r name hash relative; do
        path=$(modinfo -n "$name")
        [[ $(realpath -e "$path") == "/usr/lib/modules/$release/$relative" ]]
        modprobe -C /dev/null "$name"
        node="/sys/module/$name"
        [[ $(cat "$node/initstate") == live && -z $(cat "$node/taint") ]]
        printf '%s  %s/notes/.note.gnu.build-id\n' "$hash" "$node" | sha256sum --strict --quiet -c -
    done < "$targets"
    # All 14 must coexist before the first removal. Remove leaf modules in holder order.
    while read -r name _; do grep -Fxq live "/sys/module/$name/initstate"; done < "$targets"
    removed=0
    while (( removed < count )); do
        previous=$removed
        while read -r name _; do
            node="/sys/module/$name"
            [[ -d $node && -z $(ls -A "$node/holders") ]] || continue
            rmmod "$name"
            test ! -e "$node"
            ((removed += 1))
        done < "$targets"
        (( removed > previous ))
    done
    dmesg --raw | awk -v marker="Y700_MODULE_LOAD_START_$round" 'index($0,marker){seen=1} seen' > /run/module-messages
    grep -Fq "Y700_MODULE_LOAD_START_$round" /run/module-messages
    # raw dmesg prefixes contain the syslog facility and severity. Severity 0–4 is warning or worse.
    awk 'match($0,/^<[0-9]+>/) && (substr($0,2,RLENGTH-2) % 8 <= 4)' /run/module-messages > /run/module-warnings
    if [[ -s /run/module-warnings ]]; then cat /run/module-warnings; exit 1; fi
    [[ $(cat /proc/sys/kernel/tainted) == 0 ]]
    printf 'MODULE_ROUND round=%s loaded=%s live_build_ids=%s removed=%s warnings=0 taint=0\n' "$round" "$count" "$count" "$removed"
done
echo 'MIC_MODULES_PASS rounds=2 targets=14'
