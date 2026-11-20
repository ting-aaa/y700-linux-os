"""Report completed link recoveries from the current boot without network identifiers."""

from dataclasses import dataclass
import json
import re
import subprocess
import sys


PEER = r"([0-9a-fA-F:]{17})"
ATTEMPT = re.compile(r"(?:SME: )?Trying to (?:authenticate|associate) with " + PEER + r" \(SSID='(.*)' freq=(\d+)")
CONNECTED = re.compile(r"CTRL-EVENT-CONNECTED - Connection to " + PEER + r" completed \[id=(\d+)")
LOST = re.compile(r"CTRL-EVENT-DISCONNECTED bssid=" + PEER + r" reason=(\d+)")


@dataclass
class Link:
    time_us: int
    peer: str
    profile: str
    ssid: str
    freq: int


def inspect(lines, device):
    prefix = device + ": "
    attempt = current = loss = None
    count = 0
    seen = False
    for line in lines:
        entry = json.loads(line)
        message = entry.get("MESSAGE")
        if not isinstance(message, str) or not message.startswith(prefix):
            continue
        seen = True
        event = message[len(prefix):]
        stamp = int(entry["__MONOTONIC_TIMESTAMP"])
        if match := ATTEMPT.match(event):
            attempt = (match[1].lower(), match[2], int(match[3]))
        elif match := LOST.match(event):
            loss = (current, stamp, int(match[2])) if current and current.peer == match[1].lower() else None
            current = attempt = None
        elif match := CONNECTED.match(event):
            peer = match[1].lower()
            current = Link(stamp, peer, match[2], attempt[1], attempt[2]) if attempt and attempt[0] == peer else None
            if current and loss:
                prior, lost_at, reason = loss
                if prior.ssid == current.ssid and prior.profile == current.profile:
                    print(f"same_ssid_and_supplicant_network=yes freq_mhz={prior.freq}->{current.freq} "
                          f"bssid_changed={prior.peer != current.peer} reason={reason} "
                          f"prior_association_s={(lost_at - prior.time_us) / 1e6:.1f} "
                          f"disconnected_to_completed_s={(stamp - lost_at) / 1e6:.3f}")
                    count += 1
            loss = attempt = None
    if not seen:
        raise SystemExit("No supplicant entries for this interface in the current boot")
    print(f"fully_matched_recoveries={count}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: wifi-association-history.py WLAN_INTERFACE")
    with subprocess.Popen(["journalctl", "-b", "-u", "wpa_supplicant.service", "-o", "json",
                           "--no-pager"], stdout=subprocess.PIPE) as journal:
        inspect(journal.stdout, sys.argv[1])
        if journal.wait():
            raise SystemExit("Could not read the supplicant journal")
