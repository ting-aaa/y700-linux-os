"""Verify two reciprocal BlueZ bonds across separate kernel/daemon boots."""
import configparser
import hashlib
import os
from pathlib import Path
import re
import secrets
import struct
import subprocess
import sys
import time

import dbus

import classic
from central import ADAPTER, BLUEZ, DEVICE, HID, check_onboard_peer, control, inputs_for, verify_evdev, verify_inputs, wait

STORE = Path("/var/lib/bluetooth")
IDS = ["00:AA:01:00:00:00", "00:AA:01:01:00:01"]


def reciprocal_keys(bredr=False):
    digest = hashlib.sha256()
    previous = None
    for local, remote in (IDS, IDS[::-1]):
        record = configparser.ConfigParser(interpolation=None)
        record.read(STORE / local / remote / "info")
        groups = [g for g in sorted(record.sections()) if
                  (g == "LinkKey" if bredr else g.endswith("LongTermKey"))]
        keys = [record.get(group, "Key") for group in groups]
        if not keys or not all(re.fullmatch(r"[a-fA-F0-9]{32}", key) and int(key, 16) for key in keys):
            return None
        if bredr:
            if previous is not None and previous != keys:
                return None
            previous = keys
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


def classic_trace(phase):
    # BlueZ monitor btsnoop v1. Work inside guest RAM and print only outcomes.
    trace = Path("/run/cold-bond/trace").read_bytes()
    assert trace[:16] == struct.pack(">8sII", b"btsnoop\0", 1, 2001)
    header = struct.Struct(">IIIIQ")
    offset = 16
    packets = [[], []]
    while offset < len(trace):
        length, captured, flags, drops, _ = header.unpack_from(trace, offset)
        offset += header.size
        assert length == captured and drops == 0 and offset + captured <= len(trace)
        index, kind = divmod(flags, 0x10000)
        if index in (0, 1) and kind in (2, 3):
            packets[index].append((kind, trace[offset:offset + captured]))
        offset += captured
    for i, records in enumerate(packets):
        remote = IDS[1-i]
        addr = bytes.fromhex(remote.replace(":", ""))[::-1]
        info = configparser.ConfigParser()
        info.read(STORE / IDS[i] / remote / "info")
        key = bytes.fromhex(info.get("LinkKey", "Key"))
        events = [data for kind, data in records if kind == 3]
        # BR/EDR Connection Complete carries handle and remote BD_ADDR.
        handles = {e[3:5] for e in events if e[0] == 0x03 and e[2] == 0 and e[5:11] == addr}
        encrypted = any(e[0] == 0x08 and e[2] == 0 and e[3:5] in handles and e[5] in (1, 2) for e in events)
        paired = any(e[0] == 0x18 and e[2:8] == addr for e in events)
        completed = any(e[0] == 0x36 and e[2] == 0 and e[3:9] == addr for e in events)
        requested = any(e[0] == 0x17 and e[2:8] == addr for e in events)
        # HCI_Link_Key_Request_Reply body is peer BD_ADDR then the 16-byte key.
        replied = any(kind == 2 and data == b"\x0b\x04\x16" + addr + key for kind, data in records)
        print(f"CLASSIC_HCI hci{i} encrypted={encrypted} notified_new_key={paired} "
              f"requested_key={requested} replied_stored_key={replied} simple_pairing={completed}")
        assert encrypted
        if phase == "seed":
            assert paired and completed
        else:
            assert phase == "resume" and requested and replied and not paired and not completed


def main(phase):
    cmdline = Path("/proc/cmdline").read_text().split()
    assert f"y700.virtual_bond={phase}" in cmdline
    linked_shutdown = "y700.virtual_linked_shutdown=1" in cmdline
    bredr = "y700.virtual_classic=1" in cmdline
    def keys():
        return reciprocal_keys(bredr)
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
        assert not stamp.exists() and not keys()
        adapter = dbus.Interface(obj(adapters[0]), ADAPTER)
        adapter.SetDiscoveryFilter({"Transport": "bredr" if bredr else "le"})
        adapter.StartDiscovery()
        def found():
            state = objects().get(devices[0], {}).get(DEVICE, {})
            return state.get("Address") == IDS[1] if bredr else HID in state.get("UUIDs", ())
        wait("FRESH_HID_DISCOVERED", found)
        adapter.StopDiscovery()
        assert not objects()[devices[0]][DEVICE]["Paired"]
        target = obj(devices[0])
        dev = dbus.Interface(target, DEVICE)
        dev.Pair(timeout=35)
        dbus.Interface(target, dbus.PROPERTIES_IFACE).Set(DEVICE, "Trusted", dbus.Boolean(True))
        wait("BOTH_ENDS_BONDED", both_bonded)
        label = "RECIPROCAL_LINK_KEYS_WRITTEN" if bredr else "RECIPROCAL_LTK_STORES_WRITTEN"
        stamp.write_bytes(wait(label, keys))
        if not bredr and not objects()[devices[0]][DEVICE]["Connected"]:
            dev.Connect(timeout=20)
    else:
        assert phase == "resume"
        assert not any(objects()[path][ADAPTER]["Pairable"] for path in adapters)
        assert both_bonded() and objects()[devices[0]][DEVICE]["Trusted"]
        assert len(stamp.read_bytes()) == 32 and stamp.read_bytes() == keys()
        print("BOTH_BONDS_RELOADED_NO_AGENT_NO_PAIRABLE")
    if bredr:
        wait("CLASSIC_HID_SDP_UUID", lambda: classic.HID in objects()[devices[0]][DEVICE].get("UUIDs", ()))
        def connected():
            wait("CLASSIC_BT_EVDEV_CREATED", lambda: list(inputs_for(IDS[1])))
            wait("CLASSIC_CONNECTED_WITH_BOND", lambda: objects()[devices[0]][DEVICE]["Connected"] and both_bonded())
        if os.environ.get("Y700_BT_GREETER") == "1":
            import greeter
            assert phase == "resume"
            nonce = secrets.token_hex(4)
            with greeter.observer(IDS[1], nonce) as verify_typing:
                with classic.outgoing(IDS[1], IDS[0]) as emit:
                    connected()
                    verify_typing(emit)
                    verify_evdev(IDS[1], emit)
        else:
            with classic.outgoing(IDS[1], IDS[0]) as emit:
                connected()
                verify_inputs(IDS[1], emit, emit)
                check_onboard_peer(IDS[1], "connected")
        assert both_bonded() and stamp.read_bytes() == keys()
        print("CLASSIC_ACCESSORY_INITIATED_WITH_ORIGINAL_LINK_KEY" if phase == "resume" else "CLASSIC_SEED_VERIFIED")
        return
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
    if sys.argv[1].startswith("classic-trace-"):
        classic_trace(sys.argv[1].removeprefix("classic-trace-"))
    else:
        main(sys.argv[1])
