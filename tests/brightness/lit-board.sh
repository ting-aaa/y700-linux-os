#!/bin/bash
# Read panel state and only the KTZ8866 brightness/enable registers on dev12.11.
set -euo pipefail
export LC_ALL=C
[[ $# == 0 || ( $# == 2 && ( $1 == --expect-lit || $1 == --expect-blank ) && $2 =~ ^[0-9]+$ ) ]] ||
    { echo 'Usage: lit-board.sh [--expect-lit REQUESTED_LEVEL|--expect-blank REQUESTED_LEVEL]' >&2; exit 2; }
grep -azFxq lenovo,asphalt /proc/device-tree/compatible
printf '%s  /sys/kernel/notes\n' 35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6 | sha256sum --strict --status -c -
bl=/sys/class/backlight/ktz8866-backlight
client=$(realpath -e "$bl/device")
name=${client##*/}
[[ $name =~ ^[0-9]+-0011$ && "$client" -ef /sys/bus/i2c/devices/"$name" &&
   "$client/driver" -ef /sys/bus/i2c/drivers/ktz8866 ]]
node=$(realpath -e "$client/of_node")
[[ $node == */i2c@988000/backlight@11 && $(cat "$bl/max_brightness") == 2047 ]]
grep -azFxq lenovo,y700-ktz8866 "$node/compatible"
map=/sys/kernel/debug/regmap/$name
[[ $(stat -f -c %T "$map") == debugfs && $(cat "$map/name") == ktz8866 &&
   $(cat "$map/range") == 0-15 && ! -e $map/cache_only ]]
shopt -s nullglob
panels=(/sys/class/drm/card*-DSI-1)
[[ ${#panels[@]} == 1 ]]
panel=${panels[0]}
panel_state() {
    paste -sd' ' "$panel/status" "$panel/enabled" "$panel/dpms" "$bl/bl_power" "$bl/brightness" | tr '\n' ' '
}
read_codes() {
    # Two hex digits on either side and ": " + LF = seven bytes per register.
    # sysseek/sysread avoid stdio read-ahead or fallback to a sequential dump.
    /usr/bin/perl - "$map/registers" <<'PERL'
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW SEEK_SET);
sysopen(my $fh, $ARGV[0], O_RDONLY | O_NOFOLLOW) or die "open registers: $!";
sub exact {
    my ($reg, $size) = @_;
    my $offset = 7 * $reg;
    my $pos = sysseek($fh, $offset, SEEK_SET);
    defined($pos) && $pos == $offset or die "seek register: $!";
    my $len = sysread($fh, my $record, $size);
    defined($len) && $len == $size or die "short register read";
    return $record;
}
my ($lo, $hi) = exact(4,14) =~ /\A04: ([0-9a-f]{2})\n05: ([0-9a-f]{2})\n\z/;
my ($en) = exact(8,7) =~ /\A08: ([0-9a-f]{2})\n\z/;
defined $hi && defined $en or die "invalid register layout or I2C read failure";
printf "%d %d %d\n", hex($lo), hex($hi), hex($en);
PERL
}
before=$(panel_state)
sample=$(read_codes)
[[ $(read_codes) == "$sample" && $(panel_state) == "$before" ]] || { echo 'KTZ_STATE_CHANGED' >&2; exit 1; }
read -r conn enabled dpms power request <<<"$before"
[[ $conn == connected && $request =~ ^[0-9]+$ ]]
read -r low high en <<<"$sample"
raw=$((high*8 + (low & 7)))
led=$(((en >> 6) & 1))
printf 'KTZ_READBACK connector=%s enabled=%s dpms=%s bl_power=%s requested=%s reg04=%02x reg05=%02x reg08=%02x programmed=%d led_enable=%d sink_mask=0x%02x\n' \
    "$conn" "$enabled" "$dpms" "$power" "$request" "$low" "$high" "$en" "$raw" "$led" "$((en & 63))"
if [[ $# == 2 ]]; then
    [[ $request == "$2" && $low -le 7 && $((en & 63)) == 15 ]]
    case $1 in
        --expect-lit) [[ $enabled == enabled && $dpms == On && $power == 0 && $led == 1 && $raw -gt 0 && $raw == "$request" ]] ;;
        --expect-blank) [[ $power == 4 && $led == 0 && $raw == 0 ]] ;;
    esac
fi
