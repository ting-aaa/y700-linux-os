"""Exercise the installed manager's Search button against the PRC tablet's powered radio."""
import os
from pathlib import Path
import subprocess
import time

from probe import Atspi, BLUEZ, DBUS, DBUS_PATH, Gio, GLib, application, await_value, call, owner, pid, require, showing_nodes


def main():
    require(os.getuid() != 0 and os.environ["GSETTINGS_BACKEND"] == "memory", "expected-ordinary-test-session")
    require(Path("/proc/device-tree/region_country").read_bytes() == b"PRC\0", "not-prc")
    require(b"qcom,wcn6855-bt" in Path("/sys/class/bluetooth/hci0/device/of_node/compatible").read_bytes().split(b"\0"),
            "unexpected-physical-controller")
    home = Path(os.environ["HOME"])
    require(str(home).startswith("/run/y700-bt-discovery.") and (home / "xvfb.pid").is_file(), "private-display-missing")
    xvfb = Path("/proc", (home / "xvfb.pid").read_text().strip())
    require((xvfb / "exe").resolve().name == "Xvfb" and os.environ["DISPLAY"].startswith(":"), "unexpected-X-server")
    Atspi.init()
    system = Gio.bus_get_sync(Gio.BusType.SYSTEM)
    session = Gio.bus_get_sync(Gio.BusType.SESSION)
    manager = "org.blueman.Manager"
    applet = "org.blueman.Applet"
    applet_owner = owner(session, applet)
    bluez_owner = owner(system, BLUEZ)
    require(not call(session, DBUS, DBUS_PATH, DBUS, "NameHasOwner", GLib.Variant("(s)", (manager,)))[0],
            "existing-manager")

    def property_value(name):
        return call(system, BLUEZ, "/org/bluez/hci0", "org.freedesktop.DBus.Properties", "Get",
                    GLib.Variant("(ss)", ("org.bluez.Adapter1", name)))[0]

    def bonds():
        managed, = call(system, BLUEZ, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects")
        return {path: (dev["Paired"], dev["Trusted"], dev["Connected"]) for path, interfaces in managed.items()
                if (dev := interfaces.get("org.bluez.Device1")) and
                (dev["Paired"] or dev["Trusted"] or dev["Connected"])}

    require(property_value("Powered") and not property_value("Discovering"), "controller-busy-or-off")
    existing = bonds()
    # Match the installed desktop entry's executable, keeping this window on the private X server.
    with subprocess.Popen(["/usr/bin/blueman-manager"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as window:
        try:
            await_value(lambda: pid(session, manager) == window.pid, "manager-start", 15)
            app = await_value(lambda: application(window.pid), "manager-accessibility")

            def search():
                for node in showing_nodes(app):
                    if node.get_role() == Atspi.Role.PUSH_BUTTON and node.get_name() == "Search":
                        if node.get_state_set().contains(Atspi.StateType.SENSITIVE):
                            return node

            button = await_value(search, "search-button")
            extent = button.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
            require(extent.width >= 48 and extent.height >= 48, "small-search-control")
            require(button.get_action_iface().do_action(0), "search-action")
            await_value(lambda: property_value("Discovering"), "physical-discovery-start", 8)
            started = time.monotonic()
            print("BLUEMAN_REAL_SEARCH controller=wcn6855 discovery_started=1", flush=True)
            await_value(lambda: not property_value("Discovering"), "physical-discovery-finish", 80)
            await_value(search, "search-button-did-not-recover")
            elapsed = time.monotonic() - started
            require(elapsed >= 1 and bonds() == existing, "unexpected-discovery-or-bond-change")
            print(f"BLUEMAN_REAL_IDLE duration_s={elapsed:.2f} search_enabled=1 bonds_and_links_preserved=1", flush=True)
        finally:
            if window.poll() is None:
                try:
                    if pid(session, manager) == window.pid:
                        call(session, manager, "/org/blueman/Manager", "org.gtk.Actions", "Activate",
                             GLib.Variant("(sava{sv})", ("Quit", [], {})))
                        window.wait(timeout=6)
                finally:
                    if window.poll() is None:
                        window.terminate()
                        try:
                            window.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            window.kill()
    require(property_value("Powered") and not property_value("Discovering") and bonds() == existing,
            "controller-final-state")
    require(owner(session, applet) == applet_owner and owner(system, BLUEZ) == bluez_owner, "desktop-agents-changed")
    print("BLUEMAN_REAL_DONE applet_retained=1 bluez_retained=1 adapter_powered=1", flush=True)


if __name__ == "__main__":
    main()
