"""Drive org.bluez.Device1, observe evdev from the Bluetooth HID bus."""
import os
from pathlib import Path
from contextlib import contextmanager
import pwd
import secrets
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time

import dbus
import classic as hidp
import keyboard

BLUEZ = "org.bluez"
ADAPTER = BLUEZ + ".Adapter1"
DEVICE = BLUEZ + ".Device1"
HID = "00001812-0000-1000-8000-00805f9b34fb"
EVENT = struct.Struct("@llHHi")


def wait(description, check, seconds=20):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        result = check()
        if result:
            print(description, flush=True)
            return result
        time.sleep(.15)
    raise TimeoutError(description)


def control(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as sock:
        sock.settimeout(12 if command.startswith(b"type:") else 2)
        sock.connect("/run/y700-virtual-hid.sock")
        sock.sendall(command)
        return sock.recv(32) == b"ready"


def inputs_for(address):
    for event in sorted(Path("/sys/class/input").glob("event*")):
        info = event / "device"
        if ((info / "id/bustype").read_text().strip() == "0005" and
                (info / "uniq").read_text().strip().upper() == address.upper()):
            yield event.name


def check_onboard_peer(address, phase):
    if "Y700_GTK_HID" not in os.environ:
        return
    from Onboard import osk

    if phase == "disconnected":
        wait("PEER_EVDEV_REMOVED", lambda: not list(inputs_for(address)))
    parents = {(Path("/sys/class/input") / event / "device").resolve()
               for event in inputs_for(address)}
    assert bool(parents) == (phase == "connected")
    text_nodes = 0
    for parent in parents:
        output = subprocess.check_output(
            ["udevadm", "info", "--query=property", str(parent)], text=True)
        properties = dict(line.split("=", 1) for line in output.splitlines())
        assert properties["PHYS"].strip('"') and properties["ID_INPUT"] == "1"
        text_nodes += properties.get("ID_INPUT_KEYBOARD") == "1"
    # This VM has only the paired input hardware. The F15-only profile stays
    # negative; exactly one full keyboard should appear with the typing profile.
    expected = int(keyboard.TEXT_MODE and phase == "connected")
    assert text_nodes == expected
    assert len(osk.UDev().get_keyboard_devices()) == expected
    print(f"ONBOARD_UDEV phase={phase} peer_inputs_with_phys={len(parents)} text_keyboards={expected}", flush=True)


@contextmanager
def desktop_observer(address, nonce):
    if "Y700_GTK_HID" not in os.environ:
        yield
        return
    user = pwd.getpwnam("y700")
    with tempfile.TemporaryDirectory(dir=os.environ["XDG_RUNTIME_DIR"]) as directory:
        os.chown(directory, user.pw_uid, user.pw_gid)
        ready = Path(directory, "ready")
        args = ["runuser", "-u", "y700", "--", "env", "UV_CACHE_DIR=" + directory + "/cache",
                "./uv", "run", "--offline", "--no-project", "--python", "/usr/bin/python3",
                "python", "-B", "desktop.py", str(address), str(ready)]
        if nonce is not None:
            args.append(nonce)
        with subprocess.Popen(args) as witness:
            def is_ready():
                if witness.poll() is not None:
                    raise RuntimeError(f"GTK witness exited before ready: {witness.returncode}")
                return ready.exists()
            try:
                wait("GTK_INPUT_ARMED", is_ready, 45)
                yield
                if witness.wait(timeout=20) != 0:
                    raise RuntimeError("Missing window input from the paired device")
            finally:
                if witness.poll() is None:
                    witness.terminate()


def verify_evdev(address, emit):
    fds = []
    try:
        for name in inputs_for(address):
            fds.append(os.open("/dev/input/" + name, os.O_RDONLY | os.O_NONBLOCK))
        if not fds:
            raise RuntimeError("No evdev input on BUS_BLUETOOTH")
        assert emit()
        seen = []
        expected = {(1, 185, 1), (1, 185, 0), (1, 272, 1), (1, 272, 0),
                    (2, 0, 7), (2, 1, -3), (2, 8, 1), (2, 11, 120)}
        until = time.monotonic() + 5
        while time.monotonic() < until and not expected.issubset(seen):
            for fd in select.select(fds, [], [], .3)[0]:
                seen.extend((typ, code, value) for _, _, typ, code, value in
                            EVENT.iter_unpack(os.read(fd, EVENT.size * 64)) if typ in (1, 2))
        print("EVDEV", seen, flush=True)
        assert expected.issubset(seen), expected.difference(seen)
        assert seen.index((1, 185, 1)) < seen.index((1, 185, 0))
        assert seen.index((1, 272, 1)) < seen.index((1, 272, 0))
    finally:
        for fd in fds:
            os.close(fd)


def verify_inputs(address, emit, send_text=None):
    nonce = secrets.token_hex(4) if keyboard.TEXT_MODE else None
    with desktop_observer(address, nonce):
        verify_evdev(address, emit)
        if nonce is not None:
            assert send_text(nonce)


def main():
    if "y700.virtual_hid=1" not in Path("/proc/cmdline").read_text().split():
        raise RuntimeError("Requires the marked VM")
    bus = dbus.SystemBus()
    objects = dbus.Interface(bus.get_object(BLUEZ, "/"), "org.freedesktop.DBus.ObjectManager").GetManagedObjects
    central = "/org/bluez/hci0"
    address = objects()["/org/bluez/hci1"][ADAPTER]["Address"]
    check_onboard_peer(address, "before")
    path = central + "/dev_" + address.replace(":", "_")
    adapter = dbus.Interface(bus.get_object(BLUEZ, central), ADAPTER)
    classic = sys.argv[1:] == ["classic"]
    adapter.SetDiscoveryFilter({"Transport": "bredr" if classic else "le"})
    adapter.StartDiscovery()
    def found():
        peer = objects().get(path, {}).get(DEVICE, {})
        return peer.get("Address") == address and (classic or HID in peer.get("UUIDs", []))
    wait("DISCOVERED " + path, found)
    adapter.StopDiscovery()
    target = bus.get_object(BLUEZ, path)
    dev = dbus.Interface(target, DEVICE)
    props = dbus.Interface(target, dbus.PROPERTIES_IFACE)
    def state():
        return props.GetAll(DEVICE)
    assert not state()["Paired"]
    dev.Pair(timeout=35)
    wait("BONDED", lambda: state().get("Bonded") and state()["Paired"])
    if classic:
        wait("SDP_HID_RESOLVED", lambda: hidp.HID in state().get("UUIDs", []))
        props.Set(DEVICE, "Trusted", dbus.Boolean(True))
        host = objects()[central][ADAPTER]["Address"]
        for attempt in range(2):
            with hidp.outgoing(str(address), str(host)) as emit:
                wait("CLASSIC_BT_EVDEV_CREATED", lambda: list(inputs_for(address)))
                wait("CLASSIC_CONNECTED_WITH_BOND", lambda: state()["Connected"] and state()["Bonded"])
                verify_inputs(address, emit, emit)
                check_onboard_peer(address, "connected")
            if attempt == 0:
                if state()["Connected"]:
                    dev.Disconnect(timeout=15)
                wait("CLASSIC_DISCONNECTED_WITH_BOND", lambda: not state()["Connected"] and state()["Bonded"])
                check_onboard_peer(address, "disconnected")
        print("Y700_VIRTUAL_CLASSIC_INPUT_PASS", flush=True)
        return
    if not state()["Connected"]:
        dev.Connect(timeout=20)
    for attempt in range(3):
        wait("HOG_CONNECTED_AND_RESOLVED", lambda: state()["Connected"] and state()["ServicesResolved"])
        wait("REPORTS_SUBSCRIBED", lambda: control(b"ready"))
        wait("BT_EVDEV_CREATED " + address, lambda: list(inputs_for(address)))
        verify_inputs(address, lambda: control(b"emit"), lambda nonce: control(b"type:" + nonce.encode("ascii")))
        check_onboard_peer(address, "connected")
        if attempt == 0:
            dev.Disconnect(timeout=15)
            wait("DISCONNECTED_WITH_BOND", lambda: not state()["Connected"] and state()["Bonded"])
            check_onboard_peer(address, "disconnected")
            dev.Connect(timeout=30)
        elif attempt == 1:
            props.Set(DEVICE, "Trusted", dbus.Boolean(True))
            peer_adapter = dbus.Interface(bus.get_object(BLUEZ, "/org/bluez/hci1"), dbus.PROPERTIES_IFACE)
            peer_adapter.Set(ADAPTER, "Powered", dbus.Boolean(False))
            wait("PERIPHERAL_OFF_WITH_BOND", lambda: not state()["Connected"] and state()["Bonded"])
            check_onboard_peer(address, "disconnected")
            peer_adapter.Set(ADAPTER, "Powered", dbus.Boolean(True))
            control(b"advertise")
            wait("AUTOMATIC_RECONNECT", lambda: state()["Connected"] and state()["Bonded"], 25)
    print("Y700_VIRTUAL_HOG_PASS", flush=True)


if __name__ == "__main__":
    main()
