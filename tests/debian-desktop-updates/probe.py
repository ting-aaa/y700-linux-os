"""Touch the real updater's visible Install control and observe the installed marker."""
import os
from pathlib import Path
import subprocess
import sys
import time

from auth import admin_agent
from transactions import successful

import gi
gi.require_version("Atspi", "2.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Atspi, Gdk, GLib


def nodes(obj):
    yield obj
    for i in range(max(0, obj.get_child_count())):
        child = obj.get_child_at_index(i)
        if child:
            yield from nodes(child)


def buttons():
    seen = []
    for app in nodes(Atspi.get_desktop(0)):
        if app.get_role() != Atspi.Role.PUSH_BUTTON:
            continue
        state = app.get_state_set()
        if state.contains(Atspi.StateType.SHOWING) and state.contains(Atspi.StateType.ENABLED):
            seen.append((app.get_name().strip(), app))
    return seen


def has_update_selection():
    names = {node.get_name().strip() for node in nodes(Atspi.get_desktop(0))
             if node.get_role() in (Atspi.Role.TABLE_CELL, Atspi.Role.LABEL)}
    return ("1 update selected" in names and
            any("y700-qa-updater-2.0" in name.splitlines() for name in names))


def tap(button):
    rect = button.get_extents(Atspi.CoordType.SCREEN)
    assert rect.width > 0 and rect.height > 0
    x, y = 2 * rect.x + rect.width, 2 * rect.y + rect.height
    assert 0 <= x < 1600 and 0 <= y < 2560, (x, y)
    with open("/run/topology/feed", "w") as feed:
        print("tap", 10*x, 10*y, file=feed)
    print(f"UPDATER_TOUCH logical={rect.width}x{rect.height} scale=2 finger=type_b", flush=True)


assert os.getuid() == 1000
Atspi.init()
Atspi.set_timeout(4000, 4000)
assert Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2
bus = ["busctl", "--system", "--timeout=12s", "get-property", "org.freedesktop.PackageKit",
       "/org/freedesktop/PackageKit", "org.freedesktop.PackageKit"]
backend = subprocess.check_output(bus + ["BackendName"], text=True).strip()
print("UPDATER_BACKEND", backend, subprocess.check_output(bus + ["NetworkState"], text=True).strip(), flush=True)
assert backend in ('s "apt"', 's "aptcc"'), backend
desktop = "/usr/share/applications/org.gnome.PackageUpdater.desktop"
product = Path("product-mode").exists()
if product:
    desktop = "/usr/share/applications/y700-software-updates.desktop"
subprocess.run(["gio", "launch", desktop], check=True)
deadline = time.monotonic() + 50
last = []
while time.monotonic() < deadline:
    try:
        options = buttons()
        last = [name for name, _ in options]
        update = [button for name, button in options if name in ("Install Update", "Install Updates")]
        if len(update) == 1 and has_update_selection():
            button = update[0]
            break
    except GLib.Error:
        pass
    time.sleep(.25)
else:
    titles = [(n.get_role_name(), n.get_name()) for n in nodes(Atspi.get_desktop(0))][:45]
    raise RuntimeError(("no eligible update button", last, titles))

if product:
    assert Path("/usr/share/y700-qa-updater/version").read_text().strip() == "1.0"
    print("UPDATER_VIEWER forwarded=1 install_button_visible=1 selected=1 no_input=1", flush=True)
    sys.exit(0)

with admin_agent() as auth:
    tap(button)
    marker = Path("/usr/share/y700-qa-updater/version")
    deadline = time.monotonic() + 55
    while time.monotonic() < deadline:
        if marker.read_text().strip() == "2.0" and successful("UpdatePackages"):
            print("UPDATER_GUI normal_launcher=1 uid=1000 selected_updates=1 marker=2.0", flush=True)
            break
        time.sleep(.3)
    else:
        titles = [(n.get_role_name(), n.get_name()) for n in nodes(Atspi.get_desktop(0))][:55]
        raise RuntimeError(("update did not install", titles))
    assert auth["prompts"] == 1 and auth["action"] and auth["authenticated"], auth
    print("UPDATER_AUTH agent=pkttyagent real_pam=1 policy=stock action=system-update", flush=True)
