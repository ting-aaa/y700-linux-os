"""Inspect the authorized test peer through the running tablet's BlueZ."""

import time
import argparse
import socket
import struct
from pathlib import Path
from uuid import UUID

from gi.repository import Gio, GLib


BUS = "org.bluez"
ADAPTER = "/org/bluez/hci0"
ADAPTER_IFACE = "org.bluez.Adapter1"
DEVICE_IFACE = "org.bluez.Device1"
HID = "00001812-0000-1000-8000-00805f9b34fb"
bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
AGENT = "/org/y700/HidFixture"


def check_pairing(target):
    # Ask the real daemon whether a user gesture is required. Never approve a
    # comparison, supply a passkey, become the default agent, or trust a peer.
    xml = """<node><interface name="org.bluez.Agent1">
        <method name="Release"/><method name="Cancel"/>
        <method name="RequestPinCode"><arg type="o" direction="in"/><arg type="s" direction="out"/></method>
        <method name="RequestPasskey"><arg type="o" direction="in"/><arg type="u" direction="out"/></method>
        <method name="DisplayPinCode"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
        <method name="DisplayPasskey"><arg type="o" direction="in"/><arg type="u" direction="in"/><arg type="q" direction="in"/></method>
        <method name="RequestConfirmation"><arg type="o" direction="in"/><arg type="u" direction="in"/></method>
        <method name="RequestAuthorization"><arg type="o" direction="in"/></method>
        <method name="AuthorizeService"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
    </interface></node>"""
    interface = Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0]
    requests, results = [], []

    def request(_connection, _sender, _path, _interface, method, args, reply):
        if method in ("Release", "Cancel"):
            reply.return_value(None)
            return
        if args.unpack()[0] == target:
            requests.append(method)
        reply.return_dbus_error("org.bluez.Error.Rejected", "An operator must perform this step")

    def finished(connection, result):
        try:
            connection.call_finish(result)
        except GLib.Error as error:
            results.append(Gio.DBusError.get_remote_error(error) or "timeout-or-transport-error")
        else:
            results.append("paired")

    registration = bus.register_object(AGENT, interface, request, None, None)
    registered = False
    try:
        invoke("/org/bluez", "org.bluez.AgentManager1", "RegisterAgent", GLib.Variant("(os)", (AGENT, "KeyboardDisplay")))
        registered = True
        bus.call(BUS, target, DEVICE_IFACE, "Pair", None, None, Gio.DBusCallFlags.NO_AUTO_START,
                 18000, None, finished)
        deadline = time.monotonic() + 20
        while not results and time.monotonic() < deadline:
            while GLib.MainContext.default().iteration(False):
                pass
            time.sleep(0.03)
        if not results or results[0] == "timeout-or-transport-error":
            try:
                invoke(target, DEVICE_IFACE, "CancelPairing")
            except GLib.Error:
                pass
        print("TABLET_PAIR_RESULT", ",".join(results or ["deadline"]), "agent_requests=" + ",".join(requests), flush=True)
    finally:
        if registered:
            invoke("/org/bluez", "org.bluez.AgentManager1", "UnregisterAgent", GLib.Variant("(o)", (AGENT,)))
        bus.unregister_object(registration)


def invoke(path, iface, method, params=None, timeout=3000):
    return bus.call_sync(BUS, path, iface, method, params, None,
                         Gio.DBusCallFlags.NO_AUTO_START, timeout, None).unpack()


def state():
    return invoke("/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects")[0]


def radio_events():
    events = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
    # HCI_FILTER: event packets only, LE Meta Event (0x3e), all opcodes.
    events.setsockopt(0, 2, struct.pack("=IIIH2x", 1 << 4, 0, 1 << 30, 0))
    events.bind((0,))
    events.settimeout(0.25)
    return events


def advertising_reports(packet):
    if len(packet) < 5 or packet[:2] != b"\x04\x3e" or packet[3] not in (2, 13):
        return
    pos = 5
    for _ in range(packet[4]):
        if packet[3] == 2:  # LE Advertising Report
            if pos + 9 > len(packet):
                return
            connectable = packet[pos] in (0, 1)
            addr_start, data_start = pos + 2, pos + 9
            size = packet[pos + 8]
            pos = data_start + size + 1  # trailing RSSI
        else:  # LE Extended Advertising Report
            if pos + 24 > len(packet):
                return
            connectable = bool(packet[pos] & 1)
            addr_start, data_start = pos + 3, pos + 24
            size = packet[pos + 23]
            pos = data_start + size
        if pos > len(packet):
            return
        addr = packet[addr_start:addr_start + 6][::-1].hex(":").upper()
        yield addr, connectable, packet[data_start:data_start + size]


def find_connectable(events, token, host_address, timeout=8):
    ad = bytes((len(token) + 3, 0x16, 0x12, 0x18)) + token
    matched, connectable = set(), set()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            packet = events.recv(512)
        except TimeoutError:
            continue
        for addr, can_connect, data in advertising_reports(packet):
            if can_connect:
                connectable.add(addr)
            if ad in data:
                matched.add(addr)
        candidates = matched & connectable
        if not candidates:
            continue
        paths = {path: o[DEVICE_IFACE]["Address"] for path, o in state().items()
                 if o.get(DEVICE_IFACE, {}).get("Adapter") == ADAPTER
                 and o[DEVICE_IFACE].get("Address") in candidates
                 and bytes(o[DEVICE_IFACE].get("ServiceData", {}).get(HID, ())) == token}
        if len(paths) == 1:
            return next(iter(paths))
        public = [p for p, addr in paths.items() if addr.replace(":", "") == host_address]
        if len(public) == 1:
            return public[0]
    raise RuntimeError(f"Connectable HID marker unavailable or ambiguous: marked={len(matched)} connectable-marked={len(matched & connectable)}")


def verify_quiet(token, witness):
    """Check incoming LE advertisements independently of BlueZ's device cache."""
    snapshot = state()
    adapter = snapshot[ADAPTER][ADAPTER_IFACE]
    if not adapter["Powered"] or adapter["Discovering"]:
        raise RuntimeError("Bluetooth adapter busy or unavailable")
    matched = False
    old_ad = bytes((len(token) + 3, 0x16, 0x12, 0x18)) + token
    control_ad = bytes((19, 0xff, 0xff, 0xff)) + UUID(witness).bytes_le
    invoke(ADAPTER, ADAPTER_IFACE, "SetDiscoveryFilter", GLib.Variant("(a{sv})", ({
        "Transport": GLib.Variant("s", "le")
    },)))
    invoke(ADAPTER, ADAPTER_IFACE, "StartDiscovery")
    try:
        with radio_events() as events:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                try:
                    packet = events.recv(512)
                except TimeoutError:
                    continue
                for _, _, data in advertising_reports(packet):
                    if old_ad in data:
                        raise RuntimeError("The retired HID marker is still being advertised")
                    if control_ad in data:
                        matched = True
    finally:
        invoke(ADAPTER, ADAPTER_IFACE, "StopDiscovery")
    if not matched:
        raise RuntimeError("Positive-control advertisement missing")
    print("TABLET_SCAN_SAW_POSITIVE_CONTROL_WITHOUT_OLD_HID_MARKER", flush=True)


def probe(token, pairing, reconnect, host_address):
    if b"lenovo,asphalt" not in Path("/proc/device-tree/compatible").read_bytes().split(b"\0"):
        raise RuntimeError("Expected the Asphalt tablet")
    snapshot = state()
    adapter = snapshot[ADAPTER][ADAPTER_IFACE]
    if not adapter["Powered"] or adapter["Discovering"]:
        raise RuntimeError("Bluetooth adapter busy or unavailable")
    initial_bonds = {p for p, obj in snapshot.items() if obj.get(DEVICE_IFACE, {}).get("Paired")}
    target = None
    scanning = False
    initiated = False
    try:
        invoke(ADAPTER, ADAPTER_IFACE, "SetDiscoveryFilter", GLib.Variant("(a{sv})", ({
            "Transport": GLib.Variant("s", "le"), "DuplicateData": GLib.Variant("b", True)
        },)))
        with radio_events() as events:
            invoke(ADAPTER, ADAPTER_IFACE, "StartDiscovery")
            scanning = True
            target = find_connectable(events, token, host_address)
        invoke(ADAPTER, ADAPTER_IFACE, "StopDiscovery")
        scanning = False
        peer = state()[target][DEVICE_IFACE]
        if peer.get("Connected") or peer.get("Paired") or peer.get("Bonded") or peer.get("Trusted"):
            raise RuntimeError("Existing relationship with test peer; preserving it")
        print("TABLET_HID_ADVERTISEMENT_MATCHED", flush=True)
        initiated = True
        try:
            invoke(target, DEVICE_IFACE, "Connect", timeout=10000)
        except GLib.Error as error:
            print("TABLET_CONNECT_RESULT", Gio.DBusError.get_remote_error(error) or error.code, flush=True)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            objects = state()
            peer = objects.get(target, {}).get(DEVICE_IFACE, {})
            if peer.get("ServicesResolved"):
                break
            time.sleep(0.15)
        print("TABLET_HID_LINK connected=%s resolved=%s paired=%s bonded=%s" %
              tuple(bool(peer.get(key)) for key in ("Connected", "ServicesResolved", "Paired", "Bonded")), flush=True)
        services = [path for path, obj in objects.items()
                    if obj.get("org.bluez.GattService1", {}).get("UUID") == HID
                    and obj["org.bluez.GattService1"].get("Device") == target]
        if not peer.get("Connected") or not peer.get("ServicesResolved") or len(services) != 1:
            raise RuntimeError("No resolved HID service on the controlled physical link")
        chars = [obj["org.bluez.GattCharacteristic1"] for obj in objects.values()
                 if obj.get("org.bluez.GattCharacteristic1", {}).get("Service") == services[0]]
        found = sorted(c["UUID"][4:8] for c in chars)
        print("TABLET_HID_CHARACTERISTICS", " ".join(found), flush=True)
        if not all(x in found for x in ("2a4a", "2a4b", "2a4c")) or found.count("2a4d") != 2:
            raise RuntimeError("Incomplete HID characteristics")
        print("TABLET_HID_GATT_RESOLVED", flush=True)
        refs = [o["org.bluez.GattDescriptor1"] for o in objects.values()
                if o.get("org.bluez.GattDescriptor1", {}).get("UUID", "")[4:8] == "2908"
                and o["org.bluez.GattDescriptor1"]["Characteristic"].startswith(services[0] + "/")]
        if len(refs) != 2:
            raise RuntimeError("Expected the two HID input report references")
        print("TABLET_REPORT_REFERENCES=2", flush=True)
        if pairing:
            check_pairing(target)
        elif reconnect:
            invoke(target, DEVICE_IFACE, "Disconnect")
            if state().get(target, {}).get(DEVICE_IFACE, {}).get("Connected"):
                raise RuntimeError("The first connection did not close")
            # Some controllers rotate private addresses. Rediscover the same
            # advertised marker and require the same BlueZ object for this test.
            with radio_events() as events:
                invoke(ADAPTER, ADAPTER_IFACE, "StartDiscovery")
                scanning = True
                if find_connectable(events, token, host_address) != target:
                    raise RuntimeError("Advertiser address changed during the reconnect check")
            invoke(target, DEVICE_IFACE, "Connect", timeout=10000)
            invoke(ADAPTER, ADAPTER_IFACE, "StopDiscovery")
            scanning = False
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                peer = state().get(target, {}).get(DEVICE_IFACE, {})
                if peer.get("Connected") and peer.get("ServicesResolved"):
                    break
                time.sleep(0.15)
            else:
                raise RuntimeError("Services did not resolve on reconnect")
            if peer.get("Paired") or peer.get("Bonded") or HID not in peer.get("UUIDs", []):
                raise RuntimeError("Unexpected pairing or service state on reconnect")
            print("TABLET_UNBONDED_HID_LINK_RECONNECTED_AND_RESOLVED", flush=True)
    finally:
        if scanning:
            invoke(ADAPTER, ADAPTER_IFACE, "StopDiscovery")
        if target is not None and initiated:
            end = state().get(target, {}).get(DEVICE_IFACE, {})
            if end.get("Connected"):
                invoke(target, DEVICE_IFACE, "Disconnect")
            if end and target not in initial_bonds and (target not in snapshot or end.get("Paired") or end.get("Bonded")):
                invoke(ADAPTER, ADAPTER_IFACE, "RemoveDevice", GLib.Variant("(o)", (target,)))
        after = state()
        if {p for p, o in after.items() if o.get(DEVICE_IFACE, {}).get("Paired")} != initial_bonds:
            raise RuntimeError("Paired device inventory changed")
        if after[ADAPTER][ADAPTER_IFACE]["Discovering"]:
            raise RuntimeError("Discovery still active")
        print("TABLET_DISCOVERY_AND_BONDS_RESTORED", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("token")
    parser.add_argument("--host-address")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check-pairing", action="store_true")
    modes.add_argument("--check-reconnect", action="store_true")
    modes.add_argument("--verify-quiet", metavar="WITNESS_UUID")
    args = parser.parse_args()
    token = bytes(int(x) for x in args.token.split("-"))
    if len(token) != 8:
        raise SystemExit("Expected eight marker bytes")
    if args.verify_quiet:
        verify_quiet(token, args.verify_quiet)
    else:
        probe(token, args.check_pairing, args.check_reconnect, args.host_address)
