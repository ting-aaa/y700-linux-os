"""Temporarily roam between the saved network's two bands on the connected PRC tablet."""
import argparse
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


def wait_for_marker(stage, marker, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if (stage / "return-to-original").exists():
            return False
        if marker and (stage / marker).exists():
            return True
        time.sleep(.25)
    return False


def main(target_band=5, revisit=False):
    stage = Path(__file__).resolve().parent
    if (os.geteuid() != 0 or cli("findmnt", "-nro", "FSTYPE", "-T", str(stage)) != "tmpfs"
            or stage.stat().st_uid != 0 or stage.stat().st_mode & 0o022
            or Path("/proc/device-tree/region_country").read_bytes() != b"PRC\0"
            or b"lenovo,asphalt" not in Path("/proc/device-tree/compatible").read_bytes().split(b"\0")):
        raise RuntimeError("Expected an isolated RAM stage on a PRC tablet")
    if any((stage / name).exists() for name in ("return-to-original", "visit-original", "revisit-target")):
        raise RuntimeError("Use a fresh trial directory without old markers")
    client = NM.Client.new(None)
    device, = [d for d in client.get_devices() if isinstance(d, NM.DeviceWifi) and d.get_active_access_point()]
    iface = device.get_iface()
    original = device.get_active_access_point()
    profile = device.get_active_connection().get_connection()
    identity = profile.get_uuid()
    address = original.get_bssid().lower()
    original_ssid = original.get_ssid()
    mhz = original.get_frequency()
    low, high = range(2400, 2500), range(4900, 5925)
    original_band, requested_band = (low, high) if target_band == 5 else (high, low)
    if mhz not in original_band or not joined(iface, identity, address):
        raise RuntimeError("Starting association does not match the requested round trip")
    cli("nmcli", "--wait", "12", "device", "wifi", "list", "ifname", iface, "--rescan", "yes")
    # A fresh libnm snapshot includes the scan that just finished.
    client = NM.Client.new(None)
    device = client.get_device_by_iface(iface)
    profile = device.get_active_connection().get_connection()
    if profile.get_uuid() != identity or not joined(iface, identity, address):
        raise RuntimeError("Active network changed before trial")
    candidates = [ap for ap in device.get_access_points() if ap.get_frequency() in requested_band
                  and ap.get_ssid() is not None and ap.get_ssid().equal(original_ssid)
                  and ap.connection_valid(profile) and ap.get_bssid().lower() != address]
    if not candidates:
        raise RuntimeError("No compatible access point on the requested band for the active saved network")
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
        if revisit:
            if wait_for_marker(stage, "visit-original", 55):
                roam(iface, identity, address, mhz)
                if wait_for_marker(stage, "revisit-target", 25):
                    roam(iface, identity, target.get_bssid().lower(), target.get_frequency())
                    wait_for_marker(stage, None, 40)
        else:
            wait_for_marker(stage, None, 125)
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-band", type=int, choices=(2, 5), default=5)
    parser.add_argument("--revisit", action="store_true", help="Visit the original and target again on host request")
    args = parser.parse_args()
    main(args.target_band, args.revisit)
