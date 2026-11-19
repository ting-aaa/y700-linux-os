"""Verify two reciprocal BlueZ bonds across separate kernel/daemon boots."""
import configparser
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import time

import dbus

from central import ADAPTER, BLUEZ, DEVICE, HID, control, inputs_for, verify_inputs, wait

STORE = Path("/var/lib/bluetooth")
IDS = ["00:AA:01:00:00:00", "00:AA:01:01:00:01"]


def reciprocal_keys():
    digest = hashlib.sha256()
    for local, remote in (IDS, IDS[::-1]):
        record = configparser.ConfigParser(interpolation=None)
        record.read(STORE / local / remote / "info")
        keys = [record.get(group, "Key") for group in sorted(record.sections())
                if group.endswith("LongTermKey")]
        if not keys or not all(re.fullmatch(r"[a-fA-F0-9]{32}", key) and int(key, 16) for key in keys):
            return None
        digest.update(local.encode() + b":" + ",".join(keys).encode())
    return digest.digest()


def cached_hid():
    central = configparser.ConfigParser(interpolation=None)
    central.read(STORE / IDS[0] / IDS[1] / "info")
    return HID in central.get("General", "Services", fallback="").lower().split(";")


def passive_diagnostics(state):
    # The private monitor capture contains bond material. Print only these
    # booleans for the central controller before any explicit connection.
    trace = subprocess.check_output(["btmon", "-i", "hci0", "-r", "/run/cold-bond/trace"], text=True)
    blocks = re.split(r"(?m)(?=^[^\s])", trace)
    auto = any("MGMT Command: Add Device" in block and IDS[1] in block and
               "Action: Auto-connect remote device (0x02)" in block for block in blocks)
    complete = [block for block in blocks if "MGMT Event: Command Complete" in block
                and "Add Device (0x0033)" in block and IDS[1] in block]
    print("PASSIVE_WINDOW", f"connected={bool(state['Connected'])}",
          f"resolved={bool(state['ServicesResolved'])}", f"cached_hid_uuid={HID in state.get('UUIDs', ())}",
          f"mgmt_observed={'MGMT Command:' in trace}", f"mgmt_auto_add={auto}",
          f"mgmt_add_success={any('Status: Success' in b for b in complete)}",
          f"mgmt_add_failure={any('Status: Success' not in b for b in complete)}")


def main(phase):
    cmdline = Path("/proc/cmdline").read_text().split()
    assert f"y700.virtual_bond={phase}" in cmdline
    linked_shutdown = "y700.virtual_linked_shutdown=1" in cmdline
    bus = dbus.SystemBus()
    obj = lambda path: bus.get_object(BLUEZ, path)
    objects = dbus.Interface(obj("/"), "org.freedesktop.DBus.ObjectManager").GetManagedObjects
    adapters = [f"/org/bluez/hci{i}" for i in range(2)]
    devices = [path + "/dev_" + addr.replace(":", "_") for path, addr in zip(adapters, IDS[::-1])]
    assert [objects()[path][ADAPTER]["Address"] for path in adapters] == IDS
    stamp = STORE / ".y700-bond-proof"
    def both_bonded():
        states = [objects().get(path, {}).get(DEVICE, {}) for path in devices]
        return all(state.get("Paired") and state.get("Bonded") for state in states)

    if phase == "seed":
        assert not stamp.exists() and not reciprocal_keys()
        adapter = dbus.Interface(obj(adapters[0]), ADAPTER)
        adapter.SetDiscoveryFilter({"Transport": "le"})
        adapter.StartDiscovery()
        wait("FRESH_HID_DISCOVERED", lambda: HID in objects().get(devices[0], {}).get(DEVICE, {}).get("UUIDs", ()))
        adapter.StopDiscovery()
        assert not objects()[devices[0]][DEVICE]["Paired"]
        target = obj(devices[0])
        dev = dbus.Interface(target, DEVICE)
        dev.Pair(timeout=35)
        dbus.Interface(target, dbus.PROPERTIES_IFACE).Set(DEVICE, "Trusted", dbus.Boolean(True))
        wait("BOTH_ENDS_BONDED", both_bonded)
        stamp.write_bytes(wait("RECIPROCAL_LTK_STORES_WRITTEN", reciprocal_keys))
        if not objects()[devices[0]][DEVICE]["Connected"]:
            dev.Connect(timeout=20)
    else:
        assert phase == "resume"
        assert not any(objects()[path][ADAPTER]["Pairable"] for path in adapters)
        assert both_bonded() and objects()[devices[0]][DEVICE]["Trusted"]
        assert len(stamp.read_bytes()) == 32 and stamp.read_bytes() == reciprocal_keys()
        print("BOTH_BONDS_RELOADED_NO_AGENT_NO_PAIRABLE")
    def resolved():
        state = objects().get(devices[0], {}).get(DEVICE, {})
        return state.get("Connected") and state.get("ServicesResolved")
    reconnect = "AUTOMATIC"
    if phase == "resume":
        try:
            wait("AUTOMATIC_HOG_CONNECTED", resolved, 12)
        except TimeoutError:
            passive_diagnostics(objects()[devices[0]][DEVICE])
            if not linked_shutdown:
                raise
            reconnect = "DEVICE1_CONNECT"
            dbus.Interface(obj(devices[0]), DEVICE).Connect(timeout=30)
    wait("HOG_CONNECTED_AND_RESOLVED", resolved, 25)
    wait("REPORTS_SUBSCRIBED", lambda: control(b"ready"))
    wait("BT_EVDEV_CREATED " + IDS[1], lambda: list(inputs_for(IDS[1])))
    verify_inputs(IDS[1], lambda: control(b"emit"))
    assert both_bonded() and stamp.read_bytes() == reciprocal_keys()
    if phase == "resume":
        print(reconnect + "_WITH_ORIGINAL_RECIPROCAL_KEYS")
    elif not linked_shutdown:
        print("SEED_CONNECTED", f"info_hid={cached_hid()}",
              f"uuid_hid={HID in objects()[devices[0]][DEVICE].get('UUIDs', ())}")
        # A physical accessory retains its GATT application through host
        # shutdown. Stop the radio before this guest tears down that app.
        dbus.Interface(obj(adapters[1]), dbus.PROPERTIES_IFACE).Set(ADAPTER, "Powered", dbus.Boolean(False))
        wait("ACCESSORY_OFF_CENTRAL_DISCONNECTED",
             lambda: not objects()[devices[0]][DEVICE]["Connected"])
        until = time.monotonic() + 3
        while not cached_hid() and time.monotonic() < until:
            time.sleep(.1)
        print("SEED_BEFORE_SHUTDOWN", f"info_hid={cached_hid()}",
              f"uuid_hid={HID in objects()[devices[0]][DEVICE].get('UUIDs', ())}")
        assert cached_hid() and HID in objects()[devices[0]][DEVICE].get("UUIDs", ())


if __name__ == "__main__":
    main(sys.argv[1])
