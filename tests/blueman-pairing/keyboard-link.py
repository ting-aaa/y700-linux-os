"""Enter the desktop's displayed passkey into the virtual keyboard's BlueZ agent."""
from importlib import import_module
import os
from pathlib import Path
import re
import subprocess

from gi.repository import Gio

import probe

# The existing numeric comparison test and this test share the same two radios,
# Xorg seat, discovery and bonded input checks.
link = import_module("numeric-link")


def displayed_digits(pid, address, observed):
    app = probe.application(pid)
    if not app:
        return None
    matches = []
    for widget in probe.showing_nodes(app):
        if widget.get_role() != probe.Atspi.Role.LABEL:
            continue
        text = widget.get_name() or ""
        if "Pairing passkey for" not in text:
            continue
        observed.add("label")
        if address not in text:
            continue
        observed.add("peer")
        match = re.search(r":\s*([0-9]{6})\s*$", text)
        if match:
            matches.append(match[1])
    if len(matches) > 1:
        raise RuntimeError("More than one visible passkey for this accessory")
    return matches[0] if matches else None


def pair_from_keyboard(bus, applet, central, remote):
    # The real bluetoothctl agent interprets digits and Return on this private
    # terminal. Its prompt may echo the key, so never forward terminal data.
    master, slave = os.openpty()
    os.set_blocking(master, False)
    try:
        with subprocess.Popen(["bluetoothctl", "--agent", "KeyboardOnly"],
                              stdin=slave, stdout=slave, stderr=slave) as client:
            output = bytearray()

            def wait_output(marker, reason):
                def received():
                    if client.poll() is not None:
                        raise RuntimeError("Keyboard agent exited early")
                    try:
                        output.extend(os.read(master, 8192))
                    except BlockingIOError:
                        pass
                    return marker in output
                probe.await_value(received, reason, 35)
                output.clear()

            try:
                wait_output(b"Agent registered", "keyboard-agent-registration")
                adapter = remote.rsplit("/", 1)[0]
                addr = link.props(bus, adapter, link.ADAPTER)["Address"]
                os.write(master, f"select {addr}\nshow\n".encode("ascii"))
                wait_output(f"Controller {addr}".encode("ascii"), "keyboard-controller-not-selected")
                addr = link.props(bus, remote, link.DEVICE)["Address"]
                os.write(master, f"pair {addr}\n".encode("ascii"))
                wait_output(b"Enter passkey (number in 0-999999):", "keyboard-agent-not-prompted")
                address = link.props(bus, central, link.DEVICE)["Address"]
                observed = set()
                def displayed():
                    return displayed_digits(applet.pid, address, observed)
                try:
                    digits = probe.await_value(displayed, "blueman-visible-passkey", 25)
                except probe.ProbeError:
                    print(f"DISPLAY_CHECK label={int('label' in observed)} exact_peer={int('peer' in observed)}", flush=True)
                    raise
                assert not link.props(bus, central, link.DEVICE)["Paired"]
                for digit in digits:
                    os.write(master, digit.encode("ascii"))
                os.write(master, b"\n")
                wait_output(b"Pairing successful", "keyboard-passkey-rejected")
                assert all(link.props(bus, path, link.DEVICE)["Bonded"] for path in (central, remote))
                probe.await_value(lambda: not displayed(), "blueman-passkey-still-visible")
                print("BLUEMAN_KEYBOARD_ENTRY displayed_digits=6 peer_input=bluetoothctl "
                      "return_submitted=1 bonded_both=1 dismissed=1", flush=True)
            finally:
                client.terminate()
    finally:
        os.close(master)
        os.close(slave)


def main():
    assert "y700.blueman_keyboard=1" in Path("/proc/cmdline").read_text().split()
    assert os.getuid() == 1000 and os.environ["DISPLAY"] == ":1"
    probe.Atspi.init()
    probe.Atspi.set_timeout(2500, 2500)
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM)
    with subprocess.Popen(["blueman-applet"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as applet:
        try:
            central, remote, address = link.desktop_and_accessory(bus, applet)
            pair_from_keyboard(bus, applet, central, remote)
            for connection in (1, 2):
                # A bonded GATT server may retain CCC subscriptions across a
                # disconnect. The trace checks fresh link encryption per epoch.
                link.reconnect_and_test_input(bus, central, address, require_unsubscribed=False)
                print(f"BONDED_DESKTOP_HID connection={connection}", flush=True)
        finally:
            applet.terminate()


if __name__ == "__main__":
    main()
