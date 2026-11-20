"""Hold an unsaved GTK draft, or locate the Xfce panel's visible lock action."""
import os
from pathlib import Path
import secrets
import signal
import sys
import time

import gi


def unsaved_draft(state):
    gi.require_version("Gtk", "3.0")
    gi.require_version("GdkX11", "3.0")
    from gi.repository import GdkX11, GLib, Gtk

    Gtk.init([])
    window = Gtk.Window(title="Unsaved screen lock test")
    view = Gtk.TextView()
    text = view.get_buffer()
    contents = secrets.token_hex(24)
    text.set_text(contents)
    text.set_modified(True)
    window.add(view)
    window.set_default_size(260, 120)
    window.show_all()
    window_id = GdkX11.X11Window.get_xid(window.get_window())
    def draft_position():
        surface = window.get_window()
        _, x, y = surface.get_origin()
        (state / "point").write_text(f"{x + surface.get_width() // 2} {y + surface.get_height() // 2}\n")
        return GLib.SOURCE_REMOVE

    def receipt(path):
        start, end = text.get_bounds()
        surface = window.get_window()
        if not window.get_mapped() or not surface:
            return
        current_id = GdkX11.X11Window.get_xid(surface)
        if current_id == window_id and text.get_modified() and text.get_text(start, end, True) == contents:
            path.write_text(f"{os.getpid()} {current_id}\n")

    def resumed():
        receipt(state / "resumed")
        return GLib.SOURCE_REMOVE

    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, resumed)
    GLib.timeout_add(1200, draft_position)
    receipt(state / "draft")
    Gtk.main()


def accessible_target(kind):
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi, GLib
    Atspi.init()
    desktop = Atspi.get_desktop(0)

    def walk(node):
        yield node
        for i in range(node.get_child_count()):
            child = node.get_child_at_index(i)
            if child:
                yield from walk(child)

    def matches(role, name):
        if kind == "button":
            return role in (Atspi.Role.PUSH_BUTTON, Atspi.Role.TOGGLE_BUTTON, Atspi.Role.LABEL) and name == "y700"
        return role == Atspi.Role.MENU_ITEM and name.replace("_", "").casefold() == "lock screen"

    until = time.monotonic() + 65
    previous = None
    since = 0
    visible = set()
    clock_reported = False
    while time.monotonic() < until:
        found = None
        try:
            for i in range(desktop.get_child_count()):
                app = desktop.get_child_at_index(i)
                if not app:
                    continue
                if Path(f"/proc/{app.get_process_id()}/exe").resolve().name not in {"xfce4-panel", "wrapper-2.0"}:
                    continue
                for item in walk(app):
                    states = item.get_state_set()
                    if not states.contains(Atspi.StateType.SHOWING):
                        continue
                    role = item.get_role()
                    name = item.get_name() or ""
                    visible.add((str(role.value_nick), name))
                    if kind == "menu" and role == Atspi.Role.CALENDAR and not clock_reported:
                        print("SCREEN_LOCK_CALENDAR_OPEN", file=sys.stderr, flush=True)
                        clock_reported = True
                    if not matches(role, name):
                        continue
                    box = item.get_extents(Atspi.CoordType.SCREEN)
                    x, y = box.x + box.width // 2, box.y + box.height // 2
                    if box.width < 1 or box.height < 1 or not (0 <= x < 1024 and 0 <= y < 768):
                        continue
                    if kind == "button" and not (x > 600 and y < 65):
                        continue
                    found = (x, y)
                    break
                if found:
                    break
        except GLib.Error:
            found = None
        if found != previous:
            previous, since = found, time.monotonic()
        if found and time.monotonic() - since >= (1.2 if kind != "menu" else 0.2):
            print(*found)
            return
        time.sleep(.2)
    raise RuntimeError(f"Timed out waiting for {kind}; visible panel controls: {sorted(visible)!r}")


if __name__ == "__main__":
    if sys.argv[1] == "draft":
        unsaved_draft(Path(sys.argv[2]))
    else:
        accessible_target(sys.argv[1])
