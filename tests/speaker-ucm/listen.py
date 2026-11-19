"""Attended Y700 grille check. Run with --listen from the tablet desktop."""
import argparse
import math
import os
import struct
import subprocess
import sys


def stimulus():
    """One second per channel at 440 Hz and 1% full scale, with a quiet gap."""
    rate = 48000
    data = bytearray()
    for channel in (0, 1):
        if channel:
            data.extend(bytes(rate))  # 250 ms, four bytes per stereo sample.
        for i in range(rate):
            gain = min(1, i / 960, (rate - 1 - i) / 960)
            tone = round(328 * gain * math.sin(2 * math.pi * 440 * i / rate))
            pair = (0, tone) if channel else (tone, 0)
            data.extend(struct.pack('<hh', *pair))
    return data


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--listen', action='store_true', required=True)
    parser.parse_args()
    if sys.platform != 'linux' or not sys.stdin.isatty() or os.geteuid() == 0:
        sys.exit('Run in a terminal as the signed-in desktop user.')
    os.environ['LC_ALL'] = 'C'
    sink = 'alsa_output.platform-sound.HiFi__Speaker__sink'
    props = subprocess.check_output(['wpctl', 'inspect', '@DEFAULT_AUDIO_SINK@'], text=True)
    if f'node.name = "{sink}"' not in props or 'CS35L45 protection DSP' not in props:
        sys.exit('The protected Y700 speaker sink must be the default.')
    for amp in ('SPK1', 'SPK2'):
        state = subprocess.check_output(['amixer', '-c', 'LenovoY700', 'sget', f'{amp} Digital PCM'], text=True)
        if '[-40.00dB]' not in state:
            sys.exit(f'{amp} must already report the qualified −40.00 dB setting.')
    input('Hold the tablet in landscape and note the USB-port orientation. Press Enter to play left, then right. ')
    subprocess.run(['pw-play', '--target', sink, '--properties', '{ node.dont-fallback = true node.dont-reconnect = true }',
                    '--raw', '--rate', '48000', '--channels', '2',
                    '--channel-map', 'FL,FR', '--format', 's16', '-'], input=stimulus(), timeout=8, check=True)
    print('Record which grille was audible in each interval, including silence or both grilles.')
