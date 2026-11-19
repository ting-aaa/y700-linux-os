#!/usr/bin/env bash
# Run as root on a usr-merged Linux host with bubblewrap and GNU coreutils.
set -euo pipefail
test "$(id -u)" = 0
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT
mkdir -p "$temp/proc/device-tree" "$temp/sys/class/bluetooth/hci12/device/of_node" "$temp/state"
# Keep the process-substitution descriptor path working inside the fixture.
ln -s /kernel-proc/self "$temp/proc/self"
printf 'qcom,wcn6855-bt\0' > "$temp/sys/class/bluetooth/hci12/device/of_node/compatible"
printf '02:00:00:00:12:34\n' > "$temp/state/address"
chmod 600 "$temp/state/address"
cat > "$temp/btmgmt" <<'MOCK'
#!/bin/bash
set -eu
test "$1" = --index && test "$2" = 12
status=0
read -rt 0.1 ignored || status=$?
# An open, silent stdin must time out. EOF returns 1 immediately.
[[ $status -gt 128 ]]
printf '%s\n' "$3" >> /state/calls
case "$3" in
    info)
        if [[ -e /state/pending ]]; then
            if [[ -e /state/first-readback ]]; then
                mv /state/pending /state/current
            else
                touch /state/first-readback
            fi
        fi
        printf '  addr %s version 11\n' "$(cat /state/current)"
        ;;
    config) printf '  missing options: public-address\n' ;;
    public-addr)
        test "$4" = "$(cat /state/address)"
        if [[ -e /state/delay-confirmation ]]; then
            printf '%s\n' "$4" > /state/pending
        elif [[ ! -e /state/refuse-confirmation ]]; then
            printf '%s\n' "$4" > /state/current
        fi
        ;;
    *) exit 2 ;;
esac
MOCK
chmod 755 "$temp/btmgmt"

run_helper() {
    bwrap --unshare-all --die-with-parent --clearenv --setenv PATH /mock:/usr/bin \
        --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
        --ro-bind /etc/alternatives /etc/alternatives --dev /dev --proc /kernel-proc \
        --ro-bind "$temp/proc" /proc --ro-bind "$temp/sys" /sys \
        --bind "$temp/state" /state --ro-bind "$temp/btmgmt" /mock/btmgmt \
        --ro-bind "$repo/packaging/root/usr/libexec/y700-bluetooth-identity" /helper \
        -- /bin/bash /helper /state/address
}

printf 'other,board\0' > "$temp/proc/device-tree/compatible"
run_helper
test ! -e "$temp/state/calls"

printf 'lenovo,asphalt\0qcom,sm8475\0' > "$temp/proc/device-tree/compatible"
chmod 644 "$temp/state/address"
if run_helper > "$temp/failure.log" 2>&1; then
    echo 'A non-private public address file was accepted.' >&2
    exit 1
fi
grep -Fq 'address file must be owned by root and private' "$temp/failure.log"
test ! -e "$temp/state/calls"
chmod 600 "$temp/state/address"

printf '02:00:00:00:56:78\n' > "$temp/state/current"
run_helper
test "$(cat "$temp/state/calls")" = info
test "$(cat "$temp/state/current")" = 02:00:00:00:56:78

: > "$temp/state/calls"
printf '00:00:00:00:00:00\n' > "$temp/state/current"
run_helper
test "$(cat "$temp/state/current")" = "$(cat "$temp/state/address")"
test "$(cat "$temp/state/calls")" = "$(printf 'info\nconfig\npublic-addr\ninfo')"

: > "$temp/state/calls"
printf '00:00:00:00:00:00\n' > "$temp/state/current"
touch "$temp/state/delay-confirmation"
run_helper
test "$(cat "$temp/state/current")" = "$(cat "$temp/state/address")"
test "$(cat "$temp/state/calls")" = "$(printf 'info\nconfig\npublic-addr\ninfo\ninfo')"
rm -- "$temp/state/delay-confirmation"

: > "$temp/state/calls"
printf '00:00:00:00:00:00\n' > "$temp/state/current"
touch "$temp/state/refuse-confirmation"
if run_helper > "$temp/failure.log" 2>&1; then
    echo 'An unconfirmed public address was reported as installed.' >&2
    exit 1
fi
grep -Fq 'public address was not confirmed' "$temp/failure.log"
test "$(grep -xc public-addr "$temp/state/calls")" = 1
test "$(grep -xc info "$temp/state/calls")" = 11
echo 'PASS: Bluetooth board gate, private address file, silent non-EOF stdin, immediate and delayed readback, and bounded rejection.'
