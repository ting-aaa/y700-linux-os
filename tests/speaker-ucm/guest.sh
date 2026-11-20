#!/bin/bash
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin UV_OFFLINE=1 UV_CACHE_DIR=/run/speaker-uv
grep -qw y700.speaker_fixture=1 /proc/cmdline
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
test "$(cat /sys/block/vda/ro)" = 1
cd /opt/speaker-test
modprobe snd-pcm
insmod ./snd-dummy.ko id=LenovoY700 pcm_devs=0
./controls
test "$(id -nG y700 | tr ' ' '\n' | grep -Fx audio)" = audio
chgrp audio /dev/snd/controlC0
chmod 660 /dev/snd/controlC0
install -d -o y700 -g y700 -m700 "$UV_CACHE_DIR"
install -m600 -o y700 -g y700 /dev/null /run/speaker-observer.log
install -m755 stage-observer.sh /usr/libexec/y700-speaker-calibration
card=hw:LenovoY700
ucm=/usr/share/alsa/ucm2
profile=$ucm/Lenovo-Y700/HiFi.conf
install -d "$ucm/conf.d/Dummy"
for name in Dummy LenovoY700; do
    ln -s ../../Lenovo-Y700/Lenovo-Y700.conf "$ucm/conf.d/Dummy/$name.conf"
done
echo "ALSA $(dpkg-query -W -f='${Version}' libasound2t64) on $(uname -r)"
echo "Platform $(dpkg-query -W -f='${Version}' y700-platform)"
cmp -s old.conf "$profile" || cmp -s previous.conf "$profile" || cmp new.conf "$profile"

read_control() {
    amixer -c LenovoY700 cget "name='$1'" | sed -n 's/^  : values=//p'
}

check_switch() {
    case "$2:$(read_control "$1")" in
        on:on|on:1|off:off|off:0) ;;
        *) return 1 ;;
    esac
}

seed_enabled() {
    # A resumed session can leave a preload set. UCM must explicitly stop it
    # before running the calibration helper.
    for speaker in SPK1 SPK2; do
        amixer -c LenovoY700 cset "name='$speaker AMP Enable Switch'" on >/dev/null
        amixer -c LenovoY700 cset "name='$speaker DSP1 Preload Switch'" on >/dev/null
        amixer -c LenovoY700 cset "name='$speaker Digital PCM Volume'" 100 >/dev/null
    done
}

enable_speaker() {
    runuser -u y700 -- alsaucm -c "$card" set _verb HiFi set _enadev Speaker
}

check_speaker() {
    local scenario=$1 raw=$2 expected_db=$3 state=$4 values db
    local routes=(1 2 3 4 7 8 6 7)
    for speaker in SPK1 SPK2; do
        values=$(amixer -c LenovoY700 cget "name='$speaker Digital PCM Volume'")
        grep -Fqx "  : values=$raw" <<< "$values"
        grep -Fq 'dBscale-min=-102.25dB,step=0.25dB,mute=1' <<< "$values"
        db=$(amixer -c LenovoY700 sget "$speaker Digital PCM" | grep -oE '\[(-?([0-9.]+|inf))dB\]' | head -1)
        test "$db" = "[$expected_db]"
        test "$(read_control "$speaker Amplifier Mode")" = 0
        test "$(read_control "$speaker DACPCM Source")" = 3
        test "$(read_control "$speaker DSP1 Firmware")" = 1
        test "$(read_control "$speaker Analog PCM Volume")" = 0
        for i in "${!routes[@]}"; do
            test "$(read_control "$speaker DSP_RX$((i+1)) Source")" = "${routes[i]}"
        done
        check_switch "$speaker AMP Enable Switch" "$state"
        check_switch "$speaker DSP1 Preload Switch" "$state"
        printf 'SPEAKER_PROFILE case=%s speaker=%s raw=%s level=%s amp=%s preload=%s routing=verified\n' \
            "$scenario" "$speaker" "$raw" "$db" "$state" "$state"
    done
}

install -m644 old.conf "$profile"
seed_enabled
enable_speaker
check_speaker stock 0 -99999.99dB on
install -m644 previous.conf "$profile"
seed_enabled
enable_speaker
check_speaker previous 249 -40.00dB on

install -m644 new.conf "$profile"
test ! -e /run/y700-speaker-calibration
printf '%s\n' generic > /run/speaker-scenario
seed_enabled
enable_speaker
check_speaker generic 249 -40.00dB on

# Independent synthetic samples inside the documented factory acceptance range.
# The test never opens a factory partition.
record=/run/y700-speaker-calibration/factory
install -d -o root -g audio -m750 "${record%/*}"
"./uv" run --offline --no-project --python /usr/bin/python3 python - "$record" <<'PY'
import struct
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(struct.pack(">IIIiIIIi", 9000, 1, 9001, 23, 9300, 1, 9301, -4))
PY
chown root:audio "$record"
chmod 640 "$record"
printf '%s\n' calibrated > /run/speaker-scenario
seed_enabled
enable_speaker
check_speaker calibrated 361 -12.00dB on

check_samples() {
    local fields=(CAL_R CAL_STATUS CAL_CHECKSUM CAL_AMBIENT)
    local words=(
        0x00,0x00,0x23,0x28 0x00,0x00,0x00,0x01 0x00,0x00,0x23,0x29 0x00,0x00,0x00,0x17
        0x00,0x00,0x24,0x54 0x00,0x00,0x00,0x01 0x00,0x00,0x24,0x55 0xff,0xff,0xff,0xfc
    )
    local index=0
    for speaker in SPK1 SPK2; do
        for field in "${fields[@]}"; do
            test "$(read_control "$speaker DSP1 Protection cd $field")" = "${words[index]}"
            index=$((index+1))
        done
    done
}
check_samples
echo 'SPEAKER_SYNTHETIC_WRITEBACK channels=2 fields=8 exact=yes'

runuser -u y700 -- alsaucm -c "$card" set _verb HiFi set _enadev Speaker set _disdev Speaker set _verb Inactive
check_speaker disabled 361 -12.00dB off
check_switch "PRIMARY_MI2S_RX Audio Mixer MultiMedia1" off

printf '%s\n' invalid > /run/speaker-scenario
printf 'x' > "$record"
seed_enabled
# alsaucm's batch CLI can print a failed command and still exit 0. Assert the
# result from the libasound calls that a real audio session manager uses.
runuser -u y700 -- ./uv run --offline --no-project --python /usr/bin/python3 python - "$card" <<'PY'
import ctypes as C
import sys

alsa = C.CDLL("libasound.so.2")
alsa.snd_use_case_mgr_open.argtypes = (C.POINTER(C.c_void_p), C.c_char_p)
alsa.snd_use_case_set.argtypes = (C.c_void_p, C.c_char_p, C.c_char_p)
alsa.snd_use_case_geti.argtypes = (C.c_void_p, C.c_char_p, C.POINTER(C.c_long))
alsa.snd_use_case_mgr_close.argtypes = (C.c_void_p,)
manager = C.c_void_p()
assert alsa.snd_use_case_mgr_open(C.byref(manager), sys.argv[1].encode()) == 0
try:
    assert alsa.snd_use_case_set(manager, b"_verb", b"HiFi") == 0
    result = alsa.snd_use_case_set(manager, b"_enadev", b"Speaker")
    active = C.c_long(-1)
    assert alsa.snd_use_case_geti(manager, b"_devstatus/Speaker", C.byref(active)) == 0
    print(f"SPEAKER_INVALID_UCM_RESULT libasound={result} active={active.value}", flush=True)
    assert result < 0 and active.value == 0, (result, active.value)
finally:
    alsa.snd_use_case_mgr_close(manager)
PY
check_speaker invalid 249 -40.00dB off
check_samples
cat /run/speaker-observer.log
echo 'SPEAKER_INVALID_ABORT amp=off preload=off previous_samples=unchanged'
echo Y700_SPEAKER_UCM_PASS
