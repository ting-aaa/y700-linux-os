"""Locate Thunar controls using AT-SPI. Send every action as a direct touchscreen contact."""
import os
from pathlib import Path
import subprocess
import time

import gi
gi.require_version("Atspi", "2.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Atspi, Gdk, GLib


def walk(node):
    try:
        yield node
        role = node.get_role()
        if role in (Atspi.Role.TABLE, Atspi.Role.TABLE_CELL):
            return
        if role not in (Atspi.Role.APPLICATION, Atspi.Role.DESKTOP_FRAME):
            if not node.get_state_set().contains(Atspi.StateType.SHOWING):
                return
        for index in range(node.get_child_count()):
            yield from walk(node.get_child_at_index(index))
    except GLib.Error:
        pass


def widgets():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_name().lower() == "thunar":
            yield from walk(app)


def wait(test, label, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        context = GLib.MainContext.default()
        for _ in range(20):
            if not context.iteration(False):
                break
        result = test()
        if result:
            return result
        time.sleep(.15)
    raise RuntimeError(label)


def widget(role, name=None):
    for n in widgets():
        if n.get_role_name() == role and (name is None or n.get_name() == name):
            if n.get_state_set().contains(Atspi.StateType.SHOWING):
                return n


def box(node):
    return node.get_component_iface().get_extents(Atspi.CoordType.SCREEN)


def touch(action, x, y):
    # The GTK3 AT-SPI bridge reports logical X11 coordinates at scale two.
    x, y = int(2*x), int(2*y)
    if helper := os.environ.get("Y700_THUNAR_TOUCH"):
        subprocess.run([helper, action, str(x), str(y)], check=True, timeout=8)
    else:
        assert "y700.topology_fixture=1" in Path("/proc/cmdline").read_text().split()
        with open("/run/topology/feed", "w") as f:
            print(action, x*10, y*10, file=f)
    time.sleep(1.6 if action == "hold" else .4)


def title():
    frame = widget("frame")
    return frame.get_name() if frame else ""


def press_widget(role, name):
    n = wait(lambda: widget(role, name), name)
    r = box(n)
    assert r.width > 0 and r.height > 0
    # The parent toolbar action is on the left of its accessible bounds.
    touch("tap", r.x + r.width * (.3 if name == "Open Parent" else .5), r.y + r.height/2)


def point_in_view(action, item):
    pane = box(wait(lambda: widget("directory pane", "Icon view"), "icon view"))
    x, y = (45, 36) if item else (pane.width/2, pane.height/2)
    touch(action, pane.x + x, pane.y + y)


def enter_name(word, button):
    from keyboard import KEYS, window_geometry
    monitor = Gdk.Display.get_default().get_monitor(0)
    height = monitor.get_geometry().height * monitor.get_scale_factor()

    def visible_keyboard():
        bounds = window_geometry()
        if bounds and bounds[1] >= 0 and bounds[1] + bounds[3] <= height + 2:
            return bounds

    x, y, w, h = wait(visible_keyboard, "visible Onboard", 30)
    for c in word:
        kx, ky = KEYS[c]
        touch("tap", (x+w*kx)/2, (y+h*ky)/2)
    press_widget("button", button)


def exercise(work):
    (work / "Travel").mkdir(parents=True)
    proc = subprocess.Popen(["thunar", work], stdout=subprocess.DEVNULL)
    try:
        wait(lambda: title() == "TouchFiles - Thunar", "file manager", 55)
        if not os.environ.get("Y700_THUNAR_STOCK") and not os.environ.get("Y700_THUNAR_TOUCH"):
            for action in ("drag-back", "two-contacts"):
                point_in_view(action, True)
                time.sleep(1.3)
                assert title() == "TouchFiles - Thunar", action
                print("THUNAR_GUARD", action, "preserved directory", flush=True)
        point_in_view("tap", True)
        if os.environ.get("Y700_THUNAR_STOCK"):
            selection = wait(lambda: widget("status bar"), "file selection").get_name()
            assert title() == "TouchFiles - Thunar" and "Travel" in selection
            point_in_view("hold", True)
            assert title() == "TouchFiles - Thunar" and not widget("menu item", "Rename...")
            print("THUNAR_STOCK tap_selected=1 hold_menu=0", flush=True)
            return
        wait(lambda: title() == "Travel - Thunar", "single touch navigation")
        for label, folder in (("Back", "TouchFiles"), ("Forward", "Travel"), ("Open Parent", "TouchFiles")):
            press_widget("button", label)
            wait(lambda: title() == folder + " - Thunar", label)
        point_in_view("tap", True)
        wait(lambda: title() == "Travel - Thunar", "enter empty directory")
        point_in_view("hold", False)
        print("THUNAR_STAGE empty-hold", flush=True)
        press_widget("menu item", "Create Folder...")
        enter_name("hello", "Create")
        base = work / "Travel"
        wait(lambda: (base / "hello").is_dir(), "created directory")
        point_in_view("hold", True)
        print("THUNAR_STAGE item-hold", flush=True)
        press_widget("menu item", "Rename...")
        enter_name("oh", "Rename")
        wait(lambda: (base / "oh").is_dir() and not (base / "hello").exists(), "renamed directory")
        print("THUNAR_TOUCH opened=2 back=1 forward=1 parent=1 hold_menu=2 onboard=2 created=1 renamed=1 shortcuts=0", flush=True)
    except Exception:
        for n in widgets():
            if n.get_role_name() in ("frame", "dialog", "menu", "menu item", "button", "status bar") and n.get_state_set().contains(Atspi.StateType.SHOWING):
                print("THUNAR_DIAG", n.get_role_name(), repr(n.get_name()), flush=True)
        print(subprocess.check_output(["xwininfo","-root","-tree"], text=True)[-3400:], flush=True)
        raise
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)


def main():
    import tempfile
    assert os.getuid() != 0
    assert Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2
    Atspi.init()
    Atspi.set_timeout(3500, 3500)
    with tempfile.TemporaryDirectory(dir=os.environ["XDG_RUNTIME_DIR"], prefix="thunar-check-") as tmp:
        exercise(Path(tmp)/"TouchFiles")


if __name__ == "__main__":
    main()
