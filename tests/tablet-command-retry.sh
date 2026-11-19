#!/bin/bash
# A harmless synthetic failure followed by real authenticated device checks.
set -eu
printf 'attempt=%s\n' "$Y700_TEST_ATTEMPT"
if [[ $Y700_TEST_ATTEMPT == 1 ]]; then
    echo "Injected temporary failure"
    exit 75
fi
[[ $Y700_TEST_ATTEMPT == 2 ]]
for service in ssh.service lightdm.service asphalt-usb-maintenance.service; do
    systemctl is-active "$service"
done
cat /etc/debian_version
cat /proc/sys/kernel/random/boot_id
sha256sum /sys/kernel/notes
test -c /dev/dri/renderD128
