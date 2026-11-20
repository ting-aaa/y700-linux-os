"""Report completed link recoveries from the current boot without network identifiers."""

from dataclasses import dataclass
import json
import ipaddress
from pathlib import Path
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
    recoveries = []
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
                    recoveries.append((prior.time_us, lost_at, stamp))
            loss = attempt = None
    if not seen:
        raise SystemExit("No supplicant entries for this interface in the current boot")
    print(f"fully_matched_recoveries={len(recoveries)}")
    return recoveries


def manager_history(lines, device, recoveries):
    """Correlate journal monotonic times within this boot. Keep addresses in memory."""
    leases = {4: [], 6: []}
    states = []
    dev = re.escape(device)
    lease = re.compile(rf"dhcp([46]) \({dev}\): state changed new lease, address=([^\s,]+)")
    state = re.compile(rf"device \({dev}\): state change: ([\w-]+) -> ([\w-]+)")
    for line in lines:
        entry = json.loads(line)
        message = entry.get("MESSAGE")
        if not isinstance(message, str):
            continue
        stamp = int(entry["__MONOTONIC_TIMESTAMP"])
        owner = entry.get("_SYSTEMD_INVOCATION_ID")
        if match := state.search(message):
            states.append((stamp, match[2], owner))
        if match := lease.search(message):
            if " pending" in message or ", pending" in message:
                continue
            try:
                address = ipaddress.ip_interface(match[2]).ip
            except ValueError:
                continue
            version = int(match[1])
            if address.version == version:
                leases[version].append((stamp, address, owner))
    for joined, lost, completed in recoveries:
        # A late DHCP response after a separate activation is not this handover.
        preceding = [s for s in states if s[0] <= lost]
        following = [s for s in states if lost < s[0] <= completed + 15_000_000]
        end = min(completed + 15_000_000, following[0][0]) if following else completed + 15_000_000
        for version, rows in leases.items():
            before = [r for r in rows if joined <= r[0] < lost]
            after = [r for r in rows if completed <= r[0] < end]
            if not before or not after:
                print(f"dhcp{version}_old_and_renewed_lease=unknown")
                continue
            old, new = before[-1], after[0]
            same_nm = bool(preceding and old[2] and old[2] == new[2] == preceding[-1][2])
            print(f"dhcp{version}_same_address={old[1] == new[1]} same_nm_invocation={same_nm} "
                  f"last_device_state_activated={bool(preceding and preceding[-1][1] == 'activated')} "
                  f"disconnected_to_bound_s={(new[0] - lost) / 1e6:.3f} "
                  f"completed_to_bound_s={(new[0] - completed) / 1e6:.3f}")


if __name__ == "__main__":
    if len(sys.argv) == 1:
        active = [p.name for p in Path("/sys/class/net").iterdir()
                  if (p / "phy80211").exists() and (p / "operstate").read_text().strip() == "up"]
        if len(active) != 1:
            raise SystemExit("Pass the wireless interface to select it explicitly")
        device = active[0]
    elif len(sys.argv) == 2:
        device = sys.argv[1]
    else:
        raise SystemExit("Usage: wifi-association-history.py [WLAN_INTERFACE]")
    with subprocess.Popen(["journalctl", "-b", "-u", "wpa_supplicant.service", "-o", "json",
                           "--no-pager"], stdout=subprocess.PIPE) as journal:
        recoveries = inspect(journal.stdout, device)
        if journal.wait():
            raise SystemExit("Could not read the supplicant journal")
    if recoveries:
        with subprocess.Popen(["journalctl", "-b", "-u", "NetworkManager.service", "-o", "json",
                               "--no-pager"], stdout=subprocess.PIPE) as journal:
            manager_history(journal.stdout, device, recoveries)
            if journal.wait():
                raise SystemExit("Could not read the NetworkManager journal")
