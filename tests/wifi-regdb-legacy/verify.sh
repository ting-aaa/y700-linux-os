#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
grep -qw y700.regdb_legacy=1 /proc/cmdline
tr '\000' '\n' </proc/device-tree/compatible | grep -Fxq linux,dummy-virt
[[ $(cat /sys/block/vda/ro) == 1 ]]
unit=y700-wireless-regdb.service
unit_path=/etc/systemd/system/$unit
stage=/opt/regdb-test
upstream=/lib/firmware/regulatory.db-upstream
get() { systemctl show "$1" -p "$2" --value; }
trap 'printf "REGDB_LEGACY_CHECK_FAILED line=%s\n" "$LINENO" >&2' ERR

case ${1:-} in
    prepare)
        [[ ! -e /usr/sbin/iw && ! -e $unit_path ]]
        update-alternatives --query regulatory.db > "$stage/alternatives.before"
        grep -Fxq 'Status: auto' "$stage/alternatives.before"
        grep -Fxq 'Value: /lib/firmware/regulatory.db-debian' "$stage/alternatives.before"
        test -z "$(dpkg --audit)"
        dpkg -i "$stage/iw.deb"
        update-alternatives --set regulatory.db "$upstream"
        for file in regulatory.db regulatory.db.p7s; do
            [[ $(realpath -e "/lib/firmware/$file") == "/usr/lib/firmware/$file-upstream" ]]
        done
        install -m644 "$stage/$unit" "$unit_path"
        systemctl --root=/ enable "$unit"
        ;;
    verify)
        [[ -e /sys/module/cfg80211 ]]
        early=$(dmesg | grep -E 'failed to load regulatory\.db .*\(-2\)|Direct firmware load for regulatory\.db failed with error -2')
        printf '%s\n' "$early"
        iw_version=$(dpkg-query -W -f='${Version}' iw)
        [[ $iw_version == '6.9-1+b1' && -z $(iw dev) ]]
        [[ $(get "$unit" ActiveState) == active && $(get "$unit" SubState) == exited ]]
        [[ $(get "$unit" Result) == success && $(get "$unit" ExecMainStatus) == 0 ]]
        [[ $(get NetworkManager.service ActiveState) == active ]]
        regdb_time=$(get "$unit" ActiveEnterTimestampMonotonic)
        nm_time=$(get NetworkManager.service ActiveEnterTimestampMonotonic)
        [[ $regdb_time =~ ^[1-9][0-9]*$ && $nm_time =~ ^[1-9][0-9]*$ ]]
        (( regdb_time < nm_time ))
        printf 'REGDB_LEGACY_PASS early_enoent=1 service_exit=0 regdb_active_us=%s nm_active_us=%s radio_count=0\n' "$regdb_time" "$nm_time"

        cmp "$stage/$unit" "$unit_path"
        systemctl disable --now "$unit"
        rm -- "$unit_path"
        systemctl daemon-reload
        [[ $(readlink /etc/alternatives/regulatory.db) == "$upstream" ]]
        update-alternatives --auto regulatory.db
        update-alternatives --query regulatory.db | cmp "$stage/alternatives.before" -
        dpkg --remove iw
        [[ ! -e /usr/sbin/iw && ! -e $unit_path ]]
        [[ $(get "$unit" LoadState) == not-found && $(get NetworkManager.service ActiveState) == active ]]
        test -z "$(dpkg --audit)"
        echo 'REGDB_LEGACY_ROLLBACK alternatives_auto=1 unit_removed=1 iw_absent=1'
        systemctl --no-block poweroff
        ;;
    *) exit 2 ;;
esac
