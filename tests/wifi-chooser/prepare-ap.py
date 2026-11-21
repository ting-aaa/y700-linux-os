"""Create one guest-only AP and synthetic credentials without printing them."""

import json
import os
from pathlib import Path
import re
import secrets
import string
import sys


def private_write(path, data):
    with open(path, 'x', opener=lambda name, flags: os.open(name, flags, 0o600)) as file:
        file.write(data)


def main():
    mode, interface = sys.argv[1:]
    if (mode not in ('open', 'wpa2', 'sae') or not re.fullmatch(r'wlan[0-9]+', interface) or
            'y700.wifi_fixture=1' not in Path('/proc/cmdline').read_text().split()):
        return 2
    root = Path('/run/wifi-fixture')
    network = {'mode': mode, 'ssid': 'Y700-' + secrets.token_hex(6)}
    cfg = (
        f'interface={interface}\ndriver=nl80211\nssid={network["ssid"]}\n'
        'channel=1\nhw_mode=g\nauth_algs=1\nctrl_interface=/run/wifi-fixture/hostapd\n'
    )
    if mode != 'open':
        for key in ('correct', 'wrong'):
            if any(f'y700.wifi_attempt={attempt}' in Path('/proc/cmdline').read_text().split()
                   for attempt in ('onboard', 'chooser', 'blocked', 'cancel')):
                network[key] = ''.join(secrets.choice(string.ascii_lowercase) for _ in range(16))
            else:
                network[key] = secrets.token_urlsafe(24)
        if network['wrong'] == network['correct']:
            return 1
        cfg += 'wpa=2\nrsn_pairwise=CCMP\n'
        cfg += f'wpa_passphrase={network["correct"]}\n'
        cfg += 'wpa_key_mgmt=SAE\nieee80211w=2\nsae_pwe=2\n' if mode == 'sae' else 'wpa_key_mgmt=WPA-PSK\n'
    private_write(root / 'hostapd.conf', cfg)
    private_write(root / 'network.json', json.dumps(network))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError):
        raise SystemExit(1) from None
