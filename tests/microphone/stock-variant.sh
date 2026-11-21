#!/system/bin/sh
# Run from an existing stock Android shell. Read only cached codec metadata.
set -eu
reject() { printf 'WCD_STOCK unresolved=%s\n' "$1"; exit 1; }
[ "$#" = 0 ] || reject arguments
[ "$(getprop ro.product.device)" = TB320FC ] &&
    [ "$(getprop ro.build.version.incremental)" = TB320FC_CN_OPEN_USER_Q00031.0_V_ZUI_17.0.350_ST_250418 ] ||
    reject build
for spec in \
    machine_dlkm:4cb6952f0e1eaa9689dc573a9d49656f58546d32e7c1e5e82b7318283a51d07b \
    wcd938x_dlkm:7c96ef6e7346bd58ad98407ad4c1a5c5dbcaba58bc10568d5b4a56aea94bc380; do
    note=/sys/module/${spec%%:*}/notes/.note.gnu.build-id
    [ -r "$note" ] || reject module_note_unreadable
    hash=$(sha256sum "$note") || reject module_note_unreadable
    [ "${hash%% *}" = "${spec#*:}" ] || reject module_mismatch
done
set -- /proc/asound/card[0-9]*/codecs/wcd938x/variant
[ "$#" = 1 ] && [ -r "$1" ] || reject variant_unavailable
variant=$(cat "$1") || reject variant_unreadable
case $variant in WCD9380|WCD9385) ;; *) reject unknown ;; esac
printf 'WCD_STOCK release=CN350 source=driver_cache variant=%s\n' "$variant"
