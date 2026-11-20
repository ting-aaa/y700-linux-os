#!/bin/sh
# Board ALSA, SoundWire and device-tree inventory. Never opens a sound device.
set -eu
export LC_ALL=C
dt=/sys/firmware/devicetree/base
printf 'model='
tr -d '\000' < "$dt/model"
printf '\nkernel=%s\n' "$(uname -r)"
dpkg-query -W -f='platform=${Version}\n' y700-platform

card=
for id in /proc/asound/card*/id; do
    [ -r "$id" ] || continue
    [ "$(cat "$id")" = LenovoY700 ] || continue
    card=${id%/id}
    break
done
if [ -z "$card" ]; then
    printf 'board_card=absent\n'
    exit 1
fi
num=${card##*card}
printf 'board_card=%s\n' "$num"
awk -F '[:-]' -v number="$num" '$1 + 0 == number { print "pcm=" $0 }' /proc/asound/pcm
count=0
for path in "$card"/pcm*c; do
    [ -d "$path" ] || continue
    count=$((count+1))
done
printf 'board_capture_pcms=%s\n' "$count"

peripherals=0
for path in /sys/bus/soundwire/devices/*; do
    [ -e "$path" ] || continue
    peripherals=$((peripherals+1))
    printf 'soundwire_device=%s\n' "${path##*/}"
done
printf 'soundwire_devices=%s\n' "$peripherals"
for path in "$dt"/soc@0/soundwire@* "$dt"/soc@0/codec@3200000 \
            "$dt"/soc@0/codec@3220000 "$dt"/soc@0/codec@33f0000; do
    [ -d "$path" ] || continue
    status=okay
    if [ -r "$path/status" ]; then status=$(tr -d '\000' < "$path/status"); fi
    printf 'dt=%s %s\n' "${path#"$dt"}" "$status"
done

ucm=/usr/share/alsa/ucm2/Lenovo-Y700/HiFi.conf
tplg=/lib/firmware/qcom/sm8475/Lenovo-Y700-tplg.bin
sha256sum "$ucm" "$tplg"
awk '/SectionDevice[.]|CapturePCM/ { print "ucm=" $0 }' "$ucm"
kernel_config() {
    if [ -r /proc/config.gz ]; then
        zcat /proc/config.gz
    elif [ -r "/boot/config-$(uname -r)" ]; then
        cat "/boot/config-$(uname -r)"
    fi
}
kernel_config | awk '/^(# )?CONFIG_(SOUNDWIRE( |[=]|_QCOM)|SND_SOC_(WCD938|LPASS_(VA|RX|TX)_MACRO))/ { print }'
