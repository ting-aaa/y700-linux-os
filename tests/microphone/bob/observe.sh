#!/bin/sh
# Run as root from a private temporary directory containing only the qualified .ko.
set -eu
[ "$#" = 1 ] && [ "$(id -u)" = 0 ] || exit 2
ko=$(realpath -e -- "$1")
ko_sha=3ad4f89a4c1b58bfc676136fb15e63b29c9ddae4a2fe9a471f87075c47147dbb
[ "$(sha256sum "$ko" | cut -d' ' -f1)" = "$ko_sha" ]
[ "$(uname -r)" = 7.3.4-asphalt-prc ]
case $(sha256sum /sys/kernel/notes | cut -d' ' -f1) in
  35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6|c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063) ;;
  *) echo 'BOB_REJECT reason=kernel_notes' >&2; exit 1 ;;
esac
m=/sys/module/y700_bob_read
[ ! -e "$m" ] || { echo 'BOB_REJECT reason=module_in_use' >&2; exit 1; }
t0=$(cat /proc/sys/kernel/tainted)
insmod "$ko"
cleanup() {
    if [ -e "$m" ]; then rmmod y700_bob_read; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
[ "$(cat "$m/refcnt")" = 0 ]
v=$(cat "$m/parameters/apps_mv")
case "$v" in ''|*[!0-9]*) exit 1 ;; esac
[ "$v" -le 8191 ]
printf 'BOB_SAMPLE apps_voltage_resource_mv=%s\n' "$v"
rmmod y700_bob_read
trap - EXIT HUP INT TERM
[ ! -e "$m" ]
printf 'BOB_CLEANUP unloaded=1 refs_before_unload=0 taint_before=%s taint_after=%s\n' "$t0" "$(cat /proc/sys/kernel/tainted)"
