"""Temporarily roam between the saved network's two bands on the connected PRC tablet."""
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import time

import gi

gi.require_version("NM", "1.0")
from gi.repository import NM


def cli(*args):
    try:
        return subprocess.check_output(args, text=True, timeout=15, stderr=subprocess.DEVNULL).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        raise RuntimeError(f"{args[0]} did not complete successfully") from None


def association(iface):
    return dict(row.split("=", 1) for row in cli("wpa_cli", "-i", iface, "status").splitlines() if "=" in row)


def saved_files():
    # Only the equality of these two in-process snapshots is published.
    paths = Path("/etc/NetworkManager/system-connections").glob("*.nmconnection")
    return {p.name: hashlib.sha256(p.read_bytes()).digest() for p in paths}


def joined(iface, profile, address):
    state = association(iface)
    return (state.get("wpa_state") == "COMPLETED" and state.get("bssid", "").lower() == address
            and cli("nmcli", "-g", "GENERAL.CON-UUID", "device", "show", iface) == profile)


def roam(iface, profile, target, mhz):
    if not joined(iface, profile, target):
        if cli("wpa_cli", "-i", iface, "roam", target) != "OK":
            raise RuntimeError("Supplicant declined roam")
        deadline = time.monotonic() + 20
        while not joined(iface, profile, target):
            if time.monotonic() >= deadline:
                raise RuntimeError("Target association timed out")
            time.sleep(.15)
    state = association(iface)
    if int(state.get("freq", "0")) != mhz:
        raise RuntimeError("Target frequency changed")
    print(f"WIFI_ROAM mhz={mhz} negotiated={state['key_mgmt']} same_profile=1", flush=True)


def main():
    stage = Path(__file__).resolve().parent
    if (os.geteuid() != 0 or cli("findmnt", "-nro", "FSTYPE", "-T", str(stage)) != "tmpfs"
            or stage.stat().st_uid != 0 or stage.stat().st_mode & 0o022
            or Path("/proc/device-tree/region_country").read_bytes() != b"PRC\0"
            or b"lenovo,asphalt" not in Path("/proc/device-tree/compatible").read_bytes().split(b"\0")):
        raise RuntimeError("Expected an isolated RAM stage on a PRC tablet")
    if (stage / "return-to-original").exists():
        raise RuntimeError("Use a fresh trial directory without a return marker")
    client = NM.Client.new(None)
    device, = [d for d in client.get_devices() if isinstance(d, NM.DeviceWifi) and d.get_active_access_point()]
    iface = device.get_iface()
    original = device.get_active_access_point()
    profile = device.get_active_connection().get_connection()
    identity = profile.get_uuid()
    address = original.get_bssid().lower()
    original_ssid = original.get_ssid()
    mhz = original.get_frequency()
    if not 2400 <= mhz < 2500 or not joined(iface, identity, address):
        raise RuntimeError("Expected the original saved 2.4 GHz association")
    cli("nmcli", "--wait", "12", "device", "wifi", "list", "ifname", iface, "--rescan", "yes")
    # A fresh libnm snapshot includes the scan that just finished.
    client = NM.Client.new(None)
    device = client.get_device_by_iface(iface)
    profile = device.get_active_connection().get_connection()
    if profile.get_uuid() != identity or not joined(iface, identity, address):
        raise RuntimeError("Active network changed before trial")
    candidates = [ap for ap in device.get_access_points() if 4900 <= ap.get_frequency() < 5925
                  and ap.get_ssid() is not None and ap.get_ssid().equal(original_ssid)
                  and ap.connection_valid(profile) and ap.get_bssid().lower() != address]
    if not candidates:
        raise RuntimeError("No compatible 5 GHz access point for the active saved network")
    target = max(candidates, key=lambda ap: ap.get_strength())
    snapshot = saved_files()
    for name in ("NetworkManager", "wpa_supplicant"):
        if cli("systemctl", "is-active", name) != "active":
            raise RuntimeError("Network service unavailable")
    services = cli("systemctl", "show", "NetworkManager", "wpa_supplicant", "-p", "InvocationID", "--value")
    print(f"WIFI_ROAM_START original_mhz={mhz} target_mhz={target.get_frequency()} candidates={len(candidates)}", flush=True)
    def interrupted(_sig, _frame):
        raise InterruptedError("Roaming trial interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        roam(iface, identity, target.get_bssid().lower(), target.get_frequency())
        deadline = time.monotonic() + 125
        while not (stage / "return-to-original").exists() and time.monotonic() < deadline:
            time.sleep(.25)
    finally:
        # A deliberate user switch to a different profile takes precedence.
        current = cli("nmcli", "-g", "GENERAL.CON-UUID", "device", "show", iface)
        if current in ("", "--", identity):
            try:
                roam(iface, identity, address, mhz)
            except (RuntimeError, subprocess.SubprocessError):
                if cli("nmcli", "-g", "GENERAL.CON-UUID", "device", "show", iface) not in ("", "--", identity):
                    raise
                cli("nmcli", "--wait", "12", "connection", "up", "uuid", identity, "ifname", iface, "ap", address)
                roam(iface, identity, address, mhz)
    if not joined(iface, identity, address) or snapshot != saved_files():
        raise RuntimeError("Original association or saved profiles differ")
    if services != cli("systemctl", "show", "NetworkManager", "wpa_supplicant", "-p", "InvocationID", "--value"):
        raise RuntimeError("Network service restarted")
    print("WIFI_ROAM_RETURN original_ap=1 saved_files_equal=1 services_retained=1", flush=True)


if __name__ == "__main__":
    main()
