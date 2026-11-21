"""Drive the installed Bluetooth Manager against an isolated BlueZ mock."""

import gettext
import os
from pathlib import Path
import subprocess
import time

from probe import (Atspi, BLUEZ, Gdk, Gio, GLib, MOCK_IFACE, ProbeError, application, await_value, bluetooth_window, call,
                   emit, owner, pid, registered, require, showing_nodes, tap)


def read_property(bus, path, interface, name):
    return call(bus, BLUEZ, path, "org.freedesktop.DBus.Properties", "Get",
                GLib.Variant("(ss)", (interface, name)))[0]


def add_peer(bus, alias, suffix, appearance, device_class, icon, profile):
    peer = call(bus, BLUEZ, "/", "org.bluez.Mock", "AddDevice",
                GLib.Variant("(sss)", ("hci0", f"02:00:00:00:00:{suffix:02X}", alias)))[0]
    # dbusmock's default Pair replaces UUIDs with an Android phone's services.
    # This peripheral only advertises HID. Leave its service list unchanged.
    call(bus, BLUEZ, peer, MOCK_IFACE, "AddMethod",
         GLib.Variant("(sssss)", ("org.bluez.Device1", "Pair", "", "",
             "self.paired = True\nself.UpdateProperties('org.bluez.Device1', {'Paired': dbus.Boolean(True)})")))
    call(bus, BLUEZ, peer, MOCK_IFACE, "UpdateProperties",
         GLib.Variant("(sa{sv})", ("org.bluez.Device1", {
             "Appearance": GLib.Variant("q", appearance), "Class": GLib.Variant("u", device_class),
             "Icon": GLib.Variant("s", icon),
             "UUIDs": GLib.Variant("as", [profile + "-0000-1000-8000-00805f9b34fb"]),
         })))
    return peer


def main():
    require(os.getuid() != 0 and not any(Path("/sys/class/bluetooth").glob("*")), "unexpected-radio-or-user")
    require(os.environ["DBUS_SYSTEM_BUS_ADDRESS"].startswith("unix:path=/run/blueman-pairing/"),
            "private-bus-required")
    Atspi.init()
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM)
    session = Gio.bus_get_sync(Gio.BusType.SESSION)
    await_value(lambda: owner(bus, BLUEZ), "mock-absent", 35)
    adapter = call(bus, BLUEZ, "/", "org.bluez.Mock", "AddAdapter",
                   GLib.Variant("(ss)", ("hci0", "Fixture adapter")))[0]
    applet = subprocess.Popen(["blueman-applet"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        await_value(lambda: registered(bus), "applet-agent-absent", 45)
        language = Path(__file__).with_name("language").read_text().strip()
        locale = "zh_CN.UTF-8" if language == "zh" else "C.UTF-8"
        subprocess.run(["gio", "launch", "/usr/share/applications/blueman-manager.desktop"],
                       env=dict(os.environ, LC_ALL=locale), check=True, timeout=8)
        process = await_value(lambda: pid(session, "org.blueman.Manager"), "manager-absent", 35)
        app = await_value(lambda: application(process), "manager-accessibility-absent")
        frame = await_value(lambda: next((n for n in showing_nodes(app)
                                          if n.get_role() == Atspi.Role.FRAME), None), "manager-frame-absent")
        title = frame.get_name()
        xid = bluetooth_window(title)
        # Keep the Xfce window at a stable size as translated toolbar labels change.
        from gi.repository import GdkX11
        display = Gdk.Display.get_default()
        window = GdkX11.X11Window.foreign_new_for_display(display, int(xid))
        window.maximize()
        display.flush()
        def maximized():
            state = subprocess.check_output(["xprop", "-id", xid, "_NET_WM_STATE"], text=True)
            return "_NET_WM_STATE_MAXIMIZED_VERT" in state and "_NET_WM_STATE_MAXIMIZED_HORZ" in state
        await_value(maximized, "manager-window-not-maximized")
        tr = gettext.translation("blueman", languages=[locale], fallback=True).gettext
        require(Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2, "manager-scale-not-two")
        require(language != "zh" or tr("Search") != "Search", "chinese-catalogue-absent")
        emit(f"MANAGER_DISPLAY locale={locale} size=" + subprocess.check_output(
            ["xdotool", "getdisplaygeometry"], text=True).strip().replace(" ", "x"))

        def find(role, text, substring=False):
            def lookup():
                for n in showing_nodes(frame):
                    if n.get_role() == role and (text in n.get_name() if substring else text == n.get_name()):
                        return n
            try:
                return await_value(lookup, f"manager-control-missing-{text}", 6)
            except ProbeError:
                for n in showing_nodes(frame):
                    print(n.get_role_name(), repr(n.get_name()), repr(n.get_description()), flush=True)
                raise

        def button(label):
            return find(Atspi.Role.PUSH_BUTTON, tr(label))

        def press(widget):
            return tap(widget, frame, xid=xid)

        def stable_row(label):
            previous, since = None, 0.0
            def stationary():
                nonlocal previous, since
                row = find(Atspi.Role.TABLE_CELL, label, substring=True)
                box = row.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
                position = (box.x, box.y, box.width, box.height)
                if position != previous:
                    previous, since = position, time.monotonic()
                return row if time.monotonic() - since >= .55 else None
            return await_value(stationary, "device-row-moving")

        # The first search in this template yields a long D-Bus error when the
        # optional discovery filter is absent. Open the entire error by touch.
        press(button("Search"))
        press(button("More"))
        dialog = await_value(lambda: next((n for n in showing_nodes(app)
                                          if n.get_role() == Atspi.Role.DIALOG), None), "missing-error-dialog")
        detail = next(n for n in showing_nodes(dialog) if n.get_role() == Atspi.Role.TEXT)
        message = Atspi.Text.get_text(detail, 0, -1)
        require(message.rfind("DiscoveryFilter") > 48, "truncated-error-details")
        close = next(n for n in showing_nodes(dialog) if n.get_role() == Atspi.Role.PUSH_BUTTON)
        tap(close, dialog, dialog.get_name())
        emit(f"MANAGER_ERROR detail_chars={len(message)} original_tail=1")
        call(bus, BLUEZ, adapter, "org.bluez.Adapter1", "SetDiscoveryFilter",
             GLib.Variant("(a{sv})", ({},)))
        if read_property(bus, adapter, "org.bluez.Adapter1", "Discovering"):
            call(bus, BLUEZ, adapter, "org.bluez.Adapter1", "StopDiscovery")
        w, h = press(button("Search"))
        await_value(lambda: read_property(bus, adapter, "org.bluez.Adapter1", "Discovering"), "no-discovery")
        require(w >= 96 and h >= 96, "search-target-too-small")
        emit(f"MANAGER_SEARCH hit={w}x{h} discovery=1")
        keyboard = add_peer(bus, "Fixture keyboard", 1, 0x03C1, 0x0540, "input-keyboard", "00001812")
        mouse = add_peer(bus, "Fixture mouse", 2, 0x03C2, 0x0580, "input-mouse", "00001124")
        for name in ("Fixture keyboard", "Fixture mouse"):
            find(Atspi.Role.TABLE_CELL, name, substring=True)

        def paired(peer):
            return read_property(bus, peer, "org.bluez.Device1", "Paired")

        for label, peer in (("Fixture mouse", mouse), ("Fixture keyboard", keyboard)):
            row = stable_row(label)
            row_w, row_h = press(row)
            def selected():
                return find(Atspi.Role.TABLE_CELL, label, substring=True).get_state_set().contains(Atspi.StateType.SELECTED)
            await_value(selected, "row-not-selected", 5)
            require(not paired(peer), "new-accessory-already-paired")
            pair = button("Pair")
            await_value(lambda: pair.get_state_set().contains(Atspi.StateType.SENSITIVE), "pair-not-enabled")
            w, h = press(pair)
            try:
                await_value(lambda: paired(peer), "selected-accessory-not-paired")
            except ProbeError:
                for name, dev in (("mouse", mouse), ("keyboard", keyboard)):
                    count = len(call(bus, BLUEZ, dev, MOCK_IFACE, "GetMethodCalls", GLib.Variant("(s)", ("Pair",)))[0])
                    emit(f"MANAGER_FAILURE_PEER kind={name} pair_calls={count} paired={int(paired(dev))}")
                raise
            calls = call(bus, BLUEZ, peer, MOCK_IFACE, "GetMethodCalls", GLib.Variant("(s)", ("Pair",)))[0]
            require(len(calls) == 1, "expected-one-pair-on-selected-accessory")
            require(len(read_property(bus, peer, "org.bluez.Device1", "UUIDs")) == 1, "unexpected-peer-services")
            if peer == mouse:
                require(not paired(keyboard), "paired-the-other-device")
            if read_property(bus, peer, "org.bluez.Device1", "Trusted"):
                press(button("Untrust"))
                await_value(lambda: not read_property(bus, peer, "org.bluez.Device1", "Trusted"), "still-trusted")
            trust_w, trust_h = press(button("Trust"))
            require(min(w, h, trust_w, trust_h) >= 96, "toolbar-target-too-small")
            await_value(lambda: read_property(bus, peer, "org.bluez.Device1", "Trusted"), "not-trusted")
            emit(f"MANAGER_ACCESSORY kind={label.split()[1]} row={row_w}x{row_h} pair={w}x{h} trust={trust_w}x{trust_h} paired=1 trusted=1")
        emit("BLUEMAN_MANAGER_PASS selected=2 original_desktop_entry=1 real_radio=0")
    finally:
        applet.terminate()
        applet.wait(timeout=8)


if __name__ == "__main__":
    main()
