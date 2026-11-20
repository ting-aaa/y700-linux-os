"""Summarize saved profiles compatible with currently cached BSSes; no scan or activation."""
from collections import Counter
import subprocess
import gi

gi.require_version("NM", "1.0")
from gi.repository import NM


def band(mhz):
    if 2400 <= mhz < 2500:
        return "2.4GHz"
    if 4900 <= mhz < 5925:
        return "5GHz"
    if 5925 <= mhz <= 7125:
        return "6GHz"
    return "other"


def security(ap):
    flags = int(ap.get_rsn_flags())
    # NM80211ApSecurityFlags values shared by D-Bus and libnm.
    modes = [(0x100, "PSK"), (0x200, "EAP"), (0x400, "SAE"), (0x800, "OWE"),
             (0x1000, "OWE-transition"), (0x2000, "Suite-B-192")]
    labels = [name for bit, name in modes if flags & bit]
    if labels:
        return "+".join(labels)
    return "other-protected" if ap.get_wpa_flags() or int(ap.get_flags()) & 1 else "open"


def main():
    client = NM.Client.new(None)
    devices = [d for d in client.get_devices() if isinstance(d, NM.DeviceWifi) and d.get_active_access_point()]
    if len(devices) != 1:
        raise SystemExit("Expected one connected Wi-Fi station")
    device = devices[0]
    active = device.get_active_access_point()
    active_ssid = active.get_ssid()
    profile = device.get_active_connection().get_connection()
    saved = [p for p in client.get_connections() if p.get_setting_wireless()]
    # wpa_cli status reports negotiated security. The cached BSS RSN flags
    # below describe advertised modes and can include WPA3 transition mode.
    status = subprocess.check_output(["wpa_cli", "-i", device.get_iface(), "status"], text=True)
    fields = dict(row.split("=", 1) for row in status.splitlines() if "=" in row)
    if fields.get("wpa_state") != "COMPLETED" or int(fields["freq"]) != active.get_frequency():
        raise SystemExit("Association changed while reading the cache")
    print(f"current_mhz={active.get_frequency()} negotiated={fields['key_mgmt']} saved_profiles={len(saved)}")
    counts = Counter()
    for cell in device.get_access_points():
        group = band(cell.get_frequency())
        counts[group, "cached"] += 1
        if active_ssid is not None and cell.get_ssid() is not None and cell.get_ssid().equal(active_ssid):
            counts[group, "same_ssid"] += 1
        if any(cell.connection_valid(p) for p in saved):
            counts[group, "saved_compatible"] += 1
        if cell.connection_valid(profile):
            counts[group, security(cell)] += 1
    for group in ("2.4GHz", "5GHz", "6GHz"):
        advertised = [f"{key}:{n}" for (freq, key), n in sorted(counts.items())
                      if freq == group and key not in ("cached", "same_ssid", "saved_compatible")]
        print(f"band={group} cached_bss={counts[group,'cached']} same_ssid_bss={counts[group,'same_ssid']} "
              f"saved_compatible_bss={counts[group,'saved_compatible']} active_profile_rsn={','.join(advertised) or 'none'}")


if __name__ == "__main__":
    main()
