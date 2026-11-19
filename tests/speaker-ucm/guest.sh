#!/bin/bash
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
grep -qw y700.speaker_fixture=1 /proc/cmdline
test "$(cat /sys/block/vda/ro)" = 1
cd /opt/speaker-test
modprobe snd-pcm
insmod ./snd-dummy.ko id=Y700Dummy pcm_devs=0
./controls
card=hw:Y700Dummy
ucm=/usr/share/alsa/ucm2
# The test card's UCM lookup resolves to the complete shipped Y700 profile.
install -d "$ucm/conf.d/Dummy"
for name in Dummy Y700Dummy; do
    ln -s ../../Lenovo-Y700/Lenovo-Y700.conf "$ucm/conf.d/Dummy/$name.conf"
done
echo "ALSA $(dpkg-query -W -f='${Version}' libasound2t64) on $(uname -r)"
cmp -s old.conf "$ucm/Lenovo-Y700/HiFi.conf" || cmp new.conf "$ucm/Lenovo-Y700/HiFi.conf"
for profile in stock corrected; do
    if [[ $profile == stock ]]; then
        install -m644 old.conf "$ucm/Lenovo-Y700/HiFi.conf"
        raw=0
    else
        install -m644 new.conf "$ucm/Lenovo-Y700/HiFi.conf"
        raw=249
    fi
    for p in SPK1 SPK2; do
        amixer -c Y700Dummy cset "name='$p Digital PCM Volume'" 100 >/dev/null
    done
    alsaucm -c "$card" set _verb HiFi set _enadev Speaker
    for p in SPK1 SPK2; do
        values=$(amixer -c Y700Dummy cget "name='$p Digital PCM Volume'")
        grep -Fqx "  : values=$raw" <<< "$values"
        grep -Fq 'dBscale-min=-102.25dB,step=0.25dB,mute=1' <<< "$values"
        db=$(amixer -c Y700Dummy sget "$p Digital PCM" | grep -oE '\[(-?([0-9.]+|inf))dB\]' | head -1)
        if [[ $profile == stock ]]; then [[ $db == '[-99999.99dB]' ]]; else [[ $db == '[-40.00dB]' ]]; fi
        printf '%s %s raw=%s level=%s\n' "$profile" "$p" "$raw" "$db"
        amixer -c Y700Dummy cget "name='$p DACPCM Source'" | grep -Fxq '  : values=3'
        amixer -c Y700Dummy cget "name='$p DSP1 Firmware'" | grep -Fxq '  : values=1'
        amixer -c Y700Dummy cget "name='$p Analog PCM Volume'" | grep -Fxq '  : values=0'
        routes=(1 2 3 4 7 8 6 7)
        for i in "${!routes[@]}"; do
            amixer -c Y700Dummy cget "name='$p DSP_RX$((i+1)) Source'" | grep -Fxq "  : values=${routes[i]}"
        done
    done
done
echo Y700_SPEAKER_UCM_PASS
