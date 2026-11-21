#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077
payload=/run/y700-af-acm
cd "$payload"
[[ $EUID == 0 && $(cat /proc/1/comm) == systemd ]]
sha256sum --strict --quiet -c SHA256SUMS
grep -Fxq IMAGE_VERSION=dev12.12 /etc/os-release
printf '%s  /sys/kernel/notes\n' c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063 | sha256sum --strict --quiet -c -
virt=0
if grep -zFxq linux,dummy-virt /proc/device-tree/compatible; then
    grep -qw y700.ram_af_virtual=1 /proc/cmdline
    virt=1
else
    grep -zFxq lenovo,asphalt /proc/device-tree/compatible
    [[ $(tr -d '\0' </proc/device-tree/region_country) == PRC ]]
    ! grep -qw y700.ram_af_virtual=1 /proc/cmdline || exit 1
fi
healthy() {
    local base=/run/y700-ram options name loop
    for name in y700.media=ram y700.ram_af_acm=1 fstab=no noresume systemd.gpt_auto=0; do
        grep -qw "$name" /proc/cmdline || return 1
    done
    if (( ! virt )); then
        for name in ufshc@1d84000 mmc@8804000; do
            [[ $(tr -d '\0' <"/proc/device-tree/soc@0/$name/status") == disabled ]] || return 1
        done
    fi
    [[ $(wc -l </proc/swaps) == 1 && $(findmnt -nro FSTYPE /) == overlay ]] || return 1
    ! findmnt -n --mountpoint /boot >/dev/null || return 1
    for name in /sys/class/block/*; do [[ ${name##*/} =~ ^(loop|ram|zram)[0-9]+$ ]] || return 1; done
    options=,$(findmnt -nro OPTIONS /),
    for name in rw "lowerdir=$base/lower" "upperdir=$base/changes/upper" "workdir=$base/changes/work"; do
        [[ $options == *",$name,"* ]] || return 1
    done
    [[ $(findmnt -nro FSTYPE --mountpoint "$base/changes") == tmpfs && $(findmnt -nro FSTYPE -T "$payload") == tmpfs ]] || return 1
    for name in carrier lower; do
        loop=$(findmnt -nro SOURCE --mountpoint "$base/$name") || return 1
        [[ $loop =~ ^/dev/loop[0-9]+$ && $(blockdev --getro "$loop") == 1 ]] || return 1
        [[ ,$(findmnt -nro OPTIONS --mountpoint "$base/$name"), == *,ro,* ]] || return 1
    done
    [[ $(findmnt -nro FSTYPE --mountpoint "$base/carrier") == squashfs && $(findmnt -nro FSTYPE --mountpoint "$base/lower") == ext4 ]] || return 1
    [[ $(findmnt -nro UUID --mountpoint "$base/lower") == 171a4adb-916b-4763-9e6f-722b4a99988f ]] || return 1
}
healthy
returning=0
if (( ! virt )) || [[ -e $payload/return-origin ]]; then
    systemctl is-active --quiet y700-ram-af-return.timer
    origin=$(cat "$payload/return-origin")
    [[ $origin =~ ^[0-9]+$ ]]
    returning=1
fi
stage=$(mktemp -d /run/y700-af-optical.XXXXXXXX)
chmod 0755 "$stage"
install -m755 y700-af-measure measure-board.sh "$stage"
install -m644 libcamera.so.0.7 "$stage"
g=/sys/kernel/config/usb_gadget/y700-ram-af
own=0
cleanup() {
    if (( own )); then
        if [[ -n $(cat "$g/UDC") ]]; then printf '\n' > "$g/UDC"; fi
        rm -f -- "$g/configs/c.1/acm"
        rmdir "$g/functions/acm.qa" "$g/configs/c.1" "$g/strings/0x409" "$g" 2>/dev/null || :
    fi
    rm -f -- "$stage/y700-af-measure" "$stage/measure-board.sh" "$stage/libcamera.so.0.7"
    rmdir "$stage"
}
trap cleanup EXIT
if (( virt )); then
    port=/dev/virtio-ports/org.y700.ram-af
    for _ in {1..60}; do [[ ! -c $port ]] || break; sleep .5; done
else
    modprobe libcomposite
    for _ in {1..60}; do [[ ! -e /sys/class/udc/a600000.usb ]] || break; sleep .5; done
    [[ -e /sys/class/udc/a600000.usb && ! -e $g ]]
    for other in /sys/kernel/config/usb_gadget/*/UDC; do [[ ! -f $other || -z $(cat "$other") ]]; done
    mkdir "$g"; own=1
    echo 0x18d1 > "$g/idVendor"; echo 0x4e11 > "$g/idProduct"; echo 0x0704 > "$g/bcdDevice"
    echo 0xef > "$g/bDeviceClass"; echo 0x02 > "$g/bDeviceSubClass"; echo 0x01 > "$g/bDeviceProtocol"
    mkdir "$g/strings/0x409" "$g/configs/c.1" "$g/functions/acm.qa"
    echo 'Y700 Linux OS' > "$g/strings/0x409/manufacturer"
    echo 'Y700 RAM camera diagnostics' > "$g/strings/0x409/product"
    echo Y700_RAM_AF > "$g/strings/0x409/serialnumber"
    ln -s "$g/functions/acm.qa" "$g/configs/c.1/acm"; echo a600000.usb > "$g/UDC"
    port=/dev/ttyGS$(cat "$g/functions/acm.qa/port_num")
    udevadm settle --timeout=10
    ! systemctl is-active --quiet "serial-getty@${port##*/}.service" || exit 1
fi
[[ -c $port ]]
export Y700_AF_DIAGNOSTICS=1
run_measurement() {
    if (( virt )); then
        # The QEMU transport can only exercise synthetic data with no camera devices.
        systemd-run --quiet --wait --collect --pipe --uid=y700 -p PrivateDevices=yes -p PrivateNetwork=yes \
            -p ProtectSystem=strict -p ProtectHome=yes -p NoNewPrivileges=yes -p LimitCORE=0 -p RuntimeMaxSec=70s \
            --setenv="LD_LIBRARY_PATH=$stage:/opt/y700-camera/lib" "$stage/y700-af-measure" --self-test
    else
        /bin/bash "$stage/measure-board.sh" "$1" "$stage/y700-af-measure"
    fi
}
if (( ! virt )); then stty -F "$port" raw -echo clocal; fi
exec 3<> "$port"
token=$(tr -d - </proc/sys/kernel/random/uuid)
state=BLOCKED
test_result=failed
if run_measurement --self-test > "$payload/self-test.log" 2>&1 &&
    grep -Fxq 'AF_RESULT self_test=pass synthetic=1 camera_access=0' "$payload/self-test.log" &&
    { (( virt )) || grep -Fxq 'AF_CLEANUP mode=--self-test rear=suspended sensor_active_ms_delta=0 exit=0' "$payload/self-test.log"; }; then
    state=READY
    test_result=pass
fi
# Capture receipts even when the PC closes its port. A blocked/disconnected writer cannot stop the measurement.
send_line() { timeout -k 1 1 /usr/bin/printf '%s\n' "$*" >&3 2>/dev/null; }
publish() { send_line "$*" || :; }
status() { publish "AF1 $state $token storage=none swap=none root=ram selftest=$test_result virtual=$virt"; }
deadline=$((SECONDS+1200))
while (( SECONDS < deadline )); do
    if IFS= read -r -t 2 -n 128 command <&3; then :
    else
        read_status=$?
        if (( read_status == 1 && ! virt )); then exec 3<> "$port"; fi
        sleep .2; continue
    fi
    case $command in
        STATUS) status ;;
        "RESULT $token")
            if [[ $state != DONE ]]; then publish 'AF1 REFUSED result_unavailable'; continue; fi
            while IFS= read -r line; do send_line "$line" || break; done < "$payload/result" ;;
        "ACK $token "*)
            if [[ $state != DONE || $returning != 1 || $command != "ACK $token $digest" ]]; then
                publish 'AF1 REFUSED acknowledgement'; continue
            fi
            systemctl start y700-ram-af-ack.timer
            publish 'AF1 RETURN acknowledged=1' ;;
        "START $token")
            if [[ $state == BLOCKED ]]; then publish 'AF1 REFUSED selftest'; continue; fi
            if [[ $state != READY || -d $payload/consumed ]]; then publish 'AF1 REFUSED consumed'; continue; fi
            if (( returning )) && (( $(cut -d. -f1 /proc/uptime) - origin >= 540 )); then
                publish 'AF1 REFUSED return_pending'; continue
            fi
            if ! healthy; then publish 'AF1 REFUSED storage'; exit 1; fi
            mkdir "$payload/consumed"
            state=RUNNING
            publish "AF1 RUNNING $token virtual=$virt"
            set +e
            : > "$payload/result"
            run_measurement --rear-af 2>&1 | /bin/bash "$payload/filter.sh" | {
                connected=1
                while IFS= read -r line; do
                    printf '%s\n' "$line" >> "$payload/result" || exit 1
                    if (( connected )); then send_line "$line" || connected=0; fi
                done
            }
            codes=("${PIPESTATUS[@]}")
            set -e
            rc=${codes[0]}; [[ ${codes[1]} == 0 && ${codes[2]} == 0 ]] || rc=1
            if (( virt )); then
                echo 'AF_TEST virtual=1 camera_access=0' >> "$payload/result"; publish 'AF_TEST virtual=1 camera_access=0'
            elif ! grep -q '^AF_CLEANUP mode=--rear-af rear=suspended ' "$payload/result"; then rc=1; fi
            printf 'AF1 END rc=%s\n' "$rc" >> "$payload/result"
            digest=$(sha256sum "$payload/result" | cut -d' ' -f1)
            publish "AF1 END rc=$rc"
            state=DONE ;;
        *) publish 'AF1 REFUSED command' ;;
    esac
done
